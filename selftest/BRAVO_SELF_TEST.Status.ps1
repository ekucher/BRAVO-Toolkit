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
            -ExitCode 0 -ExitCodeName 'Success' -Status (Get-BRAVOExitCodeStatus -Code 0) -StartedAt (Get-Date).AddMinutes(-2) `
            -Details @{ localVerified = $true; issueCount = 0 }
        $operationStatusPath = Get-BRAVOOperationStatusPath -StateRoot $operationStatusTestRoot -Operation Health
        $operationStatusOk = Get-BRAVOOperationStatus -Path $operationStatusPath
        $operationStatusBytes = [IO.File]::ReadAllBytes($operationStatusPath)
        Write-BRAVOOperationStatus -StateRoot $operationStatusTestRoot -Operation Health `
            -ExitCode 10 -ExitCodeName 'SuccessWithWarnings' -Status (Get-BRAVOExitCodeStatus -Code 10) -StartedAt (Get-Date)
        $operationStatusWarn = Get-BRAVOOperationStatus -Path $operationStatusPath
        Write-BRAVOOperationStatus -StateRoot $operationStatusTestRoot -Operation Health `
            -ExitCode 43 -ExitCodeName 'RestoreFailed' -Status (Get-BRAVOExitCodeStatus -Code 43) -StartedAt (Get-Date)
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
            -ExitCode 0 -ExitCodeName 'Success' -Status (Get-BRAVOExitCodeStatus -Code 0) -StartedAt (Get-Date) `
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
            RequiredAfter = 'function Write-BRAVOArchiveOperationStatus'
        }
        @{
            Label = 'Health'
            Path = 'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1'
            RequiredAfter = '$script:healthRuntimeExitCode = $healthExitCode'
        }
        @{
            # #478: перший Write-BRAVOOperationStatus у Maintenance — у
            # fail-soft helper'і Write-BRAVOMaintenanceEarlyExitStatus, який
            # пишуть усі ранні виходи (exit code він отримує параметром).
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
    # AST-спорідненість замість відстані в символах: виклик захищено, якщо він
    # (а) всередині if із guard'ом в умові або (б) у блоці після if із guard'ом
    # в умові, чиє тіло містить return (ранній вихід).
    $archiveStatusGuardedCheck = {
        param([Management.Automation.Language.Ast]$Ast, [string]$GuardText)
        $calls = @($Ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-BRAVOOperationStatus' }, $true))
        $unguarded = 0
        foreach ($call in $calls) {
            $guarded = $false
            $node = $call
            while ($null -ne $node.Parent -and -not $guarded) {
                $parent = $node.Parent
                if ($parent -is [Management.Automation.Language.IfStatementAst]) {
                    foreach ($clause in $parent.Clauses) {
                        if ($clause.Item2.Extent.StartOffset -le $call.Extent.StartOffset -and
                            $clause.Item2.Extent.EndOffset -ge $call.Extent.EndOffset -and
                            $clause.Item1.Extent.Text.Contains($GuardText)) { $guarded = $true }
                    }
                }
                $siblings = $null
                if ($parent -is [Management.Automation.Language.StatementBlockAst]) { $siblings = $parent.Statements }
                elseif ($parent -is [Management.Automation.Language.NamedBlockAst]) { $siblings = $parent.Statements }
                if ($null -ne $siblings) {
                    foreach ($sibling in $siblings) {
                        if ($sibling.Extent.EndOffset -le $node.Extent.StartOffset -and
                            $sibling -is [Management.Automation.Language.IfStatementAst]) {
                            foreach ($clause in $sibling.Clauses) {
                                if ($clause.Item1.Extent.Text.Contains($GuardText) -and
                                    @($clause.Item2.FindAll({ param($r) $r -is [Management.Automation.Language.ReturnStatementAst] }, $true)).Count -gt 0) { $guarded = $true }
                            }
                        }
                    }
                }
                $node = $parent
            }
            if (-not $guarded) { $unguarded++ }
        }
        return [pscustomobject]@{ Calls = $calls.Count; Unguarded = $unguarded }
    }
    $archiveGuardTokens = $null
    $archiveGuardErrors = $null
    $archiveGuardAst = [Management.Automation.Language.Parser]::ParseInput($archiveStatusText, [ref]$archiveGuardTokens, [ref]$archiveGuardErrors)
    $archiveGuardResult = & $archiveStatusGuardedCheck $archiveGuardAst $archiveSyncBazaGuardText
    $archiveGuardSyntheticText = @'
function A { if ((Test-Path variable:SyncBAZA) -and $SyncBAZA) { return }; Write-BRAVOOperationStatus -X 1 }
function B { if (-not ((Test-Path variable:SyncBAZA) -and $SyncBAZA)) { Write-BRAVOOperationStatus -X 2 } }
function C { Write-BRAVOOperationStatus -X 3 }
'@
    $archiveGuardSyntheticAst = [Management.Automation.Language.Parser]::ParseInput($archiveGuardSyntheticText, [ref]$archiveGuardTokens, [ref]$archiveGuardErrors)
    $archiveGuardSynthetic = & $archiveStatusGuardedCheck $archiveGuardSyntheticAst $archiveSyncBazaGuardText
    $archiveRawStatusIndexes = if ($archiveGuardResult.Calls -gt 0) { @(1..$archiveGuardResult.Calls) } else { @() }
    $archiveUnguardedStatusCount = $archiveGuardResult.Unguarded
    if ($archiveGuardSynthetic.Calls -ne 3 -or $archiveGuardSynthetic.Unguarded -ne 1) { $archiveUnguardedStatusCount = -1 }
    Test-BRAVOCondition `
        -Condition ($archiveRawStatusIndexes.Count -ge 2 -and $archiveUnguardedStatusCount -eq 0) `
        -Name 'Status/ArchiveStatusWritesSkipSyncBaza' `
        -Failure "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1: кожен Write-BRAVOOperationStatus (helper і фатальний catch) має бути під guard'ом -SyncBAZA; викликів=$($archiveRawStatusIndexes.Count), без guard'а=$archiveUnguardedStatusCount"

    # =====================================================================
    # #479 (B4): ЄДИНЕ відображення код завершення -> severity/Status у
    # BRAVO.ExitCodes. Status, Maintenance і Archive беруть його звідти;
    # локальних switch/if-ланцюгів по кодах поза модулем немає.
    # =====================================================================
    if (-not (Get-Command -Name Get-BRAVOExitCodeStatus -ErrorAction SilentlyContinue)) {
        Import-Module -Name (Join-Path $root 'modules\BRAVO.ExitCodes\BRAVO.ExitCodes.psd1') -Force
    }
    $exitCodesModule = Get-Module -Name BRAVO.ExitCodes | Select-Object -First 1
    $namedExitCodes = @(& $exitCodesModule { $script:BRAVOExitCodeNames.Keys } | ForEach-Object { [int]$_ } | Sort-Object)
    $severityExitCodes = @(& $exitCodesModule { $script:BRAVOExitCodeSeverities.Keys } | ForEach-Object { [int]$_ } | Sort-Object)
    # Pinned очікування: код -> severity|status. Новий код у таблиці імен
    # без запису тут і в таблиці severity ламає тест (його треба класифікувати).
    $expectedExitCodeMapping = @{
        0 = 'SUCCESS|OK'; 10 = 'WARNING|WARNINGS'; 20 = 'WARNING|WARNINGS'
        30 = 'ERROR|ERROR'; 31 = 'ERROR|ERROR'
        32 = 'CRITICAL|ERROR'; 33 = 'CRITICAL|ERROR'; 34 = 'CRITICAL|ERROR'; 35 = 'CRITICAL|ERROR'
        36 = 'ERROR|ERROR'; 37 = 'ERROR|ERROR'
        40 = 'ERROR|ERROR'; 41 = 'ERROR|ERROR'; 42 = 'ERROR|ERROR'; 43 = 'ERROR|ERROR'
        50 = 'ERROR|ERROR'; 51 = 'ERROR|ERROR'; 60 = 'ERROR|ERROR'
        70 = 'CRITICAL|ERROR'; 90 = 'ERROR|ERROR'
    }
    $exitCodeMappingMismatches = New-Object 'System.Collections.Generic.List[string]'
    foreach ($namedExitCode in $namedExitCodes) {
        $actualMapping = '{0}|{1}' -f (Get-BRAVOExitCodeSeverity -Code $namedExitCode), (Get-BRAVOExitCodeStatus -Code $namedExitCode)
        if (-not $expectedExitCodeMapping.ContainsKey($namedExitCode) -or
            [string]$expectedExitCodeMapping[$namedExitCode] -ne $actualMapping) {
            $exitCodeMappingMismatches.Add("$namedExitCode=$actualMapping")
        }
    }
    Test-BRAVOCondition `
        -Condition (
            $namedExitCodes.Count -gt 0 -and
            ($namedExitCodes -join ',') -eq ($severityExitCodes -join ',') -and
            ($namedExitCodes -join ',') -eq (@($expectedExitCodeMapping.Keys | ForEach-Object { [int]$_ } | Sort-Object) -join ',') -and
            $exitCodeMappingMismatches.Count -eq 0 -and
            (Get-BRAVOExitCodeSeverity -Code 12345) -eq 'ERROR' -and
            (Get-BRAVOExitCodeStatus -Code 12345) -eq 'ERROR'
        ) `
        -Name 'ExitCodes/EveryNamedCodeHasSeverityAndStatus' `
        -Failure "кожен код з `$script:BRAVOExitCodeNames мусить мати рівно один запис у таблиці severity і pinned-очікування (SUCCESS/WARNING/ERROR/CRITICAL -> OK/WARNINGS/ERROR); коди: $($namedExitCodes -join ',') / severity: $($severityExitCodes -join ',') / розбіжності: $($exitCodeMappingMismatches -join '; ')"

    # Рішення власника D-A: SkippedLockBusy (20) -> Status WARNINGS (було ERROR
    # у BRAVO.Status); status-файл береться з ТОГО Ж відображення end-to-end.
    $skippedStatusRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_STATUS_479_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        [void](New-Item -ItemType Directory -Path $skippedStatusRoot -Force)
        Write-BRAVOOperationStatus -StateRoot $skippedStatusRoot -Operation Health `
            -ExitCode 20 -ExitCodeName (Get-BRAVOExitCodeName -Code 20) -Status (Get-BRAVOExitCodeStatus -Code 20) `
            -StartedAt (Get-Date)
        $skippedStatus = Get-BRAVOOperationStatus -Path (Get-BRAVOOperationStatusPath -StateRoot $skippedStatusRoot -Operation Health)
        Test-BRAVOCondition `
            -Condition (
                (Get-BRAVOExitCodeName -Code 20) -eq 'SkippedLockBusy' -and
                (Get-BRAVOExitCodeStatus -Code 20) -eq 'WARNINGS' -and
                [int]$skippedStatus.State.exitCode -eq 20 -and
                [string]$skippedStatus.State.status -eq 'WARNINGS'
            ) `
            -Name 'ExitCodes/SkippedLockBusyMapsToWarnings' `
            -Failure 'код 20 (SkippedLockBusy) має давати Status WARNINGS (рішення власника D-A), а не ERROR — і в Get-BRAVOExitCodeStatus, і у записаному status-файлі'
    } finally {
        Remove-Item -LiteralPath $skippedStatusRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Модуль Status не має власного відображення і не імпортує ExitCodes:
    # -Status обов'язковий (ValidateSet схеми), запасної деривації з exitCode немає.
    $statusModuleText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Status\BRAVO.Status.psm1'), [Text.Encoding]::UTF8)
    $statusModuleManifestText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Status\BRAVO.Status.psd1'), [Text.Encoding]::UTF8)
    $statusModuleTokens = $null
    $statusModuleErrors = $null
    $statusModuleAst = [Management.Automation.Language.Parser]::ParseInput($statusModuleText, [ref]$statusModuleTokens, [ref]$statusModuleErrors)
    $statusModuleBranchesOnExitCode = @($statusModuleAst.FindAll({
                param($candidate)
                ($candidate -is [Management.Automation.Language.IfStatementAst] -and
                    @($candidate.Clauses | Where-Object { $_.Item1.Extent.Text -match '(?i)exitcode' }).Count -gt 0) -or
                ($candidate -is [Management.Automation.Language.SwitchStatementAst] -and
                    $candidate.Condition.Extent.Text -match '(?i)exitcode')
            }, $true))
    $statusModuleExitCodeCalls = @($statusModuleAst.FindAll({
                param($candidate)
                $candidate -is [Management.Automation.Language.CommandAst] -and
                [string]$candidate.GetCommandName() -match '^(Get|Resolve)-BRAVOExitCode'
            }, $true))
    $statusParameter = (Get-Command -Name Write-BRAVOOperationStatus).Parameters['Status']
    $statusParameterMandatory = $null -ne $statusParameter -and
        @($statusParameter.Attributes | Where-Object { $_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count -gt 0
    $statusParameterValidateSet = if ($null -ne $statusParameter) {
        @($statusParameter.Attributes | Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] } |
            ForEach-Object { $_.ValidValues }) -join ','
    } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $statusModuleErrors.Count -eq 0 -and
            $statusModuleText -notmatch '(?m)^\s*(Import-Module|using module)\b[^\r\n]*ExitCodes' -and
            $statusModuleManifestText -notmatch 'RequiredModules|NestedModules|ExitCodes' -and
            $statusModuleExitCodeCalls.Count -eq 0 -and
            $statusModuleBranchesOnExitCode.Count -eq 0 -and
            $statusParameterMandatory -and
            $statusParameterValidateSet -eq 'OK,WARNINGS,ERROR'
        ) `
        -Name 'Status/ModuleHasNoLocalExitCodeMapping' `
        -Failure "modules\BRAVO.Status: має не імпортувати BRAVO.ExitCodes, не гілкуватись по ExitCode і приймати обов'язковий -Status з ValidateSet OK|WARNINGS|ERROR (єдине відображення живе в BRAVO.ExitCodes); гілок по ExitCode=$($statusModuleBranchesOnExitCode.Count) mandatory=$statusParameterMandatory validateSet='$statusParameterValidateSet'"

    # --- AST: у runtime-файлах немає локального switch/if-ланцюга, що
    # відображає ЧИСЛОВИЙ код завершення (або його ім'я) на літерал
    # severity/Status. Споживання канонічних Get-BRAVOExitCodeStatus/
    # Get-BRAVOExitCodeSeverity дозволено. Негативний контроль на штучному
    # зразку доводить, що правило не порожнє.
    $exitCodeLiteralSet = @('OK', 'WARNINGS', 'ERROR', 'CRITICAL', 'SUCCESS', 'WARNING')
    $findLocalExitCodeMappings = {
        param([Management.Automation.Language.Ast]$Ast, [string[]]$LiteralSet)
        $isLiteral = {
            param($node)
            $node -is [Management.Automation.Language.StringConstantExpressionAst] -and ($LiteralSet -contains [string]$node.Value)
        }
        $blockYieldsLiteral = {
            param($block)
            $yielding = @($block.FindAll({
                        param($node)
                        ($node -is [Management.Automation.Language.ReturnStatementAst] -and
                            $null -ne $node.Pipeline -and
                            $node.Pipeline -is [Management.Automation.Language.PipelineAst] -and
                            $node.Pipeline.PipelineElements.Count -eq 1 -and
                            $node.Pipeline.PipelineElements[0] -is [Management.Automation.Language.CommandExpressionAst] -and
                            (& $isLiteral $node.Pipeline.PipelineElements[0].Expression)) -or
                        ($node -is [Management.Automation.Language.CommandExpressionAst] -and
                            (& $isLiteral $node.Expression) -and
                            $node.Parent -is [Management.Automation.Language.PipelineAst] -and
                            $node.Parent.PipelineElements.Count -eq 1 -and
                            ($node.Parent.Parent -is [Management.Automation.Language.StatementBlockAst] -or
                                $node.Parent.Parent -is [Management.Automation.Language.NamedBlockAst])) -or
                        ($node -is [Management.Automation.Language.AssignmentStatementAst] -and
                            $node.Right -is [Management.Automation.Language.CommandExpressionAst] -and
                            (& $isLiteral $node.Right.Expression))
                    }, $true))
            return $yielding.Count -gt 0
        }
        $branchesOnCode = {
            param([string]$ConditionText)
            return (
                $ConditionText -match '(?i)exitcode' -and
                ($ConditionText -match '\b\d+\b' -or $ConditionText -match 'Get-BRAVOExitCodeName') -and
                $ConditionText -notmatch 'Get-BRAVOExitCode(Status|Severity)'
            )
        }
        $mappings = New-Object 'System.Collections.Generic.List[string]'
        foreach ($branchNode in @($Ast.FindAll({
                        param($node)
                        $node -is [Management.Automation.Language.IfStatementAst] -or
                        $node -is [Management.Automation.Language.SwitchStatementAst]
                    }, $true))) {
            if ($branchNode -is [Management.Automation.Language.IfStatementAst]) {
                # Одне відображення = один оператор if/switch (ланцюг if/elseif — одна знахідка).
                foreach ($ifClause in $branchNode.Clauses) {
                    if ((& $branchesOnCode $ifClause.Item1.Extent.Text) -and (& $blockYieldsLiteral $ifClause.Item2)) {
                        $mappings.Add(('line {0}: if ({1})' -f $branchNode.Extent.StartLineNumber, $ifClause.Item1.Extent.Text))
                        break
                    }
                }
            } elseif (($branchNode.Condition.Extent.Text -match '(?i)exitcode' -and
                    $branchNode.Condition.Extent.Text -notmatch 'Get-BRAVOExitCode(Status|Severity)') -or
                (& $branchesOnCode $branchNode.Condition.Extent.Text)) {
                $switchBodies = @($branchNode.Clauses | ForEach-Object { $_.Item2 })
                if ($null -ne $branchNode.Default) { $switchBodies += $branchNode.Default }
                foreach ($switchBody in $switchBodies) {
                    if (& $blockYieldsLiteral $switchBody) {
                        $mappings.Add(('line {0}: switch ({1})' -f $branchNode.Extent.StartLineNumber, $branchNode.Condition.Extent.Text))
                        break
                    }
                }
            }
        }
        return , $mappings.ToArray()
    }
    $syntheticLocalMappingText = @'
function Get-LocalStatus { param($ExitCode)
    if ($ExitCode -eq 0) { 'OK' } elseif ($ExitCode -eq 10) { 'WARNINGS' } else { 'ERROR' }
}
function Get-LocalSeverity { param($ExitCode)
    switch ($ExitCode) { 0 { return 'SUCCESS' } 20 { return 'WARNING' } default { return 'ERROR' } }
}
function Get-LocalSeverityByName { param($ExitCode)
    $label = switch (Get-BRAVOExitCodeName -Code $ExitCode) { 'Success' { 'SUCCESS' } default { 'ERROR' } }
}
function Get-CanonicalStatus { param($ExitCode)
    switch (Get-BRAVOExitCodeStatus -Code $ExitCode) { 'OK' { 'a' } default { 'b' } }
    if ($null -ne $ExitCode) { Write-Log -Level 'ERROR' }
}
'@
    $syntheticLocalMappingTokens = $null
    $syntheticLocalMappingErrors = $null
    $syntheticLocalMappingAst = [Management.Automation.Language.Parser]::ParseInput($syntheticLocalMappingText, [ref]$syntheticLocalMappingTokens, [ref]$syntheticLocalMappingErrors)
    $syntheticLocalMappings = & $findLocalExitCodeMappings $syntheticLocalMappingAst $exitCodeLiteralSet
    Test-BRAVOCondition `
        -Condition ($syntheticLocalMappingErrors.Count -eq 0 -and @($syntheticLocalMappings).Count -eq 3) `
        -Name 'ExitCodes/LocalMappingDetectorCatchesSyntheticMappings' `
        -Failure "AST-детектор локального відображення код -> severity/Status має знаходити 3 штучні мапінги (if-ланцюг, switch по коду, switch по імені) і не чіпати канонічні виклики; знайдено: $(@($syntheticLocalMappings).Count)"
    foreach ($mappingRuntimePath in @(
            'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1',
            'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1',
            'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1'
        )) {
        $mappingRuntimeTokens = $null
        $mappingRuntimeErrors = $null
        $mappingRuntimeAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $mappingRuntimePath), [ref]$mappingRuntimeTokens, [ref]$mappingRuntimeErrors)
        $mappingRuntimeHits = & $findLocalExitCodeMappings $mappingRuntimeAst $exitCodeLiteralSet
        Test-BRAVOCondition `
            -Condition ($mappingRuntimeErrors.Count -eq 0 -and @($mappingRuntimeHits).Count -eq 0) `
            -Name "ExitCodes/NoLocalExitCodeToSeverityMapping[$([IO.Path]::GetFileName($mappingRuntimePath))]" `
            -Failure "${mappingRuntimePath}: локальний switch/if-ланцюг, що відображає код завершення на severity/Status, заборонено (#479) — використовуйте Get-BRAVOExitCodeSeverity/Get-BRAVOExitCodeStatus з BRAVO.ExitCodes; знайдено: $(@($mappingRuntimeHits) -join ' | ')"
    }

    # =====================================================================
    # #478 (B3): кожен exit у Maintenance/Archive runtime проходить через
    # helper раннього виходу (який пише Status ДО exit) — або це єдиний
    # канонічний фінальний exit.
    # =====================================================================
    $earlyExitRuntimeContracts = @(
        @{
            Label = 'Maintenance'
            Path = 'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1'
            Helper = 'Complete-BRAVOMaintenanceEarlyExit'
            FinalExit = '$script:maintenanceRuntimeExitCode'
            ExpectedSkipStatusCalls = 6
        }
        @{
            Label = 'Archive'
            Path = 'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1'
            Helper = 'Complete-BRAVOArchiveEarlyExit'
            FinalExit = '$script:processExitCode'
            ExpectedSkipStatusCalls = 3
        }
    )
    $findStrayExits = {
        param([Management.Automation.Language.Ast]$Ast, [string]$HelperName, [string]$FinalExitText)
        $exitStatements = @($Ast.FindAll({ param($node) $node -is [Management.Automation.Language.ExitStatementAst] }, $true))
        $stray = New-Object 'System.Collections.Generic.List[string]'
        $finalCount = 0
        $helperExitCount = 0
        foreach ($exitStatement in $exitStatements) {
            $owner = $exitStatement.Parent
            while ($null -ne $owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
            if ($null -ne $owner -and $owner.Name -eq $HelperName) {
                $helperExitCount++
            } elseif ($null -ne $exitStatement.Pipeline -and $exitStatement.Pipeline.Extent.Text -eq $FinalExitText) {
                $finalCount++
            } else {
                $stray.Add(('line {0}: {1}' -f $exitStatement.Extent.StartLineNumber, $exitStatement.Extent.Text))
            }
        }
        return [pscustomobject]@{ Stray = $stray.ToArray(); FinalCount = $finalCount; HelperExitCount = $helperExitCount }
    }
    $syntheticExitText = @'
function Complete-X { param($ExitCode) exit $ExitCode }
function Run { param($c)
    if ($c) { exit 30 }
    Complete-X -ExitCode 1
    exit $script:finalCode
}
'@
    $syntheticExitTokens = $null
    $syntheticExitErrors = $null
    $syntheticExitAst = [Management.Automation.Language.Parser]::ParseInput($syntheticExitText, [ref]$syntheticExitTokens, [ref]$syntheticExitErrors)
    $syntheticExitResult = & $findStrayExits $syntheticExitAst 'Complete-X' '$script:finalCode'
    Test-BRAVOCondition `
        -Condition (
            $syntheticExitErrors.Count -eq 0 -and
            $syntheticExitResult.Stray.Count -eq 1 -and
            $syntheticExitResult.FinalCount -eq 1 -and
            $syntheticExitResult.HelperExitCount -eq 1
        ) `
        -Name 'Status/EarlyExitDetectorCatchesStrayExit' `
        -Failure 'AST-перевірка «кожен exit через helper» має знаходити голий exit на штучному зразку (1 сторонній, 1 фінальний, 1 у helper)'
    foreach ($earlyExitContract in $earlyExitRuntimeContracts) {
        $earlyExitTokens = $null
        $earlyExitErrors = $null
        $earlyExitAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $earlyExitContract.Path), [ref]$earlyExitTokens, [ref]$earlyExitErrors)
        $earlyExitScan = & $findStrayExits $earlyExitAst $earlyExitContract.Helper $earlyExitContract.FinalExit
        $earlyExitHelperName = [string]$earlyExitContract.Helper
        $helperCalls = @($earlyExitAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq $earlyExitHelperName
                }, $true))
        $skipStatusCalls = @($helperCalls | Where-Object {
                @($_.CommandElements | Where-Object {
                        $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'SkipStatus'
                    }).Count -gt 0
            })
        $helperDefinitions = @($earlyExitAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $earlyExitHelperName
                }, $true))
        Test-BRAVOCondition `
            -Condition (
                $earlyExitErrors.Count -eq 0 -and
                $helperDefinitions.Count -eq 1 -and
                $earlyExitScan.Stray.Count -eq 0 -and
                $earlyExitScan.FinalCount -eq 1 -and
                $earlyExitScan.HelperExitCount -eq 1 -and
                $helperCalls.Count -ge 5 -and
                $skipStatusCalls.Count -eq $earlyExitContract.ExpectedSkipStatusCalls
            ) `
            -Name "Status/EveryExitPassesThroughEarlyExitHelper[$($earlyExitContract.Label)]" `
            -Failure "$($earlyExitContract.Path): кожен exit має проходити через $($earlyExitContract.Helper) (пише Status перед exit) або бути єдиним фінальним '$($earlyExitContract.FinalExit)'; сторонні exit: $($earlyExitScan.Stray -join ' | '); фінальних=$($earlyExitScan.FinalCount); викликів helper=$($helperCalls.Count); -SkipStatus=$($skipStatusCalls.Count) (очікується $($earlyExitContract.ExpectedSkipStatusCalls): лише виходи, що не є результатом прогону — lock/no-op/RecoverServices/дочірній процес)"
    }

    # --- Поведінка (дочірній powershell.exe, бо helper викликає exit): статус
    # оновлено з правильним кодом/Status ДО завершення процесу. Тіла helper'ів
    # беруться з реальних runtime-файлів через AST. Під StrictMode 2.0.
    $earlyExitBehaviorRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_EARLYEXIT_478_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        [void](New-Item -ItemType Directory -Path $earlyExitBehaviorRoot -Force)
        $getFunctionText = {
            param([string]$RelativePath, [string[]]$Names)
            $functionTokens = $null
            $functionErrors = $null
            $functionAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $RelativePath), [ref]$functionTokens, [ref]$functionErrors)
            $texts = foreach ($functionName in $Names) {
                $functionNameToFind = $functionName
                $functionNode = $functionAst.Find({
                        param($node)
                        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionNameToFind
                    }, $true)
                if ($null -eq $functionNode) { throw "функцію $functionName не знайдено в $RelativePath" }
                $functionNode.Extent.Text
            }
            return ($texts -join "`r`n`r`n")
        }
        $maintenanceHelperText = & $getFunctionText 'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1' @('Write-BRAVOMaintenanceEarlyExitStatus', 'Complete-BRAVOMaintenanceEarlyExit')
        $archiveHelperText = & $getFunctionText 'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1' @('Write-BRAVOArchiveOperationStatus', 'Complete-BRAVOArchiveEarlyExit')
        $exitCodesManifestPath = Join-Path $root 'modules\BRAVO.ExitCodes\BRAVO.ExitCodes.psd1'
        $statusManifestPath = Join-Path $root 'modules\BRAVO.Status\BRAVO.Status.psd1'
        $invokeEarlyExitChild = {
            param([string]$Label, [string]$HelperText, [string]$CallText, [string]$Operation, [string]$SeedStatus, [string]$StateRootLine)
            $childStateRoot = Join-Path $earlyExitBehaviorRoot $Label
            [void](New-Item -ItemType Directory -Path $childStateRoot -Force)
            if ($SeedStatus -ne '') {
                Write-BRAVOOperationStatus -StateRoot $childStateRoot -Operation $Operation `
                    -ExitCode 0 -ExitCodeName 'Success' -Status 'OK' -StartedAt (Get-Date).AddMinutes(-5)
            }
            $childScriptPath = Join-Path $earlyExitBehaviorRoot "$Label.ps1"
            $childScript = @(
                'Set-StrictMode -Version 2.0'
                "Import-Module -Name '$exitCodesManifestPath'"
                "Import-Module -Name '$statusManifestPath'"
                $(if ($StateRootLine -ne '') { $StateRootLine } else { "`$stateRoot = '$childStateRoot'" })
                '$script:ScriptStartTime = (Get-Date).AddSeconds(-3)'
                '$scriptStartTime = (Get-Date).AddSeconds(-3)'
                '$script:processExitCode = 0'
                $HelperText
                $CallText
                'exit 99'
            ) -join "`r`n"
            [IO.File]::WriteAllText($childScriptPath, $childScript, (New-Object Text.UTF8Encoding($true)))
            & powershell.exe -NoProfile -File $childScriptPath *> $null
            $childExitCode = $LASTEXITCODE
            $childStatus = Get-BRAVOOperationStatus -Path (Get-BRAVOOperationStatusPath -StateRoot $childStateRoot -Operation $Operation)
            return [pscustomobject]@{ ExitCode = $childExitCode; Status = $childStatus }
        }
        $maintenanceToolIntegrity = & $invokeEarlyExitChild 'MaintToolIntegrity' $maintenanceHelperText `
            "Complete-BRAVOMaintenanceEarlyExit -ExitCode 32 -Reason 'ToolIntegrityViolation'" 'Maintenance' 'seed' ''
        $maintenanceRecoveryGuard = & $invokeEarlyExitChild 'MaintRecoveryGuard' $maintenanceHelperText `
            "Complete-BRAVOMaintenanceEarlyExit -ExitCode 20 -Reason 'RecoveryGuardServicesRunning'" 'Maintenance' 'seed' ''
        $maintenanceSkipStatus = & $invokeEarlyExitChild 'MaintSkipStatus' $maintenanceHelperText `
            "Complete-BRAVOMaintenanceEarlyExit -ExitCode 20 -Reason 'OperationLockBusy' -SkipStatus" 'Maintenance' 'seed' ''
        # Ранній вихід конфігурації: $stateRoot ще не визначено — запис
        # пропускається, exit code зберігається (fail-soft під StrictMode).
        $maintenanceNoStateRoot = & $invokeEarlyExitChild 'MaintNoStateRoot' $maintenanceHelperText `
            "Complete-BRAVOMaintenanceEarlyExit -ExitCode 30 -Reason 'ConfigurationLoad'" 'Maintenance' '' '$unrelated = 1'
        # Disk-preflight передає власні лічильники: маркери раннього виходу мають
        # бути злиті з ними, а не втрачені (і ключі викликача не перезаписуються).
        $maintenancePreflightDetails = & $invokeEarlyExitChild 'MaintPreflight' $maintenanceHelperText `
            "Complete-BRAVOMaintenanceEarlyExit -ExitCode 60 -Reason 'DiskSpacePreflight' -Details @{ stepsTotal = 3; stepsError = 1; earlyExitReason = 'CallerWins' }" 'Maintenance' 'seed' ''
        Test-BRAVOCondition `
            -Condition (
                $maintenancePreflightDetails.ExitCode -eq 60 -and
                [int]$maintenancePreflightDetails.Status.State.details.stepsTotal -eq 3 -and
                [int]$maintenancePreflightDetails.Status.State.details.stepsError -eq 1 -and
                [bool]$maintenancePreflightDetails.Status.State.details.earlyTermination -and
                [string]$maintenancePreflightDetails.Status.State.details.earlyExitReason -eq 'CallerWins'
            ) `
            -Name 'Maintenance/EarlyExitStatusMergesMarkersWithCallerDetails' `
            -Failure 'ранній вихід Maintenance із власними details (disk-preflight) має зберегти лічильники й додати earlyTermination; ключ викликача earlyExitReason не перезаписується'
        Test-BRAVOCondition `
            -Condition (
                $maintenanceToolIntegrity.ExitCode -eq 32 -and
                -not $maintenanceToolIntegrity.Status.Corrupt -and
                [int]$maintenanceToolIntegrity.Status.State.exitCode -eq 32 -and
                [string]$maintenanceToolIntegrity.Status.State.status -eq 'ERROR' -and
                [string]$maintenanceToolIntegrity.Status.State.exitCodeName -eq 'ToolIntegrityViolation' -and
                [string]$maintenanceToolIntegrity.Status.State.operation -eq 'Maintenance' -and
                [bool]$maintenanceToolIntegrity.Status.State.details.earlyTermination -and
                [string]$maintenanceToolIntegrity.Status.State.details.earlyExitReason -eq 'ToolIntegrityViolation'
            ) `
            -Name 'Maintenance/EarlyExitToolIntegrityWritesErrorStatus' `
            -Failure "ранній вихід Maintenance з кодом 32 мусить оновити BRAVO_STATUS_Maintenance.json (exitCode=32, status=ERROR) і завершити процес кодом 32; процес=$($maintenanceToolIntegrity.ExitCode) файл: exitCode=$($maintenanceToolIntegrity.Status.State.exitCode) status=$($maintenanceToolIntegrity.Status.State.status)"
        Test-BRAVOCondition `
            -Condition (
                $maintenanceRecoveryGuard.ExitCode -eq 20 -and
                -not $maintenanceRecoveryGuard.Status.Corrupt -and
                [int]$maintenanceRecoveryGuard.Status.State.exitCode -eq 20 -and
                [string]$maintenanceRecoveryGuard.Status.State.status -eq 'WARNINGS' -and
                [string]$maintenanceRecoveryGuard.Status.State.exitCodeName -eq 'SkippedLockBusy'
            ) `
            -Name 'Maintenance/EarlyExitRecoveryGuardWritesWarningsStatus' `
            -Failure "recovery guard (код 20) мусить записати Status WARNINGS (D-A), а не лишити попередній OK; процес=$($maintenanceRecoveryGuard.ExitCode) файл: exitCode=$($maintenanceRecoveryGuard.Status.State.exitCode) status=$($maintenanceRecoveryGuard.Status.State.status)"
        Test-BRAVOCondition `
            -Condition (
                $maintenanceSkipStatus.ExitCode -eq 20 -and
                [int]$maintenanceSkipStatus.Status.State.exitCode -eq 0 -and
                [string]$maintenanceSkipStatus.Status.State.status -eq 'OK' -and
                $maintenanceNoStateRoot.ExitCode -eq 30 -and
                -not $maintenanceNoStateRoot.Status.Exists
            ) `
            -Name 'Maintenance/EarlyExitSkipStatusAndMissingStateRootAreFailSoft' `
            -Failure "-SkipStatus не повинен чіпати попередній статус, а відсутній `$stateRoot (ранній вихід конфігурації) не повинен ламати exit: процес=$($maintenanceSkipStatus.ExitCode)/$($maintenanceNoStateRoot.ExitCode)"

        # --- Recovery-тик не затирає ERROR слабшим статусом (-PreserveStrongerError,
        # Get-BRAVOOperationStatusPreservation). Дочірній процес із реальним
        # status-файлом у тимчасовому каталозі; Write-Log — заглушка, що пише
        # в файл, щоб перевірити залоговану примітку.
        $invokePreserveChild = {
            param([string]$Label, [string]$Seed, [string]$CallText)
            $preserveStateRoot = Join-Path $earlyExitBehaviorRoot $Label
            [void](New-Item -ItemType Directory -Path $preserveStateRoot -Force)
            $preserveLogPath = Join-Path $earlyExitBehaviorRoot "$Label.log"
            switch ($Seed) {
                'ERROR' { Write-BRAVOOperationStatus -StateRoot $preserveStateRoot -Operation Maintenance -ExitCode 32 -ExitCodeName 'ToolIntegrityViolation' -Status 'ERROR' -StartedAt (Get-Date).AddMinutes(-5) }
                'WARNINGS' { Write-BRAVOOperationStatus -StateRoot $preserveStateRoot -Operation Maintenance -ExitCode 10 -ExitCodeName 'SuccessWithWarnings' -Status 'WARNINGS' -StartedAt (Get-Date).AddMinutes(-90) -Details @{ earlyExitReason = 'SeedMarker' } }
                'OK' { Write-BRAVOOperationStatus -StateRoot $preserveStateRoot -Operation Maintenance -ExitCode 0 -ExitCodeName 'Success' -Status 'OK' -StartedAt (Get-Date).AddMinutes(-60) -Details @{ earlyExitReason = 'SeedMarker' } }
                'CORRUPT' {
                    $corruptStatusPath = Get-BRAVOOperationStatusPath -StateRoot $preserveStateRoot -Operation Maintenance
                    [void](New-Item -ItemType Directory -Path (Split-Path $corruptStatusPath -Parent) -Force)
                    [IO.File]::WriteAllText($corruptStatusPath, '{ "schemaVersion": 1, "status": "ERR', (New-Object Text.UTF8Encoding($false)))
                }
            }
            $preserveStatusPath = Get-BRAVOOperationStatusPath -StateRoot $preserveStateRoot -Operation Maintenance
            $bytesBefore = if ([IO.File]::Exists($preserveStatusPath)) { [IO.File]::ReadAllBytes($preserveStatusPath) } else { $null }
            $preserveScriptPath = Join-Path $earlyExitBehaviorRoot "$Label.ps1"
            $preserveScript = @(
                'Set-StrictMode -Version 2.0'
                "Import-Module -Name '$exitCodesManifestPath'"
                "Import-Module -Name '$statusManifestPath'"
                "`$stateRoot = '$preserveStateRoot'"
                '$script:ScriptStartTime = (Get-Date).AddSeconds(-3)'
                "function Write-Log { param([string]`$Message, [string]`$Level = 'INFO') [IO.File]::AppendAllText('$preserveLogPath', ('[{0}] {1}' -f `$Level, `$Message) + [Environment]::NewLine) }"
                $maintenanceHelperText
                $CallText
                'exit 99'
            ) -join "`r`n"
            [IO.File]::WriteAllText($preserveScriptPath, $preserveScript, (New-Object Text.UTF8Encoding($true)))
            & powershell.exe -NoProfile -File $preserveScriptPath *> $null
            $preserveExitCode = $LASTEXITCODE
            $bytesAfter = if ([IO.File]::Exists($preserveStatusPath)) { [IO.File]::ReadAllBytes($preserveStatusPath) } else { $null }
            $identical = ($null -ne $bytesBefore -and $null -ne $bytesAfter -and [Convert]::ToBase64String($bytesBefore) -ceq [Convert]::ToBase64String($bytesAfter))
            return [pscustomobject]@{
                ExitCode = $preserveExitCode
                Status = (Get-BRAVOOperationStatus -Path $preserveStatusPath)
                Identical = $identical
                Log = $(if ([IO.File]::Exists($preserveLogPath)) { [IO.File]::ReadAllText($preserveLogPath) } else { '' })
            }
        }
        $tickNoWork = "Complete-BRAVOMaintenanceEarlyExit -ExitCode 10 -Reason 'RecoveryNoWork' -PreserveStrongerError"
        $tickGuard = "Complete-BRAVOMaintenanceEarlyExit -ExitCode 20 -Reason 'RecoveryGuardServicesRunning' -PreserveStrongerError"
        $preserveErrorTick = & $invokePreserveChild 'PresErrTick10' 'ERROR' $tickNoWork
        $preserveOkTick = & $invokePreserveChild 'PresOkTick10' 'OK' $tickNoWork
        $preserveWarnTick = & $invokePreserveChild 'PresWarnTick10' 'WARNINGS' $tickNoWork
        $preserveMissingTick = & $invokePreserveChild 'PresMissTick10' 'MISSING' $tickNoWork
        $preserveCorruptTick = & $invokePreserveChild 'PresCorruptTick10' 'CORRUPT' $tickNoWork
        $preserveErrorGuard = & $invokePreserveChild 'PresErrGuard20' 'ERROR' $tickGuard
        $preserveOkGuard = & $invokePreserveChild 'PresOkGuard20' 'OK' $tickGuard
        $preserveWarnGuard = & $invokePreserveChild 'PresWarnGuard20' 'WARNINGS' $tickGuard
        $preserveMissingGuard = & $invokePreserveChild 'PresMissGuard20' 'MISSING' $tickGuard
        $preserveFullRunOk = & $invokePreserveChild 'PresFullOk' 'ERROR' "Complete-BRAVOMaintenanceEarlyExit -ExitCode 0 -Reason 'FullRun'"
        $preserveFullRunWarn = & $invokePreserveChild 'PresFullWarn' 'ERROR' "Complete-BRAVOMaintenanceEarlyExit -ExitCode 10 -Reason 'FullRun'"
        $preserveErrorTickError = & $invokePreserveChild 'PresErrTick32' 'ERROR' "Complete-BRAVOMaintenanceEarlyExit -ExitCode 32 -Reason 'ToolIntegrityViolation' -PreserveStrongerError"
        Test-BRAVOCondition `
            -Condition (
                $preserveErrorTick.ExitCode -eq 10 -and $preserveErrorTick.Identical -and
                [string]$preserveErrorTick.Status.State.status -eq 'ERROR' -and
                [int]$preserveErrorTick.Status.State.exitCode -eq 32 -and
                $preserveErrorTick.Log -match '\[INFO\].*зберігає попередній ERROR'
            ) `
            -Name 'Maintenance/RecoveryTick10PreservesPreviousError' `
            -Failure "Recovery-тик з кодом 10 не має затирати ERROR: файл має лишитися побайтово незмінним, процес=10, залоговано INFO; процес=$($preserveErrorTick.ExitCode) identical=$($preserveErrorTick.Identical) status=$($preserveErrorTick.Status.State.status) log=$($preserveErrorTick.Log)"
        Test-BRAVOCondition `
            -Condition (
                $preserveOkTick.ExitCode -eq 10 -and -not $preserveOkTick.Identical -and [string]$preserveOkTick.Status.State.status -eq 'WARNINGS' -and [int]$preserveOkTick.Status.State.exitCode -eq 10 -and [string]$preserveOkTick.Status.State.details.earlyExitReason -ceq 'RecoveryNoWork' -and
                $preserveWarnTick.ExitCode -eq 10 -and -not $preserveWarnTick.Identical -and [string]$preserveWarnTick.Status.State.status -eq 'WARNINGS' -and [int]$preserveWarnTick.Status.State.exitCode -eq 10 -and [string]$preserveWarnTick.Status.State.details.earlyExitReason -ceq 'RecoveryNoWork' -and
                $preserveMissingTick.ExitCode -eq 10 -and [string]$preserveMissingTick.Status.State.status -eq 'WARNINGS' -and [string]$preserveMissingTick.Status.State.details.earlyExitReason -ceq 'RecoveryNoWork' -and
                $preserveMissingTick.Log -eq ''
            ) `
            -Name 'Maintenance/RecoveryTick10WritesOverOkWarningsAndMissing' `
            -Failure "Recovery-тик 10 має записувати WARNINGS поверх OK / WARNINGS / відсутнього файла: OK->$($preserveOkTick.Status.State.status) WARNINGS->$($preserveWarnTick.Status.State.status) missing->$($preserveMissingTick.Status.State.status)"
        Test-BRAVOCondition `
            -Condition (
                $preserveCorruptTick.ExitCode -eq 10 -and
                -not $preserveCorruptTick.Status.Corrupt -and
                [string]$preserveCorruptTick.Status.State.status -eq 'WARNINGS' -and
                $preserveCorruptTick.Log -match '\[WARNING\].*пошкоджений'
            ) `
            -Name 'Maintenance/RecoveryTickCorruptStatusIsFailSoftAndLogged' `
            -Failure "зіпсований status-файл не блокує запис Recovery-тика (fail-soft) і залогований як WARNING; процес=$($preserveCorruptTick.ExitCode) corrupt=$($preserveCorruptTick.Status.Corrupt) log=$($preserveCorruptTick.Log)"
        Test-BRAVOCondition `
            -Condition (
                $preserveErrorGuard.ExitCode -eq 20 -and $preserveErrorGuard.Identical -and
                [string]$preserveErrorGuard.Status.State.status -eq 'ERROR' -and
                $preserveOkGuard.ExitCode -eq 20 -and -not $preserveOkGuard.Identical -and [string]$preserveOkGuard.Status.State.status -eq 'WARNINGS' -and [int]$preserveOkGuard.Status.State.exitCode -eq 20 -and [string]$preserveOkGuard.Status.State.details.earlyExitReason -ceq 'RecoveryGuardServicesRunning' -and
                $preserveWarnGuard.ExitCode -eq 20 -and -not $preserveWarnGuard.Identical -and [string]$preserveWarnGuard.Status.State.status -eq 'WARNINGS' -and [string]$preserveWarnGuard.Status.State.details.earlyExitReason -ceq 'RecoveryGuardServicesRunning' -and
                $preserveMissingGuard.ExitCode -eq 20 -and [string]$preserveMissingGuard.Status.State.status -eq 'WARNINGS' -and [string]$preserveMissingGuard.Status.State.details.earlyExitReason -ceq 'RecoveryGuardServicesRunning'
            ) `
            -Name 'Maintenance/RecoveryGuard20PreservesPreviousError' `
            -Failure "recovery guard (20) не має затирати ERROR (файл незмінний), але має писати WARNINGS поверх OK; ERROR->$($preserveErrorGuard.Status.State.status) identical=$($preserveErrorGuard.Identical) OK->$($preserveOkGuard.Status.State.status)"
        Test-BRAVOCondition `
            -Condition (
                $preserveFullRunOk.ExitCode -eq 0 -and [string]$preserveFullRunOk.Status.State.status -eq 'OK' -and [int]$preserveFullRunOk.Status.State.exitCode -eq 0 -and
                $preserveFullRunWarn.ExitCode -eq 10 -and [string]$preserveFullRunWarn.Status.State.status -eq 'WARNINGS' -and
                $preserveErrorTickError.ExitCode -eq 32 -and [string]$preserveErrorTickError.Status.State.status -eq 'ERROR' -and -not $preserveErrorTickError.Identical
            ) `
            -Name 'Maintenance/FullRunStillOverwritesErrorAndErrorTickIsWritten' `
            -Failure "повний прогін (без -PreserveStrongerError) має, як і раніше, затирати ERROR (OK->$($preserveFullRunOk.Status.State.status), 10->$($preserveFullRunWarn.Status.State.status)); Recovery-тик з ERROR (32) теж пишеться (свіжий ERROR): $($preserveErrorTickError.Status.State.status)"

        # Статична перевірка (AST): лише три Recovery-виходи йдуть через
        # збережувальний шлях, і лише вони; Get-BRAVOOperationStatusPreservation
        # викликається єдиний раз — у Write-BRAVOMaintenanceEarlyExitStatus
        # (фінальний запис повного прогону його не використовує).
        $preserveRuntimeTokens = $null
        $preserveRuntimeErrors = $null
        $preserveRuntimeAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1'), [ref]$preserveRuntimeTokens, [ref]$preserveRuntimeErrors)
        $preserveHelperCalls = @($preserveRuntimeAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst] -and
                    @('Complete-BRAVOMaintenanceEarlyExit', 'Write-BRAVOMaintenanceEarlyExitStatus') -ccontains $node.GetCommandName()
                }, $true))
        $preserveReasonsFound = New-Object 'System.Collections.Generic.List[string]'
        $preserveReasonsStray = New-Object 'System.Collections.Generic.List[string]'
        foreach ($preserveCall in $preserveHelperCalls) {
            # Єдина передача перемикача всередині самого Complete-... (forwarding) — не call-site.
            $callOwner = $preserveCall.Parent
            while ($null -ne $callOwner -and $callOwner -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $callOwner = $callOwner.Parent }
            if ($null -ne $callOwner -and $callOwner.Name -ceq 'Complete-BRAVOMaintenanceEarlyExit') { continue }
            $callElements = @($preserveCall.CommandElements)
            $hasPreserve = @($callElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'PreserveStrongerError' }).Count -gt 0
            $reasonText = ''
            for ($elementIndex = 0; $elementIndex -lt ($callElements.Count - 1); $elementIndex++) {
                if ($callElements[$elementIndex] -is [Management.Automation.Language.CommandParameterAst] -and $callElements[$elementIndex].ParameterName -eq 'Reason') {
                    $reasonText = [string]$callElements[$elementIndex + 1].Extent.Text.Trim("'")
                }
            }
            if ($hasPreserve) { $preserveReasonsFound.Add($reasonText) }
            if ($hasPreserve -and @('RecoveryNoWork', 'RestoreVetoedAfterLock', 'RecoveryGuardServicesRunning') -cnotcontains $reasonText) {
                $preserveReasonsStray.Add($reasonText)
            }
        }
        $preservationCallers = @($preserveRuntimeAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-BRAVOOperationStatusPreservation'
                }, $true))
        $preservationCallerFunctions = @($preservationCallers | ForEach-Object {
                $ownerNode = $_.Parent
                while ($null -ne $ownerNode -and $ownerNode -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $ownerNode = $ownerNode.Parent }
                if ($null -ne $ownerNode) { $ownerNode.Name } else { '<script>' }
            })
        Test-BRAVOCondition `
            -Condition (
                $preserveRuntimeErrors.Count -eq 0 -and
                (@($preserveReasonsFound | Sort-Object) -join ',') -ceq 'RecoveryGuardServicesRunning,RecoveryNoWork,RestoreVetoedAfterLock' -and
                $preserveReasonsStray.Count -eq 0 -and
                $preservationCallerFunctions.Count -eq 1 -and
                $preservationCallerFunctions[0] -ceq 'Write-BRAVOMaintenanceEarlyExitStatus'
            ) `
            -Name 'Status/RecoveryTickExitsGoThroughPreservingPath' `
            -Failure "рівно три Recovery-виходи (RecoveryNoWork, RestoreVetoedAfterLock, RecoveryGuardServicesRunning) мають передавати -PreserveStrongerError, інші — ні; Get-BRAVOOperationStatusPreservation — лише у Write-BRAVOMaintenanceEarlyExitStatus; знайдено: [$($preserveReasonsFound -join ',')] сторонні=[$($preserveReasonsStray -join ',')] виклики з=[$($preservationCallerFunctions -join ',')]"

        $archiveToolIntegrity = & $invokeEarlyExitChild 'ArchToolIntegrity' $archiveHelperText `
            "Complete-BRAVOArchiveEarlyExit -ExitCode 32 -EarlyExitReason 'ToolIntegrityViolation'" 'Archive' 'seed' ''
        $archiveInstitutionSettings = & $invokeEarlyExitChild 'ArchInstitution' $archiveHelperText `
            "Complete-BRAVOArchiveEarlyExit -ExitCode 30 -EarlyExitReason 'InstitutionSettings'" 'Archive' 'seed' ''
        $archiveHealthForward = & $invokeEarlyExitChild 'ArchHealthForward' $archiveHelperText `
            'Complete-BRAVOArchiveEarlyExit -ExitCode 70 -SkipStatus' 'Archive' 'seed' ''
        Test-BRAVOCondition `
            -Condition (
                $archiveToolIntegrity.ExitCode -eq 32 -and
                [int]$archiveToolIntegrity.Status.State.exitCode -eq 32 -and
                [string]$archiveToolIntegrity.Status.State.status -eq 'ERROR' -and
                [string]$archiveToolIntegrity.Status.State.details.earlyExitReason -eq 'ToolIntegrityViolation' -and
                $archiveInstitutionSettings.ExitCode -eq 30 -and
                [int]$archiveInstitutionSettings.Status.State.exitCode -eq 30 -and
                [string]$archiveInstitutionSettings.Status.State.status -eq 'ERROR' -and
                $archiveHealthForward.ExitCode -eq 70 -and
                [int]$archiveHealthForward.Status.State.exitCode -eq 0
            ) `
            -Name 'Archive/EarlyExitWritesStatusBeforeExit' `
            -Failure "ранні виходи Archive мусять оновлювати BRAVO_STATUS_Archive.json (32/30 -> ERROR) до exit; -SkipStatus (пересилання -HealthCheckOnly) статус не чіпає; процес=$($archiveToolIntegrity.ExitCode)/$($archiveInstitutionSettings.ExitCode)/$($archiveHealthForward.ExitCode)"
    } finally {
        Remove-Item -LiteralPath $earlyExitBehaviorRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
