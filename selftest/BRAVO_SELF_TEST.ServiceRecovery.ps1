# Домен-фрагмент self-test: модуль BRAVO.ServiceRecovery (#314, хвиля 3) —
# політика пауз 0/5/15/60 хв у вікні 24 год, state-файл спроб
# BRAVO_SERVICE_RECOVERY_STATE.json (відсутній/пошкоджений/чужий/з BOM,
# атомарний запис без BOM), CRITICAL «циклічно падає» не частіше разу на
# добу, тексти сповіщень FR-6 і визначення «впалої» служби (план §0.3).
# Усе — чисті виклики з -Now (детерміновано, без SCM/WMI, працює на Linux).
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 — НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition,
# New-BRAVOSelfTestRuntimeModule, $script:failures.

& {
    $recoveryModuleDirectory = Join-Path $root 'modules\BRAVO.ServiceRecovery'
    $recoveryModulePath = Join-Path $recoveryModuleDirectory 'BRAVO.ServiceRecovery.psm1'
    $recoveryManifestPath = Join-Path $recoveryModuleDirectory 'BRAVO.ServiceRecovery.psd1'
    $recoveryExpectedExports = @(
        'Get-BRAVOServiceRecoveryPolicy',
        'Test-BRAVOServiceRecoveryFailed',
        'Get-BRAVOServiceRecoveryStatePath',
        'Read-BRAVOServiceRecoveryState',
        'Write-BRAVOServiceRecoveryState',
        'Get-BRAVOServiceRecoveryAttemptDecision',
        'Register-BRAVOServiceRecoveryAttempt',
        'Register-BRAVOServiceRecoveryCriticalSent',
        'Register-BRAVOServiceRecoveryStableObservation',
        'Remove-BRAVOServiceRecoveryExpiredAttempts',
        'New-BRAVOServiceRecoveryNotificationText',
        # #314 хвиля 4 (профіль -RecoverServices)
        'Get-BRAVOServiceRecoveryConditions',
        'Get-BRAVOServiceRecoveryChainPlan',
        'Select-BRAVOServiceRecoveryScmEvents',
        'Get-BRAVOServiceRecoveryScmEvents',
        'Add-BRAVOServiceRecoverySummaryLine',
        # #314 хвиля 5 (задача BRAVO_SERVICE_RECOVERY)
        'Add-BRAVOServiceRecoveryTaskTriggers',
        'Test-BRAVOServiceRecoveryTaskDefinition'
    )

    # ============================================================
    # Маніфест модуля: PowerShellVersion 3.0, експортує рівно
    # публічний API, кожна експортована функція визначена в .psm1.
    # ============================================================
    $recoveryFilesPresent = [IO.File]::Exists($recoveryModulePath) -and [IO.File]::Exists($recoveryManifestPath)
    $recoveryManifestExports = @()
    $recoveryManifestPsVersion = ''
    $recoveryDefinedFunctions = @()
    if ($recoveryFilesPresent) {
        $recoveryManifestInfo = Test-ModuleManifest -Path $recoveryManifestPath -ErrorAction Stop
        $recoveryManifestExports = @($recoveryManifestInfo.ExportedFunctions.Keys | Sort-Object)
        $recoveryManifestPsVersion = [string]$recoveryManifestInfo.PowerShellVersion
        $recoveryModuleAst = [Management.Automation.Language.Parser]::ParseFile($recoveryModulePath, [ref]$null, [ref]$null)
        $recoveryDefinedFunctions = @($recoveryModuleAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst]
                }, $true) | ForEach-Object { $_.Name })
    }
    $recoveryMissingDefinitions = @($recoveryExpectedExports | Where-Object { $recoveryDefinedFunctions -notcontains $_ })
    Test-BRAVOCondition `
        -Condition (
            $recoveryFilesPresent -and
            $recoveryManifestPsVersion -eq '3.0' -and
            @(Compare-Object -ReferenceObject @($recoveryExpectedExports | Sort-Object) -DifferenceObject $recoveryManifestExports).Count -eq 0 -and
            $recoveryMissingDefinitions.Count -eq 0
        ) `
        -Name 'ServiceRecovery/ModuleManifestExportsPublicApi' `
        -Failure ("modules\BRAVO.ServiceRecovery має містити .psm1 і .psd1 (PowerShellVersion 3.0), що експортує рівно публічний API хвиль 3–5; " +
            "файли=$recoveryFilesPresent PSVersion='$recoveryManifestPsVersion' експорт=[$($recoveryManifestExports -join ', ')] " +
            "без визначення=[$($recoveryMissingDefinitions -join ', ')]")

    # ============================================================
    # Тестовий модуль: заглушка шляху state у TEMP + усі функції
    # BRAVO.ServiceRecovery + атомарний запис із BRAVO.System. Самотест
    # ніколи не торкається справжнього %ProgramData%\BRAVO\State.
    # ============================================================
    $recoveryModuleText = [IO.File]::ReadAllText($recoveryModulePath, [Text.Encoding]::UTF8)
    $recoverySystemText = [IO.File]::ReadAllText(
        (Join-Path $root 'modules\BRAVO.System\BRAVO.System.psm1'),
        [Text.Encoding]::UTF8
    )
    $recoveryPathStub = @'
function Get-BRAVOServiceRecoveryStatePath {
    if ([string]::IsNullOrWhiteSpace($script:BRAVOSelfTestRecoveryStatePath)) {
        throw 'self-test: шлях recovery-стану не ініціалізовано'
    }
    return $script:BRAVOSelfTestRecoveryStatePath
}
function Set-BRAVOSelfTestRecoveryStatePath {
    param([string]$Path)
    $script:BRAVOSelfTestRecoveryStatePath = $Path
}
'@
    $recoveryFailingWriteStub = @'
function Write-BRAVOStateTemporaryText {
    param([string]$Path, [AllowEmptyString()][string]$Text)
    [IO.File]::WriteAllText($Path, $Text.Substring(0, [Math]::Min(7, $Text.Length)), (New-Object Text.UTF8Encoding($false)))
    throw 'self-test: імітований збій посеред запису state'
}
'@
    $recoveryModuleFunctionNames = @($recoveryDefinedFunctions | Where-Object { $_ -ne 'Get-BRAVOServiceRecoveryStatePath' } | Select-Object -Unique)
    $recoveryModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($recoveryPathStub + "`n" + $recoveryModuleText + "`n" + $recoverySystemText) `
        -FunctionNames (@('Get-BRAVOServiceRecoveryStatePath', 'Set-BRAVOSelfTestRecoveryStatePath') +
            $recoveryModuleFunctionNames + @('Write-BRAVOStateTemporaryText', 'Write-BRAVOStateFileAtomic'))
    $recoveryFailingModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($recoveryPathStub + "`n" + $recoveryFailingWriteStub + "`n" + $recoveryModuleText + "`n" + $recoverySystemText) `
        -FunctionNames (@('Get-BRAVOServiceRecoveryStatePath', 'Set-BRAVOSelfTestRecoveryStatePath') +
            $recoveryModuleFunctionNames + @('Write-BRAVOStateTemporaryText', 'Write-BRAVOStateFileAtomic'))

    $t0 = New-Object DateTime(2026, 10, 7, 10, 0, 0, [DateTimeKind]::Local)

    # ============================================================
    # Політика і визначення «впалої» служби (§0.2, §0.3).
    # ============================================================
    $recoveryPolicy = & $recoveryModule { Get-BRAVOServiceRecoveryPolicy }
    Test-BRAVOCondition `
        -Condition (
            (@($recoveryPolicy.PauseMinutesByAttempt) -join ',') -eq '0,5,15' -and
            [int]$recoveryPolicy.PauseMinutesCeiling -eq 60 -and
            [int]$recoveryPolicy.WindowHours -eq 24 -and
            [int]$recoveryPolicy.CyclicThreshold -eq 3 -and
            [int]$recoveryPolicy.StableResetMinutes -eq 30 -and
            [string]$recoveryPolicy.TaskName -eq 'BRAVO_SERVICE_RECOVERY' -and
            [string]$recoveryPolicy.MarkerOwner -eq 'BRAVO_MAINTENANCE_RECOVER'
        ) `
        -Name 'ServiceRecovery/PolicyConstants' `
        -Failure 'Get-BRAVOServiceRecoveryPolicy: паузи 0/5/15, стеля 60 хв, вікно 24 год, поріг 3, стабільність 30 хв, задача BRAVO_SERVICE_RECOVERY, owner BRAVO_MAINTENANCE_RECOVER'

    $recoveryFailedCases = @(
        @{ Condition = 'Failed'; Status = 'Stopped'; Expected = $true },
        @{ Condition = 'Failed'; Status = 'Paused'; Expected = $false },
        @{ Condition = 'Disabled'; Status = 'Stopped'; Expected = $false },
        @{ Condition = 'OwnedByBravo'; Status = 'Stopped'; Expected = $false },
        @{ Condition = 'Running'; Status = 'Running'; Expected = $false }
    )
    $recoveryFailedMismatches = @()
    foreach ($recoveryFailedCase in $recoveryFailedCases) {
        $recoveryFailedActual = & $recoveryModule {
            param($Case)
            Test-BRAVOServiceRecoveryFailed -Condition ([pscustomobject]@{ Name = 'exchangAPI'; Condition = $Case.Condition; Status = $Case.Status })
        } $recoveryFailedCase
        if ([bool]$recoveryFailedActual -ne [bool]$recoveryFailedCase.Expected) {
            $recoveryFailedMismatches += ('{0}/{1}={2}' -f $recoveryFailedCase.Condition, $recoveryFailedCase.Status, $recoveryFailedActual)
        }
    }
    $recoveryFailedNull = & $recoveryModule { Test-BRAVOServiceRecoveryFailed -Condition $null }
    Test-BRAVOCondition `
        -Condition ($recoveryFailedMismatches.Count -eq 0 -and -not [bool]$recoveryFailedNull) `
        -Name 'ServiceRecovery/FailedMeansFailedAndStopped' `
        -Failure "«впала» = Condition Failed І Status Stopped (Paused/Disabled/OwnedByBravo/Running/null — ні); розбіжності: [$($recoveryFailedMismatches -join ', ')] null=$recoveryFailedNull"

    # ============================================================
    # Тест 3: паузи, ковзне вікно, скидання після 30 хв стабільності,
    # нічний прогін ігнорує паузу, але рахує спробу.
    # ============================================================
    $ladder = & $recoveryModule {
        param($T0)
        $steps = @()
        $state = $null
        $d = Get-BRAVOServiceRecoveryAttemptDecision -State $state -ServiceName 'exchangAPI' -Now $T0
        $steps += ('{0}:{1}:{2}' -f $d.AttemptNumber, $d.PauseMinutes, $d.Allowed)
        $state = (Register-BRAVOServiceRecoveryAttempt -State $state -ServiceName 'exchangAPI' -Now $T0).State
        $d = Get-BRAVOServiceRecoveryAttemptDecision -State $state -ServiceName 'exchangAPI' -Now $T0.AddMinutes(4)
        $steps += ('{0}:{1}:{2}' -f $d.AttemptNumber, $d.PauseMinutes, $d.Allowed)
        $d = Get-BRAVOServiceRecoveryAttemptDecision -State $state -ServiceName 'exchangAPI' -Now $T0.AddMinutes(5)
        $steps += ('{0}:{1}:{2}' -f $d.AttemptNumber, $d.PauseMinutes, $d.Allowed)
        $state = (Register-BRAVOServiceRecoveryAttempt -State $state -ServiceName 'exchangAPI' -Now $T0.AddMinutes(5)).State
        $d = Get-BRAVOServiceRecoveryAttemptDecision -State $state -ServiceName 'exchangAPI' -Now $T0.AddMinutes(19)
        $steps += ('{0}:{1}:{2}' -f $d.AttemptNumber, $d.PauseMinutes, $d.Allowed)
        $d = Get-BRAVOServiceRecoveryAttemptDecision -State $state -ServiceName 'exchangAPI' -Now $T0.AddMinutes(20)
        $steps += ('{0}:{1}:{2}' -f $d.AttemptNumber, $d.PauseMinutes, $d.Allowed)
        $state = (Register-BRAVOServiceRecoveryAttempt -State $state -ServiceName 'exchangAPI' -Now $T0.AddMinutes(20)).State
        $d = Get-BRAVOServiceRecoveryAttemptDecision -State $state -ServiceName 'exchangAPI' -Now $T0.AddMinutes(79)
        $steps += ('{0}:{1}:{2}' -f $d.AttemptNumber, $d.PauseMinutes, $d.Allowed)
        $d = Get-BRAVOServiceRecoveryAttemptDecision -State $state -ServiceName 'exchangAPI' -Now $T0.AddMinutes(80)
        $steps += ('{0}:{1}:{2}' -f $d.AttemptNumber, $d.PauseMinutes, $d.Allowed)
        $state = (Register-BRAVOServiceRecoveryAttempt -State $state -ServiceName 'exchangAPI' -Now $T0.AddMinutes(80)).State
        $d = Get-BRAVOServiceRecoveryAttemptDecision -State $state -ServiceName 'exchangAPI' -Now $T0.AddMinutes(140)
        $steps += ('{0}:{1}:{2}' -f $d.AttemptNumber, $d.PauseMinutes, $d.Allowed)
        $other = Get-BRAVOServiceRecoveryAttemptDecision -State $state -ServiceName 'BRAVO' -Now $T0.AddMinutes(140)
        $steps += ('other {0}:{1}:{2}' -f $other.AttemptNumber, $other.PauseMinutes, $other.Allowed)
        return ($steps -join ' | ')
    } $t0
    $ladderExpected = '1:0:True | 2:5:False | 2:5:True | 3:15:False | 3:15:True | 4:60:False | 4:60:True | 5:60:True | other 1:0:True'
    Test-BRAVOCondition `
        -Condition ($ladder -eq $ladderExpected) `
        -Name 'ServiceRecovery/PauseLadder0-5-15-60' `
        -Failure "паузи між спробами 0/5/15/60 хв (далі 60), облік окремо для кожної служби; очікувалось [$ladderExpected], отримано [$ladder]"

    $window = & $recoveryModule {
        param($T0)
        $state = $null
        foreach ($minutes in @(0, 5, 20)) {
            $state = (Register-BRAVOServiceRecoveryAttempt -State $state -ServiceName 'exchangAPI' -Now $T0.AddMinutes($minutes)).State
        }
        $slid = Get-BRAVOServiceRecoveryAttemptDecision -State $state -ServiceName 'exchangAPI' -Now $T0.AddHours(24).AddMinutes(1)
        $pruned = Remove-BRAVOServiceRecoveryExpiredAttempts -State $state -Now $T0.AddHours(24).AddMinutes(1)
        $gone = Get-BRAVOServiceRecoveryAttemptDecision -State $state -ServiceName 'exchangAPI' -Now $T0.AddHours(24).AddMinutes(21)
        $prunedAll = Remove-BRAVOServiceRecoveryExpiredAttempts -State $state -Now $T0.AddHours(24).AddMinutes(21)
        return [pscustomobject]@{
            SlidAttempt     = $slid.AttemptNumber
            SlidPause       = $slid.PauseMinutes
            PrunedCount     = @($pruned.services['exchangAPI'].attempts).Count
            OriginalCount   = @($state.services['exchangAPI'].attempts).Count
            GoneAttempt     = $gone.AttemptNumber
            GonePause       = $gone.PauseMinutes
            PrunedAllHasKey = $prunedAll.services.ContainsKey('exchangAPI')
        }
    } $t0
    Test-BRAVOCondition `
        -Condition (
            [int]$window.SlidAttempt -eq 3 -and [int]$window.SlidPause -eq 15 -and
            [int]$window.PrunedCount -eq 2 -and [int]$window.OriginalCount -eq 3 -and
            [int]$window.GoneAttempt -eq 1 -and [int]$window.GonePause -eq 0 -and
            -not [bool]$window.PrunedAllHasKey
        ) `
        -Name 'ServiceRecovery/WindowSlides24h' `
        -Failure ("спроби старші за 24 год не рахуються і прибираються (вхідний стан не змінюється); отримано: " +
            "slid=$($window.SlidAttempt)/$($window.SlidPause) pruned=$($window.PrunedCount) original=$($window.OriginalCount) " +
            "gone=$($window.GoneAttempt)/$($window.GonePause) keyLeft=$($window.PrunedAllHasKey)")

    $stable = & $recoveryModule {
        param($T0)
        $state = $null
        $state = (Register-BRAVOServiceRecoveryAttempt -State $state -ServiceName 'exchangAPI' -Now $T0).State
        $state = (Register-BRAVOServiceRecoveryAttempt -State $state -ServiceName 'exchangAPI' -Now $T0.AddMinutes(5)).State
        $first = Register-BRAVOServiceRecoveryStableObservation -State $state -ServiceName 'exchangAPI' -Now $T0.AddMinutes(10)
        $early = Register-BRAVOServiceRecoveryStableObservation -State $first.State -ServiceName 'exchangAPI' -Now $T0.AddMinutes(39)
        $late = Register-BRAVOServiceRecoveryStableObservation -State $early.State -ServiceName 'exchangAPI' -Now $T0.AddMinutes(40)
        $after = Get-BRAVOServiceRecoveryAttemptDecision -State $late.State -ServiceName 'exchangAPI' -Now $T0.AddMinutes(41)
        # Нова спроба між спостереженнями скидає stableSince: відлік 30 хв — заново.
        $restarted = (Register-BRAVOServiceRecoveryAttempt -State $first.State -ServiceName 'exchangAPI' -Now $T0.AddMinutes(20)).State
        $againFirst = Register-BRAVOServiceRecoveryStableObservation -State $restarted -ServiceName 'exchangAPI' -Now $T0.AddMinutes(45)
        $unknown = Register-BRAVOServiceRecoveryStableObservation -State $state -ServiceName 'BRAVO' -Now $T0.AddMinutes(45)
        return [pscustomobject]@{
            FirstChanged      = [bool]$first.Changed
            FirstReset        = [bool]$first.Reset
            FirstStableSet    = ($null -ne $first.State.services['exchangAPI'].stableSince)
            EarlyChanged      = [bool]$early.Changed
            LateReset         = [bool]$late.Reset
            AfterAttempt      = $after.AttemptNumber
            AfterPause        = $after.PauseMinutes
            RestartedCleared  = ($null -eq $restarted.services['exchangAPI'].stableSince)
            AgainFirstChanged = [bool]$againFirst.Changed
            AgainFirstReset   = [bool]$againFirst.Reset
            UnknownChanged    = [bool]$unknown.Changed
        }
    } $t0
    Test-BRAVOCondition `
        -Condition (
            $stable.FirstChanged -and -not $stable.FirstReset -and $stable.FirstStableSet -and
            -not $stable.EarlyChanged -and $stable.LateReset -and
            [int]$stable.AfterAttempt -eq 1 -and [int]$stable.AfterPause -eq 0 -and
            $stable.RestartedCleared -and $stable.AgainFirstChanged -and -not $stable.AgainFirstReset -and
            -not $stable.UnknownChanged
        ) `
        -Name 'ServiceRecovery/StableFor30MinResets' `
        -Failure ("Running >= 30 хв після першого спостереження скидає облік спроб; нова спроба скидає stableSince; служба без обліку не змінює стан; отримано: " +
            "first=$($stable.FirstChanged)/$($stable.FirstReset)/$($stable.FirstStableSet) early=$($stable.EarlyChanged) late=$($stable.LateReset) " +
            "after=$($stable.AfterAttempt)/$($stable.AfterPause) restartedCleared=$($stable.RestartedCleared) " +
            "again=$($stable.AgainFirstChanged)/$($stable.AgainFirstReset) unknown=$($stable.UnknownChanged)")

    $nightly = & $recoveryModule {
        param($T0)
        $state = (Register-BRAVOServiceRecoveryAttempt -State $null -ServiceName 'BRAVO' -Now $T0).State
        $ignored = Get-BRAVOServiceRecoveryAttemptDecision -State $state -ServiceName 'BRAVO' -Now $T0.AddMinutes(1) -IgnorePause
        $paused = Get-BRAVOServiceRecoveryAttemptDecision -State $state -ServiceName 'BRAVO' -Now $T0.AddMinutes(1)
        $counted = Register-BRAVOServiceRecoveryAttempt -State $state -ServiceName 'BRAVO' -Now $T0.AddMinutes(1)
        return [pscustomobject]@{
            IgnoredAllowed = [bool]$ignored.Allowed
            IgnoredReason  = [string]$ignored.Reason
            IgnoredNumber  = $ignored.AttemptNumber
            IgnoredPause   = $ignored.PauseMinutes
            PausedAllowed  = [bool]$paused.Allowed
            PausedReason   = [string]$paused.Reason
            CountedNumber  = $counted.AttemptNumber
            CountedTotal   = @($counted.State.services['BRAVO'].attempts).Count
        }
    } $t0
    Test-BRAVOCondition `
        -Condition (
            $nightly.IgnoredAllowed -and $nightly.IgnoredReason -eq 'PauseIgnored' -and
            [int]$nightly.IgnoredNumber -eq 2 -and [int]$nightly.IgnoredPause -eq 5 -and
            -not $nightly.PausedAllowed -and $nightly.PausedReason -eq 'PauseActive' -and
            [int]$nightly.CountedNumber -eq 2 -and [int]$nightly.CountedTotal -eq 2
        ) `
        -Name 'ServiceRecovery/NightlyIgnoresPauseButCounts' `
        -Failure ("-IgnorePause (нічний Maintenance) дозволяє запуск під час паузи, але спроба рахується; отримано: " +
            "ignored=$($nightly.IgnoredAllowed)/$($nightly.IgnoredReason)/$($nightly.IgnoredNumber)/$($nightly.IgnoredPause) " +
            "paused=$($nightly.PausedAllowed)/$($nightly.PausedReason) counted=$($nightly.CountedNumber)/$($nightly.CountedTotal)")

    # ============================================================
    # Тест 4: state-файл.
    # ============================================================
    $recoveryTestRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'bravo_selftest_recovery_{0}' -f ([guid]::NewGuid().ToString('N'))
    )
    [void][IO.Directory]::CreateDirectory($recoveryTestRoot)
    try {
        $recoveryStatePath = Join-Path $recoveryTestRoot 'BRAVO_SERVICE_RECOVERY_STATE.json'
        foreach ($recoveryPathModule in @($recoveryModule, $recoveryFailingModule)) {
            & $recoveryPathModule { param($Path) Set-BRAVOSelfTestRecoveryStatePath -Path $Path } $recoveryStatePath
        }
        $recoveryUtf8NoBom = New-Object Text.UTF8Encoding($false)
        $recoveryUtf8Bom = New-Object Text.UTF8Encoding($true)
        $recoveryLeftovers = {
            param([string]$Directory)
            @([IO.Directory]::GetFiles($Directory) |
                    Where-Object { [IO.Path]::GetFileName($_) -like '.*.tmp' -or [IO.Path]::GetFileName($_) -like '.*.bak' })
        }
        $recoveryQuarantined = {
            param([string]$Directory)
            @([IO.Directory]::GetFiles($Directory) |
                    Where-Object { [IO.Path]::GetFileName($_) -like 'BRAVO_SERVICE_RECOVERY_STATE.json.corrupt-*' })
        }
        $recoveryClear = {
            param([string]$Directory)
            foreach ($recoveryClearFile in @([IO.Directory]::GetFiles($Directory))) { [IO.File]::Delete($recoveryClearFile) }
        }

        # --- StateMissingIsEmpty ---
        $missing = & $recoveryModule { Read-BRAVOServiceRecoveryState }
        Test-BRAVOCondition `
            -Condition (
                [string]$missing.Status -eq 'Missing' -and
                $null -eq $missing.Warning -and $null -eq $missing.QuarantinedPath -and
                $null -ne $missing.State -and [int]$missing.State.schemaVersion -eq 1 -and
                @($missing.State.services.Keys).Count -eq 0
            ) `
            -Name 'ServiceRecovery/StateMissingIsEmpty' `
            -Failure "відсутній state-файл -> Status Missing, порожній стан schemaVersion 1, без Warning; отримано Status=$($missing.Status) Warning=$($missing.Warning)"

        # --- StateCorruptIsQuarantinedAndNotBlocking ---
        $corruptProblems = @()
        foreach ($corruptBody in @('garbage{{{', '{"schemaVersion":99,"hostname":"HOST-01","services":{}}', ('{{"schemaVersion":1,"hostname":"{0}"}}' -f [Environment]::MachineName))) {
            & $recoveryClear $recoveryTestRoot
            [IO.File]::WriteAllText($recoveryStatePath, $corruptBody, $recoveryUtf8NoBom)
            $corrupt = & $recoveryModule { Read-BRAVOServiceRecoveryState }
            $corruptDecision = & $recoveryModule {
                param($State, $Now)
                Get-BRAVOServiceRecoveryAttemptDecision -State $State -ServiceName 'exchangAPI' -Now $Now
            } $corrupt.State $t0
            $corruptOk = (
                [string]$corrupt.Status -eq 'Corrupt' -and
                -not [string]::IsNullOrWhiteSpace([string]$corrupt.Warning) -and
                -not [string]::IsNullOrWhiteSpace([string]$corrupt.QuarantinedPath) -and
                [IO.File]::Exists([string]$corrupt.QuarantinedPath) -and
                -not [IO.File]::Exists($recoveryStatePath) -and
                @(& $recoveryQuarantined $recoveryTestRoot).Count -eq 1 -and
                @($corrupt.State.services.Keys).Count -eq 0 -and
                [bool]$corruptDecision.Allowed -and [int]$corruptDecision.AttemptNumber -eq 1
            )
            if (-not $corruptOk) {
                $corruptProblems += ("'{0}': Status={1} Quarantined={2} Allowed={3}" -f $corruptBody, $corrupt.Status, $corrupt.QuarantinedPath, $corruptDecision.Allowed)
            }
        }
        Test-BRAVOCondition `
            -Condition ($corruptProblems.Count -eq 0) `
            -Name 'ServiceRecovery/StateCorruptIsQuarantinedAndNotBlocking' `
            -Failure ("нерозбірний JSON, невідома schemaVersion чи відсутні services -> Status Corrupt, файл у .corrupt-<ts>, Warning, порожній стан і запуск НЕ блокується; проблеми: " +
                ($corruptProblems -join ' | '))

        # --- StateForeignHostIsQuarantined ---
        & $recoveryClear $recoveryTestRoot
        $foreignHost = 'HOST-01'
        if ([Environment]::MachineName -ieq $foreignHost) { $foreignHost = 'HOST-02' }
        [IO.File]::WriteAllText(
            $recoveryStatePath,
            ('{{"schemaVersion":1,"hostname":"{0}","updatedAt":null,"services":{{"exchangAPI":{{"attempts":["{1}"],"lastCriticalAt":null,"stableSince":null}}}}}}' -f
                $foreignHost, $t0.ToString('o', [Globalization.CultureInfo]::InvariantCulture)),
            $recoveryUtf8NoBom)
        $foreign = & $recoveryModule { Read-BRAVOServiceRecoveryState }
        Test-BRAVOCondition `
            -Condition (
                [string]$foreign.Status -eq 'ForeignHost' -and
                -not [string]::IsNullOrWhiteSpace([string]$foreign.Warning) -and
                [IO.File]::Exists([string]$foreign.QuarantinedPath) -and
                -not [IO.File]::Exists($recoveryStatePath) -and
                @($foreign.State.services.Keys).Count -eq 0
            ) `
            -Name 'ServiceRecovery/StateForeignHostIsQuarantined' `
            -Failure "state з чужим hostname (перенесений комплект) -> Status ForeignHost, карантин, порожній стан; отримано Status=$($foreign.Status) Quarantined=$($foreign.QuarantinedPath)"

        # --- StateWithBomIsReadable ---
        & $recoveryClear $recoveryTestRoot
        [IO.File]::WriteAllText(
            $recoveryStatePath,
            ('{{"schemaVersion":1,"hostname":"{0}","updatedAt":"{1}","services":{{"exchangAPI":{{"attempts":["{1}"],"lastCriticalAt":null,"stableSince":null}}}}}}' -f
                [Environment]::MachineName, $t0.ToString('o', [Globalization.CultureInfo]::InvariantCulture)),
            $recoveryUtf8Bom)
        $bom = & $recoveryModule { Read-BRAVOServiceRecoveryState }
        $bomDecision = & $recoveryModule {
            param($State, $Now)
            Get-BRAVOServiceRecoveryAttemptDecision -State $State -ServiceName 'exchangAPI' -Now $Now
        } $bom.State $t0.AddMinutes(1)
        Test-BRAVOCondition `
            -Condition (
                [string]$bom.Status -eq 'Ok' -and $null -eq $bom.Warning -and
                [IO.File]::Exists($recoveryStatePath) -and
                @($bom.State.services['exchangAPI'].attempts).Count -eq 1 -and
                [int]$bomDecision.AttemptNumber -eq 2 -and [int]$bomDecision.PauseMinutes -eq 5 -and
                -not [bool]$bomDecision.Allowed
            ) `
            -Name 'ServiceRecovery/StateWithBomIsReadable' `
            -Failure "state з UTF-8 BOM (записаний не BRAVO) читається як Ok і рахує спроби; отримано Status=$($bom.Status) attempt=$($bomDecision.AttemptNumber) pause=$($bomDecision.PauseMinutes)"

        # --- StateWriteIsAtomicNoBom ---
        & $recoveryClear $recoveryTestRoot
        & $recoveryModule {
            param($Now)
            $state = (Register-BRAVOServiceRecoveryAttempt -State $null -ServiceName 'exchangAPI' -Now $Now).State
            $state = Register-BRAVOServiceRecoveryCriticalSent -State $state -ServiceName 'exchangAPI' -Now $Now
            Write-BRAVOServiceRecoveryState -State $state -Now $Now
        } $t0
        $writtenBytes = [IO.File]::ReadAllBytes($recoveryStatePath)
        $writtenJson = [IO.File]::ReadAllText($recoveryStatePath) | ConvertFrom-Json
        $writtenRead = & $recoveryModule { Read-BRAVOServiceRecoveryState }
        $writtenLeftovers = @(& $recoveryLeftovers $recoveryTestRoot)
        $failingThrew = $false
        try {
            & $recoveryFailingModule {
                param($Now)
                $state = (Register-BRAVOServiceRecoveryAttempt -State $null -ServiceName 'BRAVO' -Now $Now).State
                Write-BRAVOServiceRecoveryState -State $state -Now $Now
            } $t0.AddMinutes(1)
        } catch {
            $failingThrew = $true
        }
        $afterFailureBytes = [IO.File]::ReadAllBytes($recoveryStatePath)
        $afterFailureLeftovers = @(& $recoveryLeftovers $recoveryTestRoot)
        Test-BRAVOCondition `
            -Condition (
                $writtenBytes.Length -gt 3 -and
                -not ($writtenBytes[0] -eq 0xEF -and $writtenBytes[1] -eq 0xBB -and $writtenBytes[2] -eq 0xBF) -and
                [int]$writtenJson.schemaVersion -eq 1 -and
                [string]$writtenJson.hostname -eq [Environment]::MachineName -and
                $null -ne $writtenJson.updatedAt -and
                @($writtenJson.services.exchangAPI.attempts).Count -eq 1 -and
                $null -ne $writtenJson.services.exchangAPI.lastCriticalAt -and
                [string]$writtenRead.Status -eq 'Ok' -and
                @($writtenRead.State.services['exchangAPI'].attempts).Count -eq 1 -and
                $writtenLeftovers.Count -eq 0 -and
                $failingThrew -and
                [Convert]::ToBase64String($afterFailureBytes) -eq [Convert]::ToBase64String($writtenBytes) -and
                $afterFailureLeftovers.Count -eq 0
            ) `
            -Name 'ServiceRecovery/StateWriteIsAtomicNoBom' `
            -Failure ("запис state — UTF-8 без BOM, schemaVersion/hostname/updatedAt/services, round-trip Ok, без .tmp/.bak; збій посеред запису лишає попередній файл байт-у-байт; " +
                "отримано: bytes=$($writtenBytes.Length) read=$($writtenRead.Status) leftovers=$($writtenLeftovers.Count) threw=$failingThrew afterLeftovers=$($afterFailureLeftovers.Count)")
    } finally {
        if ([IO.Directory]::Exists($recoveryTestRoot)) {
            Remove-Item -LiteralPath $recoveryTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # ============================================================
    # Тест 10: тексти сповіщень і CRITICAL «циклічно падає» не частіше
    # разу на 24 год.
    # ============================================================
    $texts = & $recoveryModule {
        param($T0)
        $condition = [pscustomobject]@{ Name = 'exchangAPI'; Condition = 'Failed'; Status = 'Stopped'; ExitCode = 1067 }
        $scmEvent = [pscustomobject]@{ Id = 7031; TimeCreated = $T0.AddMinutes(1) }
        $logPath = 'C:\LOGS\BRAVO_MAINTENANCE.log'
        return [pscustomobject]@{
            Recovered   = New-BRAVOServiceRecoveryNotificationText -Kind Recovered -ServiceName 'exchangAPI' -Condition $condition -AttemptNumber 2 -LogPath $logPath -LastScmEvent $scmEvent
            Unknown     = New-BRAVOServiceRecoveryNotificationText -Kind Recovered -ServiceName 'exchangAPI' -Condition $null -AttemptNumber 1 -LogPath $logPath
            StartFailed = New-BRAVOServiceRecoveryNotificationText -Kind StartFailed -ServiceName 'BRAVO' -Condition $condition -AttemptNumber 1 -LogPath $logPath -FailureReason 'таймаут запуску'
            Cyclic      = New-BRAVOServiceRecoveryNotificationText -Kind Cyclic -ServiceName 'exchangAPI' -Condition $condition -AttemptNumber 3 -LogPath $logPath -FirstAttemptAt $T0
        }
    } $t0
    $textsExpected = [ordered]@{
        Recovered   = 'Служба exchangAPI впала (ExitCode 1067, подія 7031 о 10:01), журнали збережено, запущена. Спроба 2 за добу. Журнал: C:\LOGS\BRAVO_MAINTENANCE.log'
        Unknown     = 'Служба exchangAPI впала (ExitCode невідомий), журнали збережено, запущена. Спроба 1 за добу. Журнал: C:\LOGS\BRAVO_MAINTENANCE.log'
        StartFailed = 'Не вдалося запустити службу BRAVO після падіння (ExitCode 1067): таймаут запуску. Спроба 1 за добу. Журнал: C:\LOGS\BRAVO_MAINTENANCE.log'
        Cyclic      = 'Служба exchangAPI циклічно падає: 3 падінь з 07.10 10:00, потрібне втручання. Журнал: C:\LOGS\BRAVO_MAINTENANCE.log'
    }
    $textsMismatches = @()
    foreach ($textKind in @($textsExpected.Keys)) {
        if ([string]$texts.$textKind -cne [string]$textsExpected[$textKind]) {
            $textsMismatches += ("{0}: '{1}'" -f $textKind, $texts.$textKind)
        }
    }
    Test-BRAVOCondition `
        -Condition ($textsMismatches.Count -eq 0) `
        -Name 'ServiceRecovery/NotificationTexts' `
        -Failure ("тексти Recovered/StartFailed/Cyclic (FR-6) українською з ExitCode, номером спроби і журналом; розбіжності: " + ($textsMismatches -join ' | '))

    $cyclic = & $recoveryModule {
        param($T0)
        $dueAt = @()
        $state = $null
        foreach ($minutes in @(0, 5, 20)) {
            $registered = Register-BRAVOServiceRecoveryAttempt -State $state -ServiceName 'exchangAPI' -Now $T0.AddMinutes($minutes)
            $state = $registered.State
            if ($registered.CyclicAlertDue) {
                $dueAt += $minutes
                $state = Register-BRAVOServiceRecoveryCriticalSent -State $state -ServiceName 'exchangAPI' -Now $T0.AddMinutes($minutes)
            }
        }
        $firstAttemptAtThird = $null
        # Служба й далі падає щогодини: наступний CRITICAL — не раніше ніж
        # через 24 год після попереднього.
        for ($hour = 1; $hour -le 25; $hour++) {
            $minutes = 20 + $hour * 60
            $registered = Register-BRAVOServiceRecoveryAttempt -State $state -ServiceName 'exchangAPI' -Now $T0.AddMinutes($minutes)
            $state = $registered.State
            if ($registered.CyclicAlertDue) {
                $dueAt += $minutes
                $state = Register-BRAVOServiceRecoveryCriticalSent -State $state -ServiceName 'exchangAPI' -Now $T0.AddMinutes($minutes)
            }
        }
        $fresh = Register-BRAVOServiceRecoveryAttempt -State $null -ServiceName 'BRAVO' -Now $T0
        $fresh = Register-BRAVOServiceRecoveryAttempt -State $fresh.State -ServiceName 'BRAVO' -Now $T0.AddMinutes(5)
        $third = Register-BRAVOServiceRecoveryAttempt -State $fresh.State -ServiceName 'BRAVO' -Now $T0.AddMinutes(20)
        $firstAttemptAtThird = $third.FirstAttemptAt
        return [pscustomobject]@{
            DueAt          = ($dueAt -join ',')
            SecondDue      = [bool]$fresh.CyclicAlertDue
            ThirdDue       = [bool]$third.CyclicAlertDue
            ThirdNumber    = $third.AttemptNumber
            ThirdFirstAt   = $firstAttemptAtThird
        }
    } $t0
    $cyclicExpectedDueAt = '20,{0}' -f (20 + 24 * 60)
    Test-BRAVOCondition `
        -Condition (
            [string]$cyclic.DueAt -eq $cyclicExpectedDueAt -and
            -not $cyclic.SecondDue -and $cyclic.ThirdDue -and [int]$cyclic.ThirdNumber -eq 3 -and
            $null -ne $cyclic.ThirdFirstAt -and ([datetime]$cyclic.ThirdFirstAt).ToUniversalTime() -eq $t0.ToUniversalTime()
        ) `
        -Name 'ServiceRecovery/CyclicCriticalAtMostOncePer24h' `
        -Failure ("CRITICAL «циклічно падає» — на 3-й спробі за 24 год, далі не частіше разу на добу; FirstAttemptAt — перша спроба у вікні; " +
            "очікувались хвилини [$cyclicExpectedDueAt], отримано [$($cyclic.DueAt)] second=$($cyclic.SecondDue) third=$($cyclic.ThirdDue)/$($cyclic.ThirdNumber) first=$($cyclic.ThirdFirstAt)")
}

# ============================================================
# #314 хвиля 3 (частина 2): нічний Maintenance піднімає впалу службу (FR-2)
# і сповіщає про це (FR-6). Статична частина тестів 7 і 10 + чистий план
# життєвого циклу з «впалою» службою (BRAVO.System, без Windows).
# Поведінку циклу служб (маркер, порядок запуску, облік спроб, сповіщення,
# guard -RunMissedRestoreOnly) перевіряє ServiceRecovery/NightlyMaintenance*
# на справжніх фрагментах runtime (ServiceQuiescence, пісочниця
# характеризації циклу служб).
# ============================================================
& {
    $nightlyRuntimeText = [IO.File]::ReadAllText(
        (Join-Path $root 'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1'), [Text.Encoding]::UTF8)
    $nightlyRuntimeAst = [Management.Automation.Language.Parser]::ParseInput($nightlyRuntimeText, [ref]$null, [ref]$null)
    $nightlyFindFunction = {
        param([string]$FunctionName)
        @($nightlyRuntimeAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName
                }, $true)) | Select-Object -First 1
    }
    $nightlyCommandCalls = {
        param($ScopeAst, [string]$CommandName)
        if ($null -eq $ScopeAst) { return @() }
        return @($ScopeAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq $CommandName
                }, $true))
    }
    $nightlyParameterValue = {
        # Значення іменованого параметра CommandAst (текст наступного елемента).
        param($CommandAst, [string]$ParameterName)
        $elements = @($CommandAst.CommandElements)
        for ($elementIndex = 0; $elementIndex -lt $elements.Count; $elementIndex++) {
            $element = $elements[$elementIndex]
            if ($element -is [Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -ieq $ParameterName) {
                if ($null -ne $element.Argument) { return $element.Argument.Extent.Text.Trim("'", '"') }
                if ($elementIndex + 1 -lt $elements.Count) { return $elements[$elementIndex + 1].Extent.Text.Trim("'", '"') }
                return ''
            }
        }
        return $null
    }

    # (тест 7а) Попередження «СЛУЖБИ НЕ ЗАПУЩЕНІ ПЕРЕД MAINTENANCE» прибрано:
    # зупинену (не Disabled) службу Maintenance тепер запускає, а не лише
    # повідомляє про неї. Runtime імпортує BRAVO.ServiceRecovery.
    $nightlyModuleImportLine = @($nightlyRuntimeText -split "`r?`n" | Where-Object { $_ -match "^foreach \(\`$moduleName in @\(" }) | Select-Object -First 1
    Test-BRAVOCondition `
        -Condition (
            -not $nightlyRuntimeText.Contains('Send-InactiveServiceWarning') -and
            -not $nightlyRuntimeText.Contains('СЛУЖБИ НЕ ЗАПУЩЕНІ ПЕРЕД MAINTENANCE') -and
            $null -ne $nightlyModuleImportLine -and
            $nightlyModuleImportLine.Contains("'BRAVO.ServiceRecovery'")
        ) `
        -Name 'ServiceRecovery/NightlyMaintenanceDropsInactiveServiceWarning' `
        -Failure "runtime Maintenance не має містити Send-InactiveServiceWarning і заголовка «СЛУЖБИ НЕ ЗАПУЩЕНІ ПЕРЕД MAINTENANCE» (#314 FR-2) і має імпортувати BRAVO.ServiceRecovery у списку спільних модулів; рядок імпорту: '$nightlyModuleImportLine'"

    # (тест 10, статична частина) Recovered — WARNING через Send-SlackAlert без
    # -IsCritical (служба піднята, прогін не провалений); Cyclic — CRITICAL без
    # -IsCritical; невдалий запуск впалої служби — текст StartFailed у
    # наявній CRITICAL-гілці (-IsCritical -> exit 60).
    $nightlyRecoveredFunction = & $nightlyFindFunction 'Send-BRAVOMaintenanceServiceRecoveredAlert'
    $nightlyRecoveredAlerts = @(& $nightlyCommandCalls $nightlyRecoveredFunction 'Send-SlackAlert')
    $nightlyRecoveredKinds = @(& $nightlyCommandCalls $nightlyRecoveredFunction 'New-BRAVOServiceRecoveryNotificationText' |
            ForEach-Object { & $nightlyParameterValue $_ 'Kind' })
    $nightlyRecoveredSeverities = @($nightlyRecoveredAlerts | ForEach-Object { & $nightlyParameterValue $_ 'Severity' })
    $nightlyRecoveredCriticalFlags = @($nightlyRecoveredAlerts | Where-Object { $null -ne (& $nightlyParameterValue $_ 'IsCritical') })
    $nightlyStartFunction = & $nightlyFindFunction 'Start-BRAVOMaintenanceManagedService'
    $nightlyStartFailedKinds = @(& $nightlyCommandCalls $nightlyStartFunction 'New-BRAVOServiceRecoveryNotificationText' |
            ForEach-Object { & $nightlyParameterValue $_ 'Kind' })
    $nightlyRecoveredCallers = @(& $nightlyCommandCalls $nightlyStartFunction 'Send-BRAVOMaintenanceServiceRecoveredAlert')
    Test-BRAVOCondition `
        -Condition (
            $null -ne $nightlyRecoveredFunction -and
            $nightlyRecoveredAlerts.Count -eq 2 -and
            (@($nightlyRecoveredSeverities | Sort-Object) -join ',') -eq 'CRITICAL,WARNING' -and
            $nightlyRecoveredCriticalFlags.Count -eq 0 -and
            (@($nightlyRecoveredKinds | Sort-Object) -join ',') -eq 'Cyclic,Recovered' -and
            $nightlyRecoveredFunction.Extent.Text.Contains('Register-BRAVOServiceRecoveryCriticalSent') -and
            $nightlyStartFailedKinds -contains 'StartFailed' -and
            $nightlyRecoveredCallers.Count -ge 1
        ) `
        -Name 'ServiceRecovery/NightlyRecoveredAlertIsWarningCyclicIsCritical' `
        -Failure ("Send-BRAVOMaintenanceServiceRecoveredAlert (виклик зі Start-BRAVOMaintenanceManagedService) має надсилати Recovered через Send-SlackAlert -Severity WARNING і Cyclic -Severity CRITICAL, обидва без -IsCritical, і фіксувати Register-BRAVOServiceRecoveryCriticalSent; невдалий запуск — текст StartFailed. " +
            "функція=$($null -ne $nightlyRecoveredFunction) алертів=$($nightlyRecoveredAlerts.Count) severity=[$($nightlyRecoveredSeverities -join ',')] -IsCritical=$($nightlyRecoveredCriticalFlags.Count) kinds=[$($nightlyRecoveredKinds -join ',')] startKinds=[$($nightlyStartFailedKinds -join ',')] викликів=$($nightlyRecoveredCallers.Count)")

    # Чистий план життєвого циклу (BRAVO.System): «впала» служба (Failed,
    # Stopped, керована) має намір перезапуску — входить у маркер із
    # RestartIntent, не зупиняється (вона вже зупинена) і запускається в
    # канонічному порядку. Некерована (Disabled оператором) — ні.
    $nightlyPlanModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ([IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.System\BRAVO.System.psm1'), [Text.Encoding]::UTF8)) `
        -FunctionNames @('Get-BRAVOManagedServiceOrder', 'Test-BRAVOManagedServiceActiveStatus', 'Test-BRAVOServiceStartRequired',
            'Get-BRAVOServiceStopDecision', 'Get-BRAVOManagedServiceRestartIntent', 'Get-BRAVOInheritedServiceRestartIntent',
            'Get-BRAVOServiceQuiescenceScope', 'Get-BRAVOManagedServiceLifecyclePlan')
    $nightlyPlanProbe = & $nightlyPlanModule {
        Set-StrictMode -Version 2.0
        $describe = {
            param($Plan)
            '{0} | stop: {1} | start: {2}' -f (@($Plan.QuiescenceServices | ForEach-Object { '{0}={1}' -f $_.Name, [bool]$_.RestartIntent }) -join ','),
                (@($Plan.StopOrder) -join ' '), (@($Plan.StartOrder) -join ' ')
        }
        $exchangeFailed = Get-BRAVOManagedServiceLifecyclePlan -Services @(
            @{ Key = 'Bravo'; Name = 'BRAVO'; Enabled = $true; Status = 'Running' },
            @{ Key = 'ExchangeApi'; Name = 'exchangAPI'; Enabled = $true; Status = 'Stopped'; Failed = $true },
            @{ Key = 'BravoWeb'; Name = 'Apache2.4'; Enabled = $true; Status = 'Running'; Failed = $false })
        $allFailedObjects = Get-BRAVOManagedServiceLifecyclePlan -Services @(
            [pscustomobject]@{ Key = 'Bravo'; Name = 'BRAVO'; Enabled = $true; Status = 'Stopped'; Failed = $true },
            [pscustomobject]@{ Key = 'ExchangeApi'; Name = 'exchangAPI'; Enabled = $true; Status = 'Stopped'; Failed = $true },
            [pscustomobject]@{ Key = 'BravoWeb'; Name = 'Apache2.4'; Enabled = $true; Status = 'Stopped'; Failed = $true })
        $failedButUnmanaged = Get-BRAVOManagedServiceLifecyclePlan -Services @(
            [pscustomobject]@{ Key = 'Bravo'; Name = 'BRAVO'; Enabled = $false; Status = 'Stopped'; Failed = $true },
            [pscustomobject]@{ Key = 'ExchangeApi'; Name = 'exchangAPI'; Enabled = $true; Status = 'Stopped'; Failed = $false },
            [pscustomobject]@{ Key = 'BravoWeb'; Name = 'Apache2.4'; Enabled = $true; Status = 'Running' })
        $legacyNoFailed = Get-BRAVOManagedServiceLifecyclePlan -Services @(
            [pscustomobject]@{ Key = 'ExchangeApi'; Name = 'exchangAPI'; Enabled = $true; Status = 'Stopped' })
        return [pscustomobject]@{
            ExchangeFailed = (& $describe $exchangeFailed)
            AllFailed = (& $describe $allFailedObjects)
            Unmanaged = (& $describe $failedButUnmanaged)
            Legacy = (& $describe $legacyNoFailed)
        }
    }
    $nightlyPlanExpected = [ordered]@{
        ExchangeFailed = 'BRAVO=True,exchangAPI=True,Apache2.4=True | stop: Apache2.4 BRAVO | start: BRAVO exchangAPI Apache2.4'
        AllFailed = 'BRAVO=True,exchangAPI=True,Apache2.4=True | stop:  | start: BRAVO exchangAPI Apache2.4'
        Unmanaged = 'Apache2.4=True | stop: Apache2.4 | start: Apache2.4'
        Legacy = ' | stop:  | start: '
    }
    $nightlyPlanDiffs = @($nightlyPlanExpected.Keys | Where-Object { [string]$nightlyPlanProbe.$_ -cne [string]$nightlyPlanExpected[$_] } |
            ForEach-Object { "${_}: '$($nightlyPlanProbe.$_)' (очікувалось '$($nightlyPlanExpected[$_])')" })
    Test-BRAVOCondition `
        -Condition ($nightlyPlanDiffs.Count -eq 0) `
        -Name 'ServiceRecovery/LifecyclePlanStartsFailedService' `
        -Failure "керована «впала» служба (Failed=`$true) має входити в маркер із RestartIntent і запускатися в порядку BRAVO -> exchangAPI -> BRAVO Web без зупинки; некерована чи без Failed — ні: $($nightlyPlanDiffs -join ' || ')"
}

# ============================================================
# #314 хвиля 4 (FR-3): профіль BRAVO_MAINTENANCE.ps1 -RecoverServices.
#   Тест 2 — чистий план ланцюжка Get-BRAVOServiceRecoveryChainPlan
#            (канонічний порядок BRAVO -> exchangAPI -> BRAVO Web; впала
#            BRAVO -> зупинка залежних і запуск усіх).
#   Тест 5 — lock зайнятий: вихід 20 без змін, сповіщень і журналу;
#            -NoWait не чекає lock.
#   Тест 6 — маркер із restartSuppressed / чужий живий власник: нічого не
#            запускати (класифікація і гонка під lock-ом).
#   Решта  — оркестратор профілю на справжньому тексті runtime зі стабами
#            побічних дій (Linux, без SCM/WMI), селектор подій SCM, проводка
#            параметра і статичні заборони профілю.
# ============================================================
& {
    $w4RuntimeText = [IO.File]::ReadAllText(
        (Join-Path $root 'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1'), [Text.Encoding]::UTF8)
    $w4ModuleText = [IO.File]::ReadAllText(
        (Join-Path $root 'modules\BRAVO.ServiceRecovery\BRAVO.ServiceRecovery.psm1'), [Text.Encoding]::UTF8)
    $w4SystemText = [IO.File]::ReadAllText(
        (Join-Path $root 'modules\BRAVO.System\BRAVO.System.psm1'), [Text.Encoding]::UTF8)
    $w4EntryText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_MAINTENANCE.ps1'), [Text.Encoding]::UTF8)
    $w4RuntimeAst = [Management.Automation.Language.Parser]::ParseInput($w4RuntimeText, [ref]$null, [ref]$null)
    $w4FunctionNamesIn = {
        param([string]$Text)
        $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
        return @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst]
                }, $true) | ForEach-Object { $_.Name } | Select-Object -Unique)
    }
    $w4ModuleFunctions = @(& $w4FunctionNamesIn $w4ModuleText)
    $w4FindRuntimeFunction = {
        param([string]$FunctionName)
        @($w4RuntimeAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName
                }, $true)) | Select-Object -First 1
    }
    # Тестовий модуль лише з тих функцій, що справді є в тексті: до
    # реалізації (RED) відсутня функція дає збій виклику всередині тесту, а
    # не падіння всього фрагмента.
    $w4NewModule = {
        param([string]$SourceText, [string[]]$FunctionNames)
        $available = @(& $w4FunctionNamesIn $SourceText)
        $present = @($FunctionNames | Select-Object -Unique | Where-Object { $available -contains $_ })
        $module = New-BRAVOSelfTestRuntimeModule -SourceText $SourceText -FunctionNames $present
        # New-Module імпортує заглушки в глобальну область: заглушки
        # командлетів (Write-Host, Get-/Start-/Stop-Service, Start-Sleep)
        # потрібні лише всередині модуля — глобальна копія гасила б вивід
        # самотесту і справжні командлети наступних перевірок.
        foreach ($stubName in $present) {
            if ($null -eq (Get-Command -Name $stubName -CommandType Cmdlet -ErrorAction SilentlyContinue)) { continue }
            $leaked = Get-Command -Name $stubName -CommandType Function -ErrorAction SilentlyContinue
            if ($null -ne $leaked -and $leaked.ModuleName -eq $module.Name) {
                Remove-Item -Path ('function:' + $stubName) -Force -ErrorAction Stop
            }
        }
        return $module
    }

    # ============================================================
    # Тест 2: план ланцюжка (чиста функція модуля).
    # ============================================================
    $w4ChainModule = & $w4NewModule ($w4ModuleText + "`n" + $w4SystemText) (@($w4ModuleFunctions) + @('Get-BRAVOManagedServiceOrder'))
    $w4ChainError = $null
    $w4Chain = $null
    try {
        $w4Chain = & $w4ChainModule {
            Set-StrictMode -Version 2.0
            $c = {
                param([string]$Key, [string]$Name, [string]$Condition, [string]$Status)
                [pscustomobject]@{ Key = $Key; Name = $Name; Condition = $Condition; Status = $Status }
            }
            $describe = {
                param($Plan)
                'failed: {0} | stop: {1} | start: {2} | deferred: {3} | accounted: {4}' -f (@($Plan.FailedNames) -join ' '),
                    (@($Plan.StopOrder) -join ' '), (@($Plan.StartOrder) -join ' '), (@($Plan.Deferred) -join ' '),
                    (@($Plan.AccountedNames) -join ' ')
            }
            $result = [ordered]@{}
            $result.BravoFailed = & $describe (Get-BRAVOServiceRecoveryChainPlan -Conditions @(
                    (& $c 'Bravo' 'BRAVO' 'Failed' 'Stopped'),
                    (& $c 'ExchangeApi' 'exchangAPI' 'Running' 'Running'),
                    (& $c 'BravoWeb' 'Apache2.4' 'Running' 'Running')))
            $result.ExchangeOnly = & $describe (Get-BRAVOServiceRecoveryChainPlan -Conditions @(
                    (& $c 'Bravo' 'BRAVO' 'Running' 'Running'),
                    (& $c 'ExchangeApi' 'exchangAPI' 'Failed' 'Stopped'),
                    (& $c 'BravoWeb' 'Apache2.4' 'Running' 'Running')))
            $result.WebOnly = & $describe (Get-BRAVOServiceRecoveryChainPlan -Conditions @(
                    (& $c 'Bravo' 'BRAVO' 'Running' 'Running'),
                    (& $c 'ExchangeApi' 'exchangAPI' 'Running' 'Running'),
                    (& $c 'BravoWeb' 'Apache2.4' 'Failed' 'Stopped')))
            # Порядок входу не канонічний — план однаково канонічний.
            $result.Union = & $describe (Get-BRAVOServiceRecoveryChainPlan -Conditions @(
                    (& $c 'BravoWeb' 'Apache2.4' 'Failed' 'Stopped'),
                    (& $c 'ExchangeApi' 'exchangAPI' 'Failed' 'Stopped'),
                    (& $c 'Bravo' 'BRAVO' 'Running' 'Running')))
            # Hashtable-входи теж приймаються.
            $result.UnionBravo = & $describe (Get-BRAVOServiceRecoveryChainPlan -Conditions @(
                    @{ Key = 'ExchangeApi'; Name = 'exchangAPI'; Condition = 'Failed'; Status = 'Stopped' },
                    @{ Key = 'BravoWeb'; Name = 'Apache2.4'; Condition = 'Running'; Status = 'Running' },
                    @{ Key = 'Bravo'; Name = 'BRAVO'; Condition = 'Failed'; Status = 'Stopped' }))
            $result.SkipDisabled = & $describe (Get-BRAVOServiceRecoveryChainPlan -Conditions @(
                    (& $c 'Bravo' 'BRAVO' 'Failed' 'Stopped'),
                    (& $c 'ExchangeApi' 'exchangAPI' 'Disabled' 'Stopped'),
                    (& $c 'BravoWeb' 'Apache2.4' 'NotInstalled' '')))
            $result.DeferPending = & $describe (Get-BRAVOServiceRecoveryChainPlan -Conditions @(
                    (& $c 'Bravo' 'BRAVO' 'Failed' 'Stopped'),
                    (& $c 'ExchangeApi' 'exchangAPI' 'Running' 'Running'),
                    (& $c 'BravoWeb' 'Apache2.4' 'Pending' 'StartPending')))
            $result.DeferBravoPending = & $describe (Get-BRAVOServiceRecoveryChainPlan -Conditions @(
                    (& $c 'Bravo' 'BRAVO' 'Pending' 'StartPending'),
                    (& $c 'ExchangeApi' 'exchangAPI' 'Failed' 'Stopped')))
            $result.PausedNotFailed = & $describe (Get-BRAVOServiceRecoveryChainPlan -Conditions @(
                    (& $c 'Bravo' 'BRAVO' 'Running' 'Running'),
                    (& $c 'ExchangeApi' 'exchangAPI' 'Failed' 'Paused'),
                    (& $c 'BravoWeb' 'Apache2.4' 'OwnedByBravo' 'Stopped')))
            $result.Eligible = & $describe (Get-BRAVOServiceRecoveryChainPlan -EligibleNames @('Apache2.4') -Conditions @(
                    (& $c 'Bravo' 'BRAVO' 'Running' 'Running'),
                    (& $c 'ExchangeApi' 'exchangAPI' 'Failed' 'Stopped'),
                    (& $c 'BravoWeb' 'Apache2.4' 'Failed' 'Stopped')))
            $result.BravoInPause = & $describe (Get-BRAVOServiceRecoveryChainPlan -EligibleNames @('exchangAPI') -Conditions @(
                    (& $c 'Bravo' 'BRAVO' 'Failed' 'Stopped'),
                    (& $c 'ExchangeApi' 'exchangAPI' 'Failed' 'Stopped'),
                    (& $c 'BravoWeb' 'Apache2.4' 'Running' 'Running')))
            $result.BravoInPauseRunning = & $describe (Get-BRAVOServiceRecoveryChainPlan -EligibleNames @() -Conditions @(
                    (& $c 'Bravo' 'BRAVO' 'Failed' 'Stopped'),
                    (& $c 'ExchangeApi' 'exchangAPI' 'Running' 'Running'),
                    (& $c 'BravoWeb' 'Apache2.4' 'Running' 'Running')))
            # Залежні, утримані паузою BRAVO (не запускаються й не
            # обліковуються в цьому тику).
            $heldPlan = Get-BRAVOServiceRecoveryChainPlan -EligibleNames @('exchangAPI', 'Apache2.4') -Conditions @(
                (& $c 'Bravo' 'BRAVO' 'Failed' 'Stopped'),
                (& $c 'ExchangeApi' 'exchangAPI' 'Failed' 'Stopped'),
                (& $c 'BravoWeb' 'Apache2.4' 'Failed' 'Stopped'))
            $result.BravoInPauseAllDependents = & $describe $heldPlan
            $heldNames = {
                param($Plan)
                if ($null -eq $Plan.PSObject.Properties['HeldByBravoNames']) { return '<немає HeldByBravoNames>' }
                return (@($Plan.HeldByBravoNames) -join ' ')
            }
            $result.BravoInPauseHeld = & $heldNames $heldPlan
            $result.BravoRunningHeld = & $heldNames (Get-BRAVOServiceRecoveryChainPlan -EligibleNames @('exchangAPI') -Conditions @(
                    (& $c 'Bravo' 'BRAVO' 'Running' 'Running'),
                    (& $c 'ExchangeApi' 'exchangAPI' 'Failed' 'Stopped')))
            $result.Empty = & $describe (Get-BRAVOServiceRecoveryChainPlan -Conditions @())
            return [pscustomobject]$result
        }
    } catch {
        $w4ChainError = $_.Exception.Message
    }
    $w4ChainCheck = {
        param([hashtable]$Expected)
        if ($null -ne $w4ChainError) { return @("помилка: $w4ChainError") }
        return @($Expected.Keys | Sort-Object | Where-Object { [string]$w4Chain.$_ -cne [string]$Expected[$_] } |
                ForEach-Object { "${_}: '$($w4Chain.$_)' (очікувалось '$($Expected[$_])')" })
    }
    $w4ChainDiffs = @(& $w4ChainCheck @{
            BravoFailed = 'failed: BRAVO | stop: Apache2.4 exchangAPI | start: BRAVO exchangAPI Apache2.4 | deferred:  | accounted: BRAVO'
        })
    Test-BRAVOCondition -Condition ($w4ChainDiffs.Count -eq 0) `
        -Name 'ServiceRecovery/ChainPlanBravoFailedStopsDependentsAndStartsAll' `
        -Failure "впала BRAVO: зупинити працюючі залежні (BRAVO Web, exchangAPI) і запустити всі в порядку BRAVO -> exchangAPI -> BRAVO Web: $($w4ChainDiffs -join ' || ')"
    $w4ChainDiffs = @(& $w4ChainCheck @{
            ExchangeOnly = 'failed: exchangAPI | stop:  | start: exchangAPI | deferred:  | accounted: exchangAPI'
        })
    Test-BRAVOCondition -Condition ($w4ChainDiffs.Count -eq 0) `
        -Name 'ServiceRecovery/ChainPlanExchangeApiOnly' `
        -Failure "впала лише exchangAPI: запуск лише exchangAPI, без зупинок: $($w4ChainDiffs -join ' || ')"
    $w4ChainDiffs = @(& $w4ChainCheck @{
            WebOnly = 'failed: Apache2.4 | stop:  | start: Apache2.4 | deferred:  | accounted: Apache2.4'
        })
    Test-BRAVOCondition -Condition ($w4ChainDiffs.Count -eq 0) `
        -Name 'ServiceRecovery/ChainPlanWebOnly' `
        -Failure "впала лише BRAVO Web: запуск лише BRAVO Web, без зупинок: $($w4ChainDiffs -join ' || ')"
    $w4ChainDiffs = @(& $w4ChainCheck @{
            Union = 'failed: exchangAPI Apache2.4 | stop:  | start: exchangAPI Apache2.4 | deferred:  | accounted: exchangAPI Apache2.4'
            UnionBravo = 'failed: BRAVO exchangAPI | stop: Apache2.4 | start: BRAVO exchangAPI Apache2.4 | deferred:  | accounted: BRAVO exchangAPI'
            Empty = 'failed:  | stop:  | start:  | deferred:  | accounted: '
        })
    Test-BRAVOCondition -Condition ($w4ChainDiffs.Count -eq 0) `
        -Name 'ServiceRecovery/ChainPlanUnionKeepsCanonicalOrder' `
        -Failure "кілька впалих: об'єднання планів у канонічному порядку незалежно від порядку входу (pscustomobject і hashtable): $($w4ChainDiffs -join ' || ')"
    $w4ChainDiffs = @(& $w4ChainCheck @{
            SkipDisabled = 'failed: BRAVO | stop:  | start: BRAVO | deferred:  | accounted: BRAVO'
            DeferPending = 'failed: BRAVO | stop: exchangAPI | start: BRAVO exchangAPI | deferred: Apache2.4 | accounted: BRAVO'
            DeferBravoPending = 'failed: exchangAPI | stop:  | start: exchangAPI | deferred: BRAVO | accounted: exchangAPI'
            PausedNotFailed = 'failed:  | stop:  | start:  | deferred:  | accounted: '
        })
    Test-BRAVOCondition -Condition ($w4ChainDiffs.Count -eq 0) `
        -Name 'ServiceRecovery/ChainPlanSkipsDisabledAndDefersPending' `
        -Failure "Disabled/NotInstalled/OwnedByBravo/призупинена служба не зупиняється й не запускається; служба в Pending, від якої залежить план, — Deferred (цього тику план не виконується): $($w4ChainDiffs -join ' || ')"
    $w4ChainDiffs = @(& $w4ChainCheck @{
            Eligible = 'failed: Apache2.4 | stop:  | start: Apache2.4 | deferred:  | accounted: Apache2.4'
        })
    Test-BRAVOCondition -Condition ($w4ChainDiffs.Count -eq 0) `
        -Name 'ServiceRecovery/ChainPlanHonorsPauseEligibility' `
        -Failure "-EligibleNames (служби, чия пауза минула): впала служба в паузі цього тику не запускається і не тягне ланцюжок: $($w4ChainDiffs -join ' || ')"
    # Впала BRAVO у паузі: залежні (exchangAPI, BRAVO Web) від неї залежать —
    # у цьому тику їх не запускають і не обліковують, навіть якщо їхня власна
    # пауза минула (HeldByBravoNames — для рядка зведення); працюючі залежні
    # не зупиняються. Самостійно впала залежна при працюючій BRAVO — як і
    # раніше за власною паузою.
    $w4ChainDiffs = @(& $w4ChainCheck @{
            BravoInPause = 'failed:  | stop:  | start:  | deferred:  | accounted: '
            BravoInPauseRunning = 'failed:  | stop:  | start:  | deferred:  | accounted: '
            BravoInPauseAllDependents = 'failed:  | stop:  | start:  | deferred:  | accounted: '
            BravoInPauseHeld = 'exchangAPI Apache2.4'
            BravoRunningHeld = ''
            ExchangeOnly = 'failed: exchangAPI | stop:  | start: exchangAPI | deferred:  | accounted: exchangAPI'
        })
    Test-BRAVOCondition -Condition ($w4ChainDiffs.Count -eq 0) `
        -Name 'ServiceRecovery/ChainPlanBravoInPauseHoldsDependents' `
        -Failure "впала BRAVO у паузі: впалі залежні не запускаються і не обліковуються (HeldByBravoNames), працюючі не зупиняються; при працюючій BRAVO залежна — за своєю паузою: $($w4ChainDiffs -join ' || ')"

    $w4ModuleAst = [Management.Automation.Language.Parser]::ParseInput($w4ModuleText, [ref]$null, [ref]$null)
    $w4ChainFunction = @($w4ModuleAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-BRAVOServiceRecoveryChainPlan'
            }, $true)) | Select-Object -First 1
    $w4ChainSideEffects = @()
    if ($null -ne $w4ChainFunction) {
        $w4ChainSideEffects = @($w4ChainFunction.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -in @('Get-Service', 'Start-Service', 'Stop-Service', 'Get-BRAVOWmiInstance',
                        'Read-BRAVOServiceQuiescenceState', 'Get-BRAVOManagedServiceCondition', 'Write-BRAVOStateFileAtomic')
                }, $true) | ForEach-Object { $_.GetCommandName() })
    }
    Test-BRAVOCondition -Condition ($null -ne $w4ChainFunction -and $w4ChainSideEffects.Count -eq 0) `
        -Name 'ServiceRecovery/ChainPlanIsPure' `
        -Failure "Get-BRAVOServiceRecoveryChainPlan має бути чистою функцією модуля BRAVO.ServiceRecovery (без SCM/WMI/маркера/диска): визначено=$($null -ne $w4ChainFunction) виклики=[$($w4ChainSideEffects -join ', ')]"

    # ============================================================
    # Події SCM: чистий селектор (Get-WinEvent — лише Windows CI).
    # ============================================================
    $w4ScmError = $null
    $w4Scm = $null
    try {
        $w4Scm = & $w4ChainModule {
            Set-StrictMode -Version 2.0
            $base = New-Object DateTime(2026, 10, 7, 10, 0, 0, [DateTimeKind]::Local)
            $newScmEvent = {
                param([int]$Id, [int]$MinutesAgo, [string]$Message, [object[]]$Values)
                [pscustomobject]@{
                    Id = $Id; TimeCreated = $base.AddMinutes(-$MinutesAgo); Message = $Message
                    Properties = @($Values | ForEach-Object { [pscustomobject]@{ Value = $_ } })
                }
            }
            $events = @(
                (& $newScmEvent 7034 5 'other text' @('Apache2.4')),
                (& $newScmEvent 7034 30 'Служба "exchangAPI" неочікувано завершила роботу.' @('exchangAPI', 1)),
                (& $newScmEvent 7031 20 'The BRAVO Web service terminated unexpectedly.' @('BRAVO Web', 2)),
                (& $newScmEvent 7034 10 'Служба "Spooler" неочікувано завершила роботу.' @('Spooler', 1)),
                (& $newScmEvent 7000 15 'Служба BRAVO не запустилася.' @())
            )
            $all = @(Select-BRAVOServiceRecoveryScmEvents -Events $events -ServiceNames @('exchangAPI', 'Apache2.4', 'BRAVO') -MaxEvents 50)
            $limited = @(Select-BRAVOServiceRecoveryScmEvents -Events $events -ServiceNames @('exchangAPI', 'Apache2.4', 'BRAVO') -MaxEvents 1)
            $none = @(Select-BRAVOServiceRecoveryScmEvents -Events @() -ServiceNames @('exchangAPI') -MaxEvents 50)
            return [pscustomobject]@{
                All = (@($all | ForEach-Object { '{0}:{1}:{2:HH:mm}' -f $_.ServiceName, $_.Id, $_.TimeCreated }) -join ' ')
                Limited = (@($limited | ForEach-Object { '{0}:{1}' -f $_.ServiceName, $_.Id }) -join ' ')
                None = $none.Count
            }
        }
    } catch {
        $w4ScmError = $_.Exception.Message
    }
    if ($null -eq $w4Scm) { $w4Scm = [pscustomobject]@{ All = $null; Limited = $null; None = -1 } }
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w4ScmError -and
            [string]$w4Scm.All -ceq 'exchangAPI:7034:09:30 BRAVO:7000:09:45 Apache2.4:7034:09:55' -and
            [string]$w4Scm.Limited -ceq 'Apache2.4:7034' -and
            [int]$w4Scm.None -eq 0
        ) `
        -Name 'ServiceRecovery/ScmEventSelectorFiltersByServiceAndLimits' `
        -Failure ("Select-BRAVOServiceRecoveryScmEvents: подія належить службі за першим параметром події (ім'я служби), без параметрів — за словом у тексті; чужі служби (Spooler, 'BRAVO Web' для BRAVO) відкинуто; " +
            "хронологічно, лише MaxEvents найновіших, ServiceName у результаті. помилка='$w4ScmError' all='$($w4Scm.All)' limited='$($w4Scm.Limited)'")

    $w4ScmUnavailable = $null
    try {
        $w4ScmUnavailable = & $w4ChainModule {
            Get-BRAVOServiceRecoveryScmEvents -ServiceNames @('exchangAPI') -MaxEvents 50
        }
    } catch {
        $w4ScmUnavailable = $null
    }
    $w4IsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    Test-BRAVOCondition `
        -Condition (
            $null -ne $w4ScmUnavailable -and
            $null -ne $w4ScmUnavailable.PSObject.Properties['Available'] -and
            $null -ne $w4ScmUnavailable.PSObject.Properties['Events'] -and
            ($w4IsWindows -or (-not [bool]$w4ScmUnavailable.Available -and [string]$w4ScmUnavailable.Reason -match 'недоступн'))
        ) `
        -Name 'ServiceRecovery/ScmEventsUnavailableOffWindows' `
        -Failure "Get-BRAVOServiceRecoveryScmEvents не кидає винятку і повертає Available/Events/Reason; поза Windows — Available=`$false і причина «події SCM недоступні»"

    # ============================================================
    # Класифікація керованих служб: одне читання маркера на виклик; маркер
    # із restartSuppressed робить зупинену службу OwnedByBravo (тест 6а).
    # ============================================================
    $w4ClassifyStubs = @'
function Read-BRAVOServiceQuiescenceState {
    $script:W4MarkerReads++
    return $script:W4Marker
}
function Get-Service {
    param([string]$Name, $ErrorAction)
    $status = $script:W4ServiceStatus[$Name]
    if ($null -eq $status) { return $null }
    return [pscustomobject]@{ Name = $Name; Status = $status; StartType = 'Automatic' }
}
function Get-BRAVOWin32ServiceInfo { param([string]$Name) return $null }
function Invoke-W4Classify {
    param($Marker, [hashtable]$Statuses, [object[]]$Services)
    $script:W4Marker = $Marker
    $script:W4MarkerReads = 0
    $script:W4ServiceStatus = $Statuses
    $conditions = @(Get-BRAVOServiceRecoveryConditions -Services $Services)
    return [pscustomobject]@{
        Text = (@($conditions | ForEach-Object { '{0}/{1}={2}' -f $_.Key, $_.Name, $_.Condition }) -join ' ')
        Reads = $script:W4MarkerReads
    }
}
'@
    $w4ClassifyModule = & $w4NewModule ($w4ClassifyStubs + "`n" + $w4ModuleText + "`n" + $w4SystemText) (
        @('Read-BRAVOServiceQuiescenceState', 'Get-Service', 'Get-BRAVOWin32ServiceInfo', 'Invoke-W4Classify') + @($w4ModuleFunctions) +
        @('Get-BRAVOManagedServiceCondition', 'Get-BRAVOServiceStartMode', 'Test-BRAVOServiceDisabledByOperator', 'Get-BRAVOManagedServiceOrder'))
    $w4SuppressedMarker = [pscustomobject]@{
        schemaVersion = 1; owner = 'BRAVO_DATA_RESTORE'; hostname = [Environment]::MachineName; pid = 4242
        processStartTime = '2026-10-07T09:00:00.0000000+03:00'; createdAt = '2026-10-07T09:00:01.0000000+03:00'
        logFile = 'C:\LOGS\restore.log'; restartSuppressed = $true
        services = @([pscustomobject]@{ Name = 'exchangAPI'; RestartIntent = $true }); startTypeSnapshot = @()
    }
    $w4ClassifyServices = @(
        @{ Key = 'Bravo'; Name = 'BRAVO'; Enabled = $true },
        @{ Key = 'ExchangeApi'; Name = 'exchangAPI'; Enabled = $true },
        @{ Key = 'BravoWeb'; Name = 'Apache2.4'; Enabled = $true },
        @{ Key = 'BravoWeb'; Name = ''; Enabled = $false }
    )
    $w4ClassifyStatuses = @{ BRAVO = 'Running'; exchangAPI = 'Stopped'; 'Apache2.4' = 'Running' }
    $w4ClassifyError = $null
    $w4ClassifyMarked = $null
    $w4ClassifyPlain = $null
    try {
        $w4ClassifyMarked = & $w4ClassifyModule {
            param($Marker, $Statuses, $Services)
            Set-StrictMode -Version 2.0
            Invoke-W4Classify -Marker $Marker -Statuses $Statuses -Services $Services
        } $w4SuppressedMarker $w4ClassifyStatuses $w4ClassifyServices
        $w4ClassifyPlain = & $w4ClassifyModule {
            param($Statuses, $Services)
            Set-StrictMode -Version 2.0
            Invoke-W4Classify -Marker $null -Statuses $Statuses -Services @($Services | Select-Object -First 3)
        } $w4ClassifyStatuses $w4ClassifyServices
    } catch {
        $w4ClassifyError = $_.Exception.Message
    }
    if ($null -eq $w4ClassifyMarked) { $w4ClassifyMarked = [pscustomobject]@{ Text = $null; Reads = -1 } }
    if ($null -eq $w4ClassifyPlain) { $w4ClassifyPlain = [pscustomobject]@{ Text = $null; Reads = -1 } }
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w4ClassifyError -and
            [string]$w4ClassifyMarked.Text -ceq 'Bravo/BRAVO=Running ExchangeApi/exchangAPI=OwnedByBravo BravoWeb/Apache2.4=Running' -and
            [int]$w4ClassifyMarked.Reads -eq 1 -and
            [string]$w4ClassifyPlain.Text -ceq 'Bravo/BRAVO=Running ExchangeApi/exchangAPI=Failed BravoWeb/Apache2.4=Running'
        ) `
        -Name 'ServiceRecovery/ConditionsClassifyManagedServicesWithOneMarkerRead' `
        -Failure ("Get-BRAVOServiceRecoveryConditions: лише керовані служби в канонічному порядку (Key додано), маркер читається один раз; служба з маркера restartSuppressed — OwnedByBravo, без маркера зупинена — Failed. " +
            "помилка='$w4ClassifyError' з маркером='$($w4ClassifyMarked.Text)' читань=$($w4ClassifyMarked.Reads) без маркера='$($w4ClassifyPlain.Text)'")

    # ============================================================
    # Оркестратор профілю: справжня Invoke-BRAVOMaintenanceServiceRecoveryProfile
    # (runtime) + справжні чисті функції модуля; побічні дії — стаби з
    # журналом подій. Перший Write-Log створив би RECOVER-журнал, тож
    # «журнал не створено» = жодного виклику Write-Log.
    # ============================================================
    $w4ProfileStubs = @'
function Write-Host {
    param([Parameter(Position = 0)]$Object, $ForegroundColor, [switch]$NoNewline)
    $script:W4HostLines += @([string]$Object)
}
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO', [switch]$NoConsole)
    $script:W4LogCalls += @("$Level|$Message")
}
function Get-BRAVOMaintenanceServiceRecoveryServices { return @($script:W4Services) }
function Read-BRAVOServiceRecoveryState {
    return [pscustomobject]@{ State = $script:W4RecoveryState; Status = 'Ok'; Warning = $null; QuarantinedPath = $null }
}
function Write-BRAVOServiceRecoveryState {
    param($State, $Now)
    $script:W4StateWrites++
    $script:W4WrittenState = $State
}
function Add-BRAVOServiceRecoverySummaryLine {
    param([string]$Path, [string]$Text)
    $script:W4Events += @("SUMMARY $Text")
}
function Enter-BRAVOMaintenanceOperationLock {
    param([string]$TaskType, [switch]$NoWait, [string]$OperationName)
    $script:W4LockArgs = '{0}|{1}|{2}' -f $TaskType, [bool]$NoWait, $OperationName
    if ($script:W4LockBusy) {
        return [pscustomobject]@{ Success = $false; Stream = $null; Path = 'C:\BRAVO\BRAVO_OPERATION.lock'; Error = 'self-test: lock зайнятий' }
    }
    return [pscustomobject]@{ Success = $true; Stream = $null; Path = 'C:\BRAVO\BRAVO_OPERATION.lock'; Error = $null }
}
function Exit-BRAVOMaintenanceOperationLock { $script:W4LockExits++ }
function Resolve-BRAVOExitCode {
    param([switch]$LockBusy, [switch]$InvalidConfiguration, [switch]$HasWarnings, [switch]$MaintenanceFailed)
    if ($LockBusy) { return 20 }
    if ($InvalidConfiguration) { return 30 }
    if ($MaintenanceFailed) { return 60 }
    if ($HasWarnings) { return 10 }
    return 0
}
function Get-BRAVOForeignServiceQuiescenceContext { return $script:W4Foreign }
function Write-BRAVOServiceQuiescenceState {
    param([string]$Owner, [object[]]$Services, [string]$LogFile, [switch]$RestartSuppressed, [object[]]$StartTypeSnapshot)
    if ($script:W4MarkerWriteFails) { throw 'self-test: маркер не записано' }
    $script:W4Events += @("MARKER $Owner " + (@($Services | ForEach-Object { '{0}={1}' -f $_.Name, [bool]$_.RestartIntent }) -join ','))
    $script:W4MarkerLogFile = $LogFile
}
function Clear-BRAVOServiceQuiescenceState {
    param($ExpectedState)
    $script:W4Events += @('CLEAR')
    return $true
}
function Invoke-ServiceStateChange {
    param([string]$Name, [string]$DesiredStatus, [int]$TimeoutSeconds, [int]$PollIntervalSeconds, [switch]$Force)
    $script:W4Events += @("STATE $Name $DesiredStatus")
    return [pscustomobject]@{ Success = $true; AlreadyInState = $false; StateChangeIssued = $true; FinalStatus = $DesiredStatus; Error = $null }
}
function Start-BRAVOMaintenanceManagedService {
    param([string]$Key, [string]$Name, [hashtable]$Outcome, $RecoveryCondition, $LastScmEvent)
    $script:W4Events += @("START $Name recovery=$($null -ne $RecoveryCondition)")
    if (@($script:W4StartFailures) -contains $Name) {
        $Outcome.RestartFailed = $true
        $script:criticalErrorOccurred = $true
    }
}
function Start-Service { param($Name) $script:W4Events += @("START-SERVICE $Name") }
function Stop-Service { param($Name) $script:W4Events += @("STOP-SERVICE $Name") }
function Stop-BRAVOMaintenanceStrayProcess { $script:W4Events += @('STRAY') }
function Invoke-BRAVOMaintenanceBeforeServiceStopHook { param($Key) $script:W4Events += @('HOOK') }
function Write-BRAVOTaskExecutionState { param($TaskName) $script:W4Events += @('TASKSTATE') }
function Write-BRAVOOperationStatus { $script:W4Events += @('OPSTATUS') }
function Send-SlackAlert {
    param([string]$Message, [switch]$IsCritical, [string]$Severity)
    $script:W4Events += @("SLACK $Severity $([bool]$IsCritical)")
    if ($IsCritical) { $script:criticalErrorOccurred = $true }
}
function Send-BRAVOMaintenanceEarlyExitAlerts {
    param([string]$Reason, [string]$Title, [string]$Summary)
    $script:W4Events += @('REPORT')
}
function Get-BRAVOServiceRecoveryScmEvents {
    param([string[]]$ServiceNames, [int]$MaxEvents)
    return [pscustomobject]@{ Available = $false; Events = @(); Reason = 'події SCM недоступні (self-test)' }
}
function Initialize-BRAVOMaintenanceServiceRecoveryLogSources {
    param([string[]]$Keys)
    return @{ TraceConfiguration = $null; TraceOutSources = @(); BravoFilePhaseAllowed = $false; ExchangeApiRuntime = $null }
}
function Invoke-BRAVOMaintenanceServiceLogProcessing {
    param([string]$Key, [hashtable]$Outcome)
    $script:W4Events += @("LOGS $Key")
}
function Get-BRAVOMaintenanceResolvedExitCode {
    if ($script:criticalErrorOccurred) { return 60 }
    return 0
}
function Invoke-W4Profile {
    param(
        [object[]]$Conditions,
        $RecoveryState = $null,
        [bool]$LockBusy = $false,
        $Foreign = $null,
        [bool]$MarkerWriteFails = $false,
        [string[]]$StartFailures = @()
    )
    $script:W4Services = @(
        @{ Key = 'Bravo'; Name = 'BRAVO'; Enabled = $true },
        @{ Key = 'ExchangeApi'; Name = 'exchangAPI'; Enabled = $true },
        @{ Key = 'BravoWeb'; Name = 'Apache2.4'; Enabled = $true }
    )
    $script:W4Conditions = @($Conditions)
    $script:W4RecoveryState = $RecoveryState
    $script:W4LockBusy = $LockBusy
    $script:W4Foreign = if ($null -ne $Foreign) { $Foreign } else {
        [pscustomobject]@{ Present = $false; OwnerAlive = $false; Owner = $null; RestartSuppressed = $false; RestartIntentNames = @(); HeldSnapshot = @() }
    }
    $script:W4MarkerWriteFails = $MarkerWriteFails
    $script:W4StartFailures = @($StartFailures)
    $script:W4Events = @()
    $script:W4LogCalls = @()
    $script:W4HostLines = @()
    $script:W4LockArgs = $null
    $script:W4LockExits = 0
    $script:W4StateWrites = 0
    $script:W4WrittenState = $null
    $script:W4ClassifyCount = 0
    $script:W4MarkerLogFile = $null
    $script:criticalErrorOccurred = $false
    $script:LOG_FILE = 'C:\BRAVO\LOGS\BRAVO_MAINTENANCE_20261007_101500_RECOVER_PID1234.log'
    $script:LOG_DIR = 'C:\BRAVO\LOGS'
    $script:ServiceStopTimeoutSeconds = 60
    $script:ServiceStartTimeoutSeconds = 60
    $script:ServicePollIntervalSeconds = 1
    $exitCode = $null
    $profileError = $null
    try {
        $exitCode = Invoke-BRAVOMaintenanceServiceRecoveryProfile
    } catch {
        $profileError = $_.Exception.Message
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Error = $profileError
        Events = @($script:W4Events)
        LogCalls = @($script:W4LogCalls)
        HostLines = @($script:W4HostLines)
        LockArgs = $script:W4LockArgs
        LockExits = $script:W4LockExits
        StateWrites = $script:W4StateWrites
        WrittenState = $script:W4WrittenState
        ClassifyCount = $script:W4ClassifyCount
        MarkerLogFile = $script:W4MarkerLogFile
    }
}
'@
    $w4ConditionsStub = @'
function Get-BRAVOServiceRecoveryConditions {
    param($Services)
    $script:W4ClassifyCount++
    return @($script:W4Conditions)
}
'@
    $w4ProfileStubNames = @(& $w4FunctionNamesIn $w4ProfileStubs)
    $w4ProfileModule = & $w4NewModule ($w4ConditionsStub + "`n" + $w4ProfileStubs + "`n" + $w4RuntimeText + "`n" + $w4ModuleText + "`n" + $w4SystemText) (
        @('Get-BRAVOServiceRecoveryConditions') + $w4ProfileStubNames + @('Invoke-BRAVOMaintenanceServiceRecoveryProfile') + @($w4ModuleFunctions) + @('Get-BRAVOManagedServiceOrder'))
    $w4Cond = {
        param([string]$Key, [string]$Name, [string]$Condition, [string]$Status)
        [pscustomobject]@{
            Key = $Key; Name = $Name; Exists = $true; StartMode = 'Automatic'; StartModeSource = 'StartType'; Status = $Status
            ExitCode = $(if ($Condition -eq 'Failed') { 1067 } else { 0 }); ServiceSpecificExitCode = 0
            Condition = $Condition; HeldByBravo = $false; OriginalStartMode = $null; MarkerOwner = $null
        }
    }
    $w4AllRunning = @(
        (& $w4Cond 'Bravo' 'BRAVO' 'Running' 'Running'),
        (& $w4Cond 'ExchangeApi' 'exchangAPI' 'Running' 'Running'),
        (& $w4Cond 'BravoWeb' 'Apache2.4' 'Running' 'Running'))
    $w4ExchangeFailed = @(
        (& $w4Cond 'Bravo' 'BRAVO' 'Running' 'Running'),
        (& $w4Cond 'ExchangeApi' 'exchangAPI' 'Failed' 'Stopped'),
        (& $w4Cond 'BravoWeb' 'Apache2.4' 'Running' 'Running'))
    $w4BravoFailed = @(
        (& $w4Cond 'Bravo' 'BRAVO' 'Failed' 'Stopped'),
        (& $w4Cond 'ExchangeApi' 'exchangAPI' 'Running' 'Running'),
        (& $w4Cond 'BravoWeb' 'Apache2.4' 'Running' 'Running'))
    $w4RunProfile = {
        param([hashtable]$Arguments)
        & $w4ProfileModule {
            param($ProfileArguments)
            Set-StrictMode -Version 2.0
            Invoke-W4Profile @ProfileArguments
        } $Arguments
    }
    $w4Describe = {
        param($Result)
        "exit=$($Result.ExitCode) помилка='$($Result.Error)' lock='$($Result.LockArgs)' lockExits=$($Result.LockExits) stateWrites=$($Result.StateWrites) " +
            "events=[$(@($Result.Events) -join '; ')] log=$(@($Result.LogCalls).Count) перший='$(@($Result.LogCalls) | Select-Object -First 1)'"
    }
    $w4ForbiddenEvents = {
        param($Result)
        @($Result.Events | Where-Object { $_ -match '^(STRAY|HOOK|TASKSTATE|OPSTATUS|START-SERVICE|STOP-SERVICE)' })
    }

    # Немає впалих: вихід 0, lock не береться, журнал не створюється, state
    # не пишеться.
    $w4NoFailed = & $w4RunProfile @{ Conditions = $w4AllRunning }
    # ... крім скидання stableSince, коли воно змінилося (служба з обліком
    # спроб працює — перше спостереження стабільності).
    $w4StableState = [pscustomobject]@{
        schemaVersion = 1; hostname = [Environment]::MachineName; updatedAt = $null
        services = @{ exchangAPI = [pscustomobject]@{ attempts = @((Get-Date).AddMinutes(-10).ToString('o')); lastCriticalAt = $null; stableSince = $null } }
    }
    $w4StableObserved = & $w4RunProfile @{ Conditions = $w4AllRunning; RecoveryState = $w4StableState }
    $w4StableWrittenSince = $null
    if ($null -ne $w4StableObserved.WrittenState -and $null -ne $w4StableObserved.WrittenState.services -and
        $w4StableObserved.WrittenState.services.ContainsKey('exchangAPI')) {
        $w4StableWrittenSince = $w4StableObserved.WrittenState.services['exchangAPI'].stableSince
    }
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w4NoFailed.Error -and [int]$w4NoFailed.ExitCode -eq 0 -and
            $null -eq $w4NoFailed.LockArgs -and @($w4NoFailed.LogCalls).Count -eq 0 -and
            [int]$w4NoFailed.StateWrites -eq 0 -and @($w4NoFailed.Events).Count -eq 0 -and
            $null -eq $w4StableObserved.Error -and [int]$w4StableObserved.ExitCode -eq 0 -and
            [int]$w4StableObserved.StateWrites -eq 1 -and $null -ne $w4StableWrittenSince -and
            $null -eq $w4StableObserved.LockArgs -and @($w4StableObserved.LogCalls).Count -eq 0
        ) `
        -Name 'ServiceRecovery/ProfileNoFailedExitsWithoutDiskWrites' `
        -Failure ("немає впалих служб: вихід 0 без lock-а, журналу RECOVER і запису state; єдиний дозволений запис — stableSince, коли він змінився. " +
            "без обліку: $(& $w4Describe $w4NoFailed) || з обліком: $(& $w4Describe $w4StableObserved) stableSince='$w4StableWrittenSince'")

    # Пауза ще не минула (друга спроба через 2 хв після першої, пауза 5 хв):
    # lock не береться, журнал не створюється, рядок у зведенні.
    $w4PauseState = [pscustomobject]@{
        schemaVersion = 1; hostname = [Environment]::MachineName; updatedAt = $null
        services = @{ exchangAPI = [pscustomobject]@{ attempts = @((Get-Date).AddMinutes(-2).ToString('o')); lastCriticalAt = $null; stableSince = $null } }
    }
    $w4Paused = & $w4RunProfile @{ Conditions = $w4ExchangeFailed; RecoveryState = $w4PauseState }
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w4Paused.Error -and [int]$w4Paused.ExitCode -eq 0 -and
            $null -eq $w4Paused.LockArgs -and @($w4Paused.LogCalls).Count -eq 0 -and
            @($w4Paused.Events | Where-Object { $_ -match '^(START|STATE|MARKER|SLACK|REPORT|LOGS)' }).Count -eq 0 -and
            @($w4Paused.Events | Where-Object { $_ -match '^SUMMARY .*exchangAPI.*пауза до \d\d:\d\d \(спроба 2\)' }).Count -eq 1
        ) `
        -Name 'ServiceRecovery/ProfilePauseSkipsWithoutLock' `
        -Failure "впала служба в паузі (0/5/15/60): вихід 0 без lock-а, журналу і запуску; рядок «exchangAPI впала, пауза до HH:mm (спроба 2)» у зведенні: $(& $w4Describe $w4Paused)"

    # Впала BRAVO у паузі, впала exchangAPI без обліку (її пауза минула):
    # exchangAPI залежить від BRAVO — lock не береться, журнал не
    # створюється, запуску й обліку немає; у зведенні — рядок паузи BRAVO і
    # рядок «exchangAPI чекає на BRAVO».
    $w4BravoPauseState = [pscustomobject]@{
        schemaVersion = 1; hostname = [Environment]::MachineName; updatedAt = $null
        services = @{ BRAVO = [pscustomobject]@{ attempts = @((Get-Date).AddMinutes(-2).ToString('o')); lastCriticalAt = $null; stableSince = $null } }
    }
    $w4BravoPausedHeld = & $w4RunProfile @{
        Conditions = @(
            (& $w4Cond 'Bravo' 'BRAVO' 'Failed' 'Stopped'),
            (& $w4Cond 'ExchangeApi' 'exchangAPI' 'Failed' 'Stopped'),
            (& $w4Cond 'BravoWeb' 'Apache2.4' 'Running' 'Running'))
        RecoveryState = $w4BravoPauseState
    }
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w4BravoPausedHeld.Error -and [int]$w4BravoPausedHeld.ExitCode -eq 0 -and
            $null -eq $w4BravoPausedHeld.LockArgs -and @($w4BravoPausedHeld.LogCalls).Count -eq 0 -and
            [int]$w4BravoPausedHeld.StateWrites -eq 0 -and
            @($w4BravoPausedHeld.Events | Where-Object { $_ -match '^(START|STATE|MARKER|SLACK|REPORT|LOGS)' }).Count -eq 0 -and
            @($w4BravoPausedHeld.Events | Where-Object { $_ -match '^SUMMARY .*BRAVO впала, пауза до \d\d:\d\d \(спроба 2\)' }).Count -eq 1 -and
            @($w4BravoPausedHeld.Events | Where-Object { $_ -match '^SUMMARY .*exchangAPI.*чекає на BRAVO' }).Count -eq 1
        ) `
        -Name 'ServiceRecovery/ProfileBravoInPauseHoldsDependentsWithoutLock' `
        -Failure "впала BRAVO у паузі і впала exchangAPI: exchangAPI залежить від BRAVO — вихід 0 без lock-а, журналу RECOVER, запуску й обліку; у зведенні пауза BRAVO і «exchangAPI ... чекає на BRAVO»: $(& $w4Describe $w4BravoPausedHeld)"

    # Тест 5: lock зайнятий -> 20, без змін, сповіщень і журналу.
    $w4LockBusy = & $w4RunProfile @{ Conditions = $w4ExchangeFailed; LockBusy = $true }
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w4LockBusy.Error -and [int]$w4LockBusy.ExitCode -eq 20 -and
            [string]$w4LockBusy.LockArgs -ceq 'Maintenance|True|ServiceRecovery' -and
            @($w4LockBusy.Events).Count -eq 0 -and @($w4LockBusy.LogCalls).Count -eq 0 -and
            [int]$w4LockBusy.StateWrites -eq 0 -and [int]$w4LockBusy.LockExits -eq 0
        ) `
        -Name 'ServiceRecovery/ProfileLockBusyExits20WithoutChanges' `
        -Failure "lock зайнятий: Enter-BRAVOMaintenanceOperationLock -TaskType Maintenance -NoWait -OperationName ServiceRecovery, вихід 20 без маркера, запусків, сповіщень, журналу RECOVER і запису state: $(& $w4Describe $w4LockBusy)"

    # Тест 6б: гонка — класифікація без маркера, під lock-ом маркер
    # мертвого власника з restartSuppressed -> нічого не запускати, INFO.
    $w4Race = & $w4RunProfile @{
        Conditions = $w4ExchangeFailed
        Foreign = [pscustomobject]@{ Present = $true; OwnerAlive = $false; Owner = 'BRAVO_DATA_RESTORE'; RestartSuppressed = $true; RestartIntentNames = @(); HeldSnapshot = @() }
    }
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w4Race.Error -and [int]$w4Race.ExitCode -eq 0 -and
            @($w4Race.Events | Where-Object { $_ -match '^(START|STATE|MARKER|LOGS)' }).Count -eq 0 -and
            @($w4Race.LogCalls | Where-Object { $_ -match '^INFO\|' -and $_ -match 'restartSuppressed' -and $_ -match '43' }).Count -eq 1 -and
            [int]$w4Race.LockExits -eq 1
        ) `
        -Name 'ServiceRecovery/ProfileRaceSuppressedMarkerUnderLockStartsNothing' `
        -Failure "під lock-ом виявлено маркер із restartSuppressed: жодного запуску/зупинки/маркера, INFO з кодом 43, вихід 0, lock звільнено: $(& $w4Describe $w4Race)"

    # Чужий живий власник маркера під lock-ом -> 20 без дій.
    $w4LiveOwner = & $w4RunProfile @{
        Conditions = $w4ExchangeFailed
        Foreign = [pscustomobject]@{ Present = $true; OwnerAlive = $true; Owner = 'BRAVO_DATA_RESTORE'; RestartSuppressed = $false; RestartIntentNames = @(); HeldSnapshot = @() }
    }
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w4LiveOwner.Error -and [int]$w4LiveOwner.ExitCode -eq 20 -and
            @($w4LiveOwner.Events | Where-Object { $_ -match '^(START|STATE|MARKER|LOGS|SLACK)' }).Count -eq 0 -and
            [int]$w4LiveOwner.LockExits -eq 1
        ) `
        -Name 'ServiceRecovery/ProfileForeignLiveOwnerUnderLockExits20' `
        -Failure "чужий живий власник ownership-маркера: вихід 20 без дій: $(& $w4Describe $w4LiveOwner)"

    # Тест 6а: справжня класифікація з маркером restartSuppressed -> служба
    # OwnedByBravo -> профіль не бачить впалих і нічого не запускає.
    $w4RealClassifyModule = & $w4NewModule ($w4ClassifyStubs + "`n" + $w4ProfileStubs + "`n" + $w4RuntimeText + "`n" + $w4ModuleText + "`n" + $w4SystemText) (
        @('Read-BRAVOServiceQuiescenceState', 'Get-Service', 'Get-BRAVOWin32ServiceInfo') +
        $w4ProfileStubNames +
        @('Invoke-BRAVOMaintenanceServiceRecoveryProfile') + @($w4ModuleFunctions) +
        @('Get-BRAVOManagedServiceCondition', 'Get-BRAVOServiceStartMode', 'Test-BRAVOServiceDisabledByOperator', 'Get-BRAVOManagedServiceOrder'))
    $w4SuppressedClassified = $null
    try {
        $w4SuppressedClassified = & $w4RealClassifyModule {
            param($Marker)
            $script:W4Marker = $Marker
            $script:W4MarkerReads = 0
            $script:W4ServiceStatus = @{ BRAVO = 'Running'; exchangAPI = 'Stopped'; 'Apache2.4' = 'Running' }
            Invoke-W4Profile -Conditions @()
        } $w4SuppressedMarker
    } catch {
        $w4SuppressedClassified = [pscustomobject]@{ ExitCode = $null; Error = $_.Exception.Message; Events = @(); LogCalls = @(); LockArgs = $null; LockExits = 0; StateWrites = 0 }
    }
    Test-BRAVOCondition `
        -Condition (
            $null -ne $w4SuppressedClassified -and $null -eq $w4SuppressedClassified.Error -and
            [int]$w4SuppressedClassified.ExitCode -eq 0 -and $null -eq $w4SuppressedClassified.LockArgs -and
            @($w4SuppressedClassified.Events | Where-Object { $_ -match '^(START|STATE|MARKER)' }).Count -eq 0 -and
            @($w4SuppressedClassified.LogCalls).Count -eq 0
        ) `
        -Name 'ServiceRecovery/ProfileSuppressedMarkerClassifiesOwnedByBravoNoStart' `
        -Failure "маркер restartSuppressed зі службою exchangAPI: класифікація OwnedByBravo, профіль виходить 0 без lock-а і без запуску: $(& $w4Describe $w4SuppressedClassified)"

    # Щасливий шлях: впала exchangAPI -> маркер BRAVO_MAINTENANCE_RECOVER,
    # журнал RECOVER з доказами (ExitCode, «події SCM недоступні»), журнали
    # служби, запуск з обліком спроби, маркер знято, звіт.
    $w4Exchange = & $w4RunProfile @{ Conditions = $w4ExchangeFailed }
    $w4ExchangeActions = @($w4Exchange.Events | Where-Object { $_ -match '^(MARKER|STATE|LOGS|START|CLEAR|REPORT)' })
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w4Exchange.Error -and [int]$w4Exchange.ExitCode -eq 0 -and
            ($w4ExchangeActions -join '; ') -ceq 'MARKER BRAVO_MAINTENANCE_RECOVER exchangAPI=True; LOGS ExchangeApi; START exchangAPI recovery=True; CLEAR; REPORT' -and
            [string]$w4Exchange.MarkerLogFile -match '_RECOVER_PID\d+\.log$' -and
            [string](@($w4Exchange.LogCalls) | Select-Object -First 1) -ceq 'INFO|=== ВІДНОВЛЕННЯ СЛУЖБ (-RecoverServices) ===' -and
            @($w4Exchange.LogCalls | Where-Object { $_ -match 'exchangAPI' -and $_ -match 'ExitCode=1067' -and $_ -match 'StartMode=Automatic' -and $_ -match 'ServiceSpecificExitCode=0' }).Count -ge 1 -and
            @($w4Exchange.LogCalls | Where-Object { $_ -match 'події SCM недоступні' }).Count -ge 1 -and
            @(& $w4ForbiddenEvents $w4Exchange).Count -eq 0 -and
            [int]$w4Exchange.LockExits -eq 1
        ) `
        -Name 'ServiceRecovery/ProfileStartsFailedExchangeApiUnderMarker' `
        -Failure "впала exchangAPI: маркер BRAVO_MAINTENANCE_RECOVER -> журнали служби -> запуск з обліком (-RecoveryCondition) -> маркер знято -> звіт; журнал RECOVER починається заголовком і містить StartMode/Status/ExitCode/ServiceSpecificExitCode і рядок про недоступні події SCM; без Stop-BRAVOMaintenanceStrayProcess, Set-/Start-/Stop-Service напряму і стану задачі Maintenance: $(& $w4Describe $w4Exchange)"

    # Впала BRAVO: зупинка залежних (BRAVO Web -> exchangAPI) без точки
    # розширення Bis, журнали BRAVO, запуск усіх у порядку BRAVO -> exchangAPI
    # -> BRAVO Web (обліковується лише впала BRAVO).
    $w4Bravo = & $w4RunProfile @{ Conditions = $w4BravoFailed }
    $w4BravoActions = @($w4Bravo.Events | Where-Object { $_ -match '^(MARKER|STATE|LOGS|START|CLEAR|REPORT)' })
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w4Bravo.Error -and [int]$w4Bravo.ExitCode -eq 0 -and
            ($w4BravoActions -join '; ') -ceq ('MARKER BRAVO_MAINTENANCE_RECOVER BRAVO=True,exchangAPI=True,Apache2.4=True; STATE Apache2.4 Stopped; STATE exchangAPI Stopped; LOGS Bravo; ' +
                'START BRAVO recovery=True; START exchangAPI recovery=False; START Apache2.4 recovery=False; CLEAR; REPORT') -and
            @(& $w4ForbiddenEvents $w4Bravo).Count -eq 0
        ) `
        -Name 'ServiceRecovery/ProfileBravoFailedRestartsDependentsInCanonicalOrder' `
        -Failure "впала BRAVO: маркер на всі три служби, зупинка BRAVO Web і exchangAPI, журнали BRAVO, запуск BRAVO -> exchangAPI -> BRAVO Web, без Stop-BRAVOMaintenanceStrayProcess: $(& $w4Describe $w4Bravo)"

    # Збій запису маркера -> нічого не зупиняти/запускати, CRITICAL, вихід 60.
    $w4MarkerFails = & $w4RunProfile @{ Conditions = $w4ExchangeFailed; MarkerWriteFails = $true }
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w4MarkerFails.Error -and [int]$w4MarkerFails.ExitCode -eq 60 -and
            @($w4MarkerFails.Events | Where-Object { $_ -match '^(START|STATE|LOGS|CLEAR)' }).Count -eq 0 -and
            @($w4MarkerFails.Events | Where-Object { $_ -eq 'SLACK  True' }).Count -eq 1 -and
            [int]$w4MarkerFails.LockExits -eq 1
        ) `
        -Name 'ServiceRecovery/ProfileMarkerWriteFailureAbortsWith60' `
        -Failure "збій запису ownership-маркера: жодних зупинок/запусків, Send-SlackAlert -IsCritical, вихід 60: $(& $w4Describe $w4MarkerFails)"

    # Невдалий запуск -> маркер лишається (Health-watchdog доспробує), вихід 60.
    $w4StartFails = & $w4RunProfile @{ Conditions = $w4ExchangeFailed; StartFailures = @('exchangAPI') }
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w4StartFails.Error -and [int]$w4StartFails.ExitCode -eq 60 -and
            @($w4StartFails.Events | Where-Object { $_ -eq 'START exchangAPI recovery=True' }).Count -eq 1 -and
            @($w4StartFails.Events | Where-Object { $_ -eq 'CLEAR' }).Count -eq 0 -and
            @($w4StartFails.Events | Where-Object { $_ -eq 'REPORT' }).Count -eq 1
        ) `
        -Name 'ServiceRecovery/ProfileStartFailureKeepsMarker' `
        -Failure "невдалий запуск впалої служби: маркер не знімається, звіт надсилається, вихід 60: $(& $w4Describe $w4StartFails)"

    # ============================================================
    # Тест 5 (lock): -NoWait — одна спроба без Start-Sleep і без журналу;
    # -OperationName — поле operation у JSON lock-а.
    # ============================================================
    $w4LockStubs = @'
function Get-BRAVOOperationLockWaitBudget {
    param($SchedulerSettings, $TaskType)
    return [pscustomobject]@{ EffectiveMinutes = 30; LimitDescription = '' }
}
function Start-Sleep {
    param([int]$Seconds)
    $script:W4Sleeps++
    throw 'self-test: Start-Sleep під -NoWait заборонено'
}
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $script:W4LockLog += @($Message)
}
'@
    $w4LockModule = & $w4NewModule ($w4LockStubs + "`n" + $w4RuntimeText) @('Get-BRAVOOperationLockWaitBudget', 'Start-Sleep', 'Write-Log', 'Enter-BRAVOMaintenanceOperationLock')
    $w4LockRoot = Join-Path ([IO.Path]::GetTempPath()) ("bravo_selftest_w4lock_{0}" -f ([guid]::NewGuid().ToString('N')))
    [void][IO.Directory]::CreateDirectory($w4LockRoot)
    $w4LockProbe = $null
    try {
        $w4BusyPath = Join-Path $w4LockRoot 'busy.lock'
        [void][IO.Directory]::CreateDirectory($w4BusyPath)
        $w4LockProbe = & $w4LockModule {
            param($BusyPath, $FreePath)
            $script:operationLockSettings = @{ Path = $BusyPath }
            $script:schedulerSettings = @{}
            $script:ScriptVersion = '0.0.0-selftest'
            $script:ConfigPath = 'C:\BRAVO\BRAVO.config'
            $script:W4Sleeps = 0
            $script:W4LockLog = @()
            $busy = $null; $busyError = $null
            try { $busy = Enter-BRAVOMaintenanceOperationLock -TaskType Maintenance -NoWait -OperationName 'ServiceRecovery' } catch { $busyError = $_.Exception.Message }
            $busySleeps = $script:W4Sleeps
            $busyLog = @($script:W4LockLog).Count
            $script:operationLockSettings = @{ Path = $FreePath }
            $free = $null; $freeOperation = $null; $freeError = $null
            try {
                $free = Enter-BRAVOMaintenanceOperationLock -TaskType Maintenance -NoWait -OperationName 'ServiceRecovery'
                if ($null -ne $free -and $free.Success) {
                    $free.Stream.Dispose()
                    $freeOperation = [string](([IO.File]::ReadAllText($FreePath)) | ConvertFrom-Json).operation
                }
            } catch { $freeError = $_.Exception.Message }
            $defaultOperation = $null
            try {
                $default = Enter-BRAVOMaintenanceOperationLock -TaskType Maintenance
                if ($null -ne $default -and $default.Success) {
                    $default.Stream.Dispose()
                    $defaultOperation = [string](([IO.File]::ReadAllText($FreePath)) | ConvertFrom-Json).operation
                }
            } catch { $defaultOperation = "помилка: $($_.Exception.Message)" }
            return [pscustomobject]@{
                BusySuccess = $(if ($null -ne $busy) { [bool]$busy.Success } else { $null }); BusyError = $busyError
                BusySleeps = $busySleeps; BusyLog = $busyLog
                FreeSuccess = $(if ($null -ne $free) { [bool]$free.Success } else { $null }); FreeOperation = $freeOperation; FreeError = $freeError
                DefaultOperation = $defaultOperation
            }
        } $w4BusyPath (Join-Path $w4LockRoot 'free.lock')
    } catch {
        $w4LockProbe = [pscustomobject]@{ BusySuccess = $null; BusyError = $_.Exception.Message; BusySleeps = -1; BusyLog = -1; FreeSuccess = $null; FreeOperation = $null; FreeError = $null; DefaultOperation = $null }
    } finally {
        Remove-Item -LiteralPath $w4LockRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w4LockProbe.BusyError -and $w4LockProbe.BusySuccess -eq $false -and
            [int]$w4LockProbe.BusySleeps -eq 0 -and [int]$w4LockProbe.BusyLog -eq 0 -and
            $w4LockProbe.FreeSuccess -eq $true -and [string]$w4LockProbe.FreeOperation -ceq 'ServiceRecovery' -and
            [string]$w4LockProbe.DefaultOperation -ceq 'Maintenance'
        ) `
        -Name 'ServiceRecovery/LockEnterNoWaitDoesNotSleep' `
        -Failure ("Enter-BRAVOMaintenanceOperationLock -NoWait: зайнятий lock -> одна спроба, Success=`$false без Start-Sleep і Write-Log; -OperationName пишеться в поле operation (за замовчуванням 'Maintenance'). " +
            "busy=$($w4LockProbe.BusySuccess) помилка='$($w4LockProbe.BusyError)' sleeps=$($w4LockProbe.BusySleeps) log=$($w4LockProbe.BusyLog) free=$($w4LockProbe.FreeSuccess)/'$($w4LockProbe.FreeOperation)' '$($w4LockProbe.FreeError)' default='$($w4LockProbe.DefaultOperation)'")

    # ============================================================
    # Проводка параметра і статичні заборони профілю.
    # ============================================================
    $w4EntryAst = [Management.Automation.Language.Parser]::ParseInput($w4EntryText, [ref]$null, [ref]$null)
    $w4EntryParams = @($w4EntryAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $w4EntryLines = @($w4EntryText -split "`r?`n").Count
    $w4RuntimeScriptParams = @($w4RuntimeAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $w4MaintenanceFunction = & $w4FindRuntimeFunction 'Invoke-BRAVOMaintenance'
    $w4MaintenanceParams = @()
    if ($null -ne $w4MaintenanceFunction -and $null -ne $w4MaintenanceFunction.Body.ParamBlock) {
        $w4MaintenanceParams = @($w4MaintenanceFunction.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    }
    Test-BRAVOCondition `
        -Condition (
            $w4EntryParams -contains 'RecoverServices' -and
            $w4EntryText -match 'RecoverServices\s*=\s*\$RecoverServices' -and
            $w4EntryLines -le 250 -and
            $w4RuntimeScriptParams -contains 'RecoverServices' -and
            $w4MaintenanceParams -contains 'RecoverServices' -and
            $w4RuntimeText -match 'if \(\$RecoverServices\) \{ \$elevatedArguments \+= "-RecoverServices" \}'
        ) `
        -Name 'ServiceRecovery/RecoverServicesParameterWiring' `
        -Failure "-RecoverServices: параметр BRAVO_MAINTENANCE.ps1 (≤250 рядків, рядків=$w4EntryLines) передається в runtime, є в param() скрипта і Invoke-BRAVOMaintenance і зберігається при елевації; entry=[$($w4EntryParams -join ',')] runtime=[$($w4RuntimeScriptParams -join ',')] fn=[$($w4MaintenanceParams -join ',')]"

    $w4ConflictIf = $null
    if ($null -ne $w4MaintenanceFunction) {
        $w4ConflictIf = @($w4MaintenanceFunction.Body.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses[0].Item1.Extent.Text -match '\$RecoverServices' -and
                    $node.Clauses[0].Item1.Extent.Text -match '\$ForceRestore' -and
                    $node.Clauses[0].Item1.Extent.Text -match '\$RunMissedRestoreOnly'
                }, $true)) | Select-Object -First 1
    }
    $w4ConflictOffset = if ($null -ne $w4ConflictIf) { $w4ConflictIf.Extent.StartOffset } else { -1 }
    $w4ElevationOffset = $w4RuntimeText.IndexOf('$elevatedProcess = Start-Process powershell.exe')
    $w4ClearHostOffset = $w4RuntimeText.IndexOf("`nClear-Host")
    Test-BRAVOCondition `
        -Condition (
            $null -ne $w4ConflictIf -and
            $w4ConflictIf.Clauses[0].Item2.Extent.Text -match 'exit \(Resolve-BRAVOExitCode -InvalidConfiguration\)' -and
            $w4ConflictOffset -ge 0 -and $w4ElevationOffset -gt $w4ConflictOffset -and $w4ClearHostOffset -gt $w4ConflictOffset
        ) `
        -Name 'ServiceRecovery/RecoverServicesConflictExits30' `
        -Failure "-RecoverServices з -ForceRestore/-RunMissedRestoreOnly: exit (Resolve-BRAVOExitCode -InvalidConfiguration) = 30 до елевації і Clear-Host; знайдено=$($null -ne $w4ConflictIf) offset=$w4ConflictOffset elevation=$w4ElevationOffset clear=$w4ClearHostOffset"

    $w4LogFileAnchor = $w4RuntimeText.IndexOf('$script:LOG_FILE = "$LOG_DIR\BRAVO_MAINTENANCE_$maintenanceLogRunId.log"')
    $w4StepsAnchor = $w4RuntimeText.IndexOf('Initialize-BRAVOMaintenanceSteps -Total 8')
    $w4BranchIf = $null
    if ($null -ne $w4MaintenanceFunction) {
        $w4BranchIf = @($w4MaintenanceFunction.Body.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses[0].Item1.Extent.Text -eq '$RecoverServices' -and
                    $node.Clauses[0].Item2.Extent.Text.Contains('Invoke-BRAVOMaintenanceServiceRecoveryProfile')
                }, $true)) | Select-Object -First 1
    }
    $w4BranchOffset = if ($null -ne $w4BranchIf) { $w4BranchIf.Extent.StartOffset } else { -1 }
    Test-BRAVOCondition `
        -Condition (
            $null -ne $w4BranchIf -and $w4LogFileAnchor -ge 0 -and $w4StepsAnchor -gt $w4BranchOffset -and $w4BranchOffset -gt $w4LogFileAnchor -and
            $w4BranchIf.Extent.Text -match 'BRAVO_MAINTENANCE_\{0\}_RECOVER_PID\{1\}\.log' -and
            $w4BranchIf.Extent.Text -match '\bexit\b'
        ) `
        -Name 'ServiceRecovery/RecoverProfileBranchesBeforeFirstLogWrite' `
        -Failure "розгалуження if (`$RecoverServices) { ... Invoke-BRAVOMaintenanceServiceRecoveryProfile ... exit } — після визначення LOG_FILE і до Initialize-BRAVOMaintenanceSteps, журнал BRAVO_MAINTENANCE_<ts>_RECOVER_PID<pid>.log; знайдено=$($null -ne $w4BranchIf) offset=$w4BranchOffset logFile=$w4LogFileAnchor steps=$w4StepsAnchor"

    $w4ProfileFunctionNames = @('Invoke-BRAVOMaintenanceServiceRecoveryProfile', 'Initialize-BRAVOMaintenanceServiceRecoveryLogSources', 'Get-BRAVOMaintenanceServiceRecoveryServices')
    $w4ProfileFunctions = @($w4ProfileFunctionNames | ForEach-Object { & $w4FindRuntimeFunction $_ } | Where-Object { $null -ne $_ })
    $w4ForbiddenCommands = @('Stop-BRAVOMaintenanceStrayProcess', 'Invoke-BRAVOMaintenanceBeforeServiceStopHook', 'Stop-BRAVOMaintenanceManagedService',
        'Stop-BRAVOMaintenanceManagedServices', 'Start-BRAVOMaintenanceManagedServices', 'Write-BRAVOTaskExecutionState', 'Write-BRAVOOperationStatus',
        'Send-BRAVOMaintenanceOperationsEvent', 'Send-FinalReport', 'Set-Service', 'Set-BRAVOServiceStartMode', 'Suspend-BRAVOServiceAutostart',
        'Start-Service', 'Stop-Service', 'Initialize-BRAVOMaintenanceSteps')
    $w4ForbiddenFound = @($w4ProfileFunctions | ForEach-Object {
            $_.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) |
                Where-Object { $w4ForbiddenCommands -contains $_.GetCommandName() } |
                ForEach-Object { $_.GetCommandName() }
        } | Select-Object -Unique)
    Test-BRAVOCondition `
        -Condition (
            $w4ProfileFunctions.Count -eq $w4ProfileFunctionNames.Count -and
            $w4ForbiddenFound.Count -eq 0 -and
            $w4RuntimeText -notmatch 'Set-Service'
        ) `
        -Name 'ServiceRecovery/RecoverProfileForbiddenCalls' `
        -Failure ("профіль -RecoverServices не пише стан задачі Maintenance/статус операції, не викликає Stop-BRAVOMaintenanceStrayProcess (точка #316), не змінює типи запуску і керує службами лише через Invoke-ServiceStateChange/Start-BRAVOMaintenanceManagedService; runtime не містить Set-Service. " +
            "функцій=$($w4ProfileFunctions.Count)/$($w4ProfileFunctionNames.Count) заборонені=[$($w4ForbiddenFound -join ', ')]")
}

# ============================================================
# #314 хвиля 5: FR-4 задача BRAVO_SERVICE_RECOVERY і FR-7 Health.
#   Тест 8 — тригери задачі: фейковий ITaskDefinition (Linux), справжній
#            COM Schedule.Service без реєстрації (лише Windows), чиста
#            перевірка визначення для BRAVO_TASKS_DIAGNOSE і інсталятор
#            на фейковому планувальнику.
#   Тест 9 — Health при Failed+Stopped запускає задачу відновлення (один
#            раз за прогін), а не службу; відсутня/вимкнена задача —
#            окремий issue; Disabled — без issue; fingerprint алерту не
#            залежить від ActionText.
#   Решта  — похідний вузол schedulerSettings.ServiceRecovery (Derivation
#            і legacy-гілка завантажувача), проводка типу задачі в
#            Install/Diagnose/Uninstall.
# ============================================================
& {
    $w5ReadText = {
        param([string]$RelativePath)
        [IO.File]::ReadAllText((Join-Path $root $RelativePath), [Text.Encoding]::UTF8)
    }
    $w5ModuleText = & $w5ReadText 'modules\BRAVO.ServiceRecovery\BRAVO.ServiceRecovery.psm1'
    $w5SystemText = & $w5ReadText 'modules\BRAVO.System\BRAVO.System.psm1'
    $w5InstallText = & $w5ReadText 'BRAVO_TASKS_INSTALL.ps1'
    $w5DiagnoseText = & $w5ReadText 'BRAVO_TASKS_DIAGNOSE.ps1'
    $w5UninstallText = & $w5ReadText 'BRAVO_TASKS_UNINSTALL.ps1'
    $w5HealthText = & $w5ReadText 'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1'
    $w5DerivationText = & $w5ReadText 'modules\BRAVO.Configuration\BRAVO.Configuration.Derivation.psm1'
    $w5LoaderText = & $w5ReadText 'BRAVO_CONFIG_LOADER.ps1'
    $w5ParityText = & $w5ReadText 'ci\Test-BRAVOConfigFoundationParity.ps1'
    $w5FunctionNamesIn = {
        param([string]$Text)
        $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
        return @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst]
                }, $true) | ForEach-Object { $_.Name } | Select-Object -Unique)
    }
    $w5FindFunction = {
        param([string]$Text, [string]$FunctionName)
        $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
        @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName
                }, $true)) | Select-Object -First 1
    }
    # Тестовий модуль лише з тих функцій, що справді є в тексті (RED: відсутня
    # функція дає збій виклику в тесті, а не падіння фрагмента); заглушки
    # командлетів прибираються з глобальної області.
    $w5NewModule = {
        param([string]$SourceText, [string[]]$FunctionNames)
        $available = @(& $w5FunctionNamesIn $SourceText)
        $present = @($FunctionNames | Select-Object -Unique | Where-Object { $available -contains $_ })
        $module = New-BRAVOSelfTestRuntimeModule -SourceText $SourceText -FunctionNames $present
        foreach ($stubName in $present) {
            if ($null -eq (Get-Command -Name $stubName -CommandType Cmdlet -ErrorAction SilentlyContinue)) { continue }
            $leaked = Get-Command -Name $stubName -CommandType Function -ErrorAction SilentlyContinue
            if ($null -ne $leaked -and $leaked.ModuleName -eq $module.Name) {
                Remove-Item -Path ('function:' + $stubName) -Force -ErrorAction Stop
            }
        }
        return $module
    }
    $w5ModuleFunctions = @(& $w5FunctionNamesIn $w5ModuleText)

    # Фейковий ITaskDefinition: Triggers/Actions — колекції з методом
    # Create(type), як у COM Task Scheduler 2.0.
    $w5NewFakeDefinition = {
        $triggers = New-Object System.Collections.ArrayList
        Add-Member -InputObject $triggers -MemberType ScriptMethod -Name Create -Value {
            param([int]$Type)
            $trigger = [pscustomobject]@{
                Type = $Type; Enabled = $false; Delay = ''; Subscription = ''; StartBoundary = ''; DaysInterval = 0
                Repetition = [pscustomobject]@{ Interval = ''; Duration = ''; StopAtDurationEnd = $true }
            }
            [void]$this.Add($trigger)
            return $trigger
        }
        $actions = New-Object System.Collections.ArrayList
        Add-Member -InputObject $actions -MemberType ScriptMethod -Name Create -Value {
            param([int]$Type)
            $action = [pscustomobject]@{ Type = $Type; Path = ''; Arguments = ''; WorkingDirectory = '' }
            [void]$this.Add($action)
            return $action
        }
        [pscustomobject]@{
            RegistrationInfo = [pscustomobject]@{ Description = '' }
            Settings = [pscustomobject]@{
                Enabled = $false; StartWhenAvailable = $true; WakeToRun = $false; Hidden = $false
                DisallowStartIfOnBatteries = $true; StopIfGoingOnBatteries = $true; MultipleInstances = 0
                ExecutionTimeLimit = ''; RestartCount = 0; RestartInterval = ''
            }
            Principal = [pscustomobject]@{ UserId = ''; LogonType = 0; RunLevel = 0 }
            Triggers = $triggers
            Actions = $actions
            XmlText = ''
        }
    }
    $w5DescribeTriggers = {
        param($Definition)
        @(@($Definition.Triggers) | ForEach-Object {
                '{0}:{1}:{2}:{3}:{4}' -f $_.Type, [bool]$_.Enabled, $_.Delay, $_.Repetition.Interval, $_.DaysInterval
            }) -join ' '
    }

    # ============================================================
    # Тест 8 (Linux): тригери на фейковому визначенні.
    # ============================================================
    $w5TriggerModule = & $w5NewModule ($w5ModuleText + "`n" + $w5SystemText) (@($w5ModuleFunctions) + @('Get-BRAVOManagedServiceOrder'))
    $w5Fake = & $w5NewFakeDefinition
    $w5Today = New-Object DateTime(2026, 10, 7, 0, 0, 0)
    $w5BuildError = $null
    $w5FakeProblems = @('<не виконано>')
    try {
        & $w5TriggerModule {
            param($Definition, $Today)
            Set-StrictMode -Version 2.0
            Add-BRAVOServiceRecoveryTaskTriggers -Definition $Definition -Today $Today
        } $w5Fake $w5Today
        $w5FakeProblems = @(& $w5TriggerModule {
                param($Definition)
                Set-StrictMode -Version 2.0
                Test-BRAVOServiceRecoveryTaskDefinition -Definition $Definition
            } $w5Fake)
    } catch {
        $w5BuildError = $_.Exception.Message
    }
    $w5FakeTriggers = @($w5Fake.Triggers)
    $w5EventTrigger = @($w5FakeTriggers | Where-Object { $_.Type -eq 0 }) | Select-Object -First 1
    $w5DailyTrigger = @($w5FakeTriggers | Where-Object { $_.Type -eq 2 }) | Select-Object -First 1
    $w5Subscription = if ($null -ne $w5EventTrigger) { [string]$w5EventTrigger.Subscription } else { '' }
    $w5MissingIds = @(7000, 7009, 7011, 7022, 7023, 7024, 7031, 7034 | Where-Object { $w5Subscription -notmatch "EventID=$_\b" })
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w5BuildError -and
            (& $w5DescribeTriggers $w5Fake) -ceq '0:True:PT1M::0 8:True:PT10M::0 2:True::PT15M:1' -and
            $w5Subscription -match '<QueryList>' -and $w5Subscription -match 'Path="System"' -and
            $w5Subscription -match "Provider\[@Name='Service Control Manager'\]" -and $w5MissingIds.Count -eq 0 -and
            $null -ne $w5DailyTrigger -and [string]$w5DailyTrigger.StartBoundary -ceq '2026-10-07T00:00:00' -and
            [string]$w5DailyTrigger.Repetition.Duration -ceq 'P1D' -and -not [bool]$w5DailyTrigger.Repetition.StopAtDurationEnd -and
            [int]$w5Fake.Settings.MultipleInstances -eq 2 -and [string]$w5Fake.Settings.ExecutionTimeLimit -ceq 'PT1H' -and
            -not [bool]$w5Fake.Settings.StartWhenAvailable -and
            @($w5FakeProblems).Count -eq 0
        ) `
        -Name 'ServiceRecovery/TaskTriggersBuiltOnFakeDefinition' `
        -Failure ("Add-BRAVOServiceRecoveryTaskTriggers: три тригери — подія SCM (8 EventID, Delay PT1M), старт ОС (Delay PT10M), щодня з 00:00 з повтором PT15M на P1D; MultipleInstances=2 (IgnoreNew), ExecutionTimeLimit PT1H, StartWhenAvailable=false; Test-BRAVOServiceRecoveryTaskDefinition без проблем. " +
            "помилка='$w5BuildError' тригери='$(& $w5DescribeTriggers $w5Fake)' без EventID=[$($w5MissingIds -join ',')] проблеми=[$(@($w5FakeProblems) -join ' | ')]")

    # Diagnose: чиста перевірка ловить відсутній тригер і неправильні
    # параметри (фейк, побудований тією самою функцією, потім зіпсований).
    $w5Broken = & $w5NewFakeDefinition
    $w5Damaged = & $w5NewFakeDefinition
    $w5BrokenProblems = @()
    $w5DamagedProblems = @()
    $w5DiagnoseError = $null
    try {
        & $w5TriggerModule {
            param($First, $Second, $Today)
            Add-BRAVOServiceRecoveryTaskTriggers -Definition $First -Today $Today
            Add-BRAVOServiceRecoveryTaskTriggers -Definition $Second -Today $Today
        } $w5Broken $w5Damaged $w5Today
        $w5Broken.Triggers.RemoveAt(1)
        $w5DamagedEvent = @($w5Damaged.Triggers)[0]
        $w5DamagedEvent.Subscription = ([string]$w5DamagedEvent.Subscription) -replace ' or EventID=7034', '' -replace 'EventID=7034 or ', ''
        $w5DamagedEvent.Delay = 'PT5M'
        @($w5Damaged.Triggers)[2].Repetition.Interval = 'PT1H'
        @($w5Damaged.Triggers)[1].Enabled = $false
        $w5Damaged.Settings.MultipleInstances = 0
        $w5Damaged.Settings.ExecutionTimeLimit = 'PT72H'
        $w5BrokenProblems = @(& $w5TriggerModule { param($Definition) Set-StrictMode -Version 2.0; Test-BRAVOServiceRecoveryTaskDefinition -Definition $Definition } $w5Broken)
        $w5DamagedProblems = @(& $w5TriggerModule { param($Definition) Set-StrictMode -Version 2.0; Test-BRAVOServiceRecoveryTaskDefinition -Definition $Definition } $w5Damaged)
    } catch {
        $w5DiagnoseError = $_.Exception.Message
    }
    $w5DamagedText = @($w5DamagedProblems) -join ' | '
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w5DiagnoseError -and
            @($w5BrokenProblems).Count -eq 1 -and [string]@($w5BrokenProblems)[0] -match 'старт' -and
            $w5DamagedText -match '7034' -and $w5DamagedText -match 'PT5M' -and $w5DamagedText -match 'PT1H' -and
            $w5DamagedText -match 'вимкнено' -and $w5DamagedText -match 'MultipleInstances' -and $w5DamagedText -match 'PT72H'
        ) `
        -Name 'ServiceRecovery/DiagnoseDetectsMissingTrigger' `
        -Failure ("Test-BRAVOServiceRecoveryTaskDefinition: без тригера старту ОС — одна проблема про нього; зіпсоване визначення — проблеми про відсутній EventID 7034, Delay PT5M, повтор PT1H, вимкнений тригер, MultipleInstances і ExecutionTimeLimit PT72H. " +
            "помилка='$w5DiagnoseError' без boot=[$(@($w5BrokenProblems) -join ' | ')] зіпсоване=[$w5DamagedText]")

    # ============================================================
    # Тест 8 (лише Windows): справжній COM Schedule.Service, без реєстрації
    # (NewTask лише в пам'яті; XmlText іншого NewTask — перевірка схеми
    # планувальником). Поза Windows — доведена відсутність COM.
    # ============================================================
    $w5IsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    $w5ComXml = ''
    $w5ComProblems = @('<не виконано>')
    $w5ComError = $null
    $w5ComAbsent = $false
    if ($w5IsWindows) {
        $w5TaskService = $null
        try {
            $w5TaskService = New-Object -ComObject 'Schedule.Service'
            $w5TaskService.Connect()
            $w5ComResult = & $w5TriggerModule {
                param($TaskService)
                Set-StrictMode -Version 2.0
                $definition = $TaskService.NewTask(0)
                Add-BRAVOServiceRecoveryTaskTriggers -Definition $definition
                $action = $definition.Actions.Create(0)
                $action.Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $action.Arguments = '-NoProfile -File BRAVO_MAINTENANCE.ps1 -NoPause -RecoverServices'
                $validated = $TaskService.NewTask(0)
                $validated.XmlText = $definition.XmlText
                [pscustomobject]@{
                    Xml = [string]$validated.XmlText
                    Problems = @(Test-BRAVOServiceRecoveryTaskDefinition -Definition $validated)
                }
            } $w5TaskService
            $w5ComXml = [string]$w5ComResult.Xml
            $w5ComProblems = @($w5ComResult.Problems)
        } catch {
            $w5ComError = $_.Exception.Message
        } finally {
            if ($null -ne $w5TaskService) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($w5TaskService) }
        }
    } else {
        try {
            [void](New-Object -ComObject 'Schedule.Service' -ErrorAction Stop)
        } catch {
            $w5ComAbsent = $true
        }
    }
    $w5ComXmlOk = (
        $w5ComXml.Contains('<EventTrigger>') -and $w5ComXml.Contains('<BootTrigger>') -and $w5ComXml.Contains('<CalendarTrigger>') -and
        $w5ComXml.Contains('<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>') -and
        $w5ComXml.Contains('<ExecutionTimeLimit>PT1H</ExecutionTimeLimit>') -and
        $w5ComXml.Contains('<Delay>PT1M</Delay>') -and $w5ComXml.Contains('<Delay>PT10M</Delay>') -and
        $w5ComXml.Contains('<Interval>PT15M</Interval>') -and $w5ComXml.Contains('EventID=7034')
    )
    Test-BRAVOCondition `
        -Condition $(if ($w5IsWindows) { $null -eq $w5ComError -and $w5ComXmlOk -and @($w5ComProblems).Count -eq 0 } else { $w5ComAbsent }) `
        -Name 'ServiceRecovery/TaskXmlViaComContainsThreeTriggers' `
        -Failure ("Windows: визначення з Add-BRAVOServiceRecoveryTaskTriggers проходить перевірку XML планувальника — EventTrigger/BootTrigger/CalendarTrigger, IgnoreNew, PT1H, Delay PT1M/PT10M, Interval PT15M, EventID у Subscription — і Test-BRAVOServiceRecoveryTaskDefinition на прочитаному з COM визначенні без проблем; поза Windows COM відсутній. " +
            "windows=$w5IsWindows помилка='$w5ComError' comВідсутній=$w5ComAbsent проблеми=[$(@($w5ComProblems) -join ' | ')]")

    # ============================================================
    # Інсталятор на фейковому планувальнику: справжня New-BRAVOTaskDefinition
    # -TaskType ServiceRecovery (Linux, без COM).
    # ============================================================
    $w5InstallModule = & $w5NewModule ($w5InstallText + "`n" + $w5ModuleText + "`n" + $w5SystemText) (
        @('New-BRAVOTaskDefinition', 'ConvertTo-ScheduleTime', 'ConvertTo-BRAVOMultipleInstancesPolicy',
            'Get-BRAVOExpectedSchedulerPrincipal', 'ConvertTo-BRAVOSchedulerLogonType', 'ConvertTo-BRAVOSchedulerExecutionTimeLimit') +
        @($w5ModuleFunctions))
    $w5ScriptDirectory = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_W5_TASK_' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($w5ScriptDirectory)
    $w5ScriptPath = Join-Path $w5ScriptDirectory 'BRAVO_MAINTENANCE.ps1'
    [IO.File]::WriteAllText($w5ScriptPath, '# self-test')
    $w5FakeService = [pscustomobject]@{ Factory = $w5NewFakeDefinition; Created = (New-Object System.Collections.ArrayList) }
    Add-Member -InputObject $w5FakeService -MemberType ScriptMethod -Name NewTask -Value {
        param([int]$Flags)
        $definition = & $this.Factory
        [void]$this.Created.Add($definition)
        return $definition
    }
    $w5InstallError = $null
    try {
        [void](& $w5InstallModule {
                param($TaskService, $ScriptPath)
                Set-StrictMode -Version 2.0
                $script:schedulerSettings = @{
                    StartWhenAvailable = $true; WakeToRun = $false; Hidden = $false; AllowStartIfOnBatteries = $true
                    DontStopIfGoingOnBatteries = $true; MultipleInstances = 'Queue'; RestartCount = 0; RestartIntervalMinutes = 0
                    RunAsUser = 'SYSTEM'; LogonType = 'ServiceAccount'; WindowStyle = 'Hidden'; PowerShellExecutable = 'powershell.exe'
                }
                New-BRAVOTaskDefinition -TaskService $TaskService -TaskType 'ServiceRecovery' -ResolvedConfigPath 'C:\BRAVO\BRAVO.config' -TaskSettings @{
                    Enabled = $true; TaskName = 'BRAVO_SERVICE_RECOVERY'; Description = 'self-test'
                    ExecutionTimeLimitHours = 1; ScriptPath = $ScriptPath
                }
            } $w5FakeService $w5ScriptPath)
    } catch {
        $w5InstallError = $_.Exception.Message
    } finally {
        Remove-Item -LiteralPath $w5ScriptDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    $w5InstalledDefinition = if ($w5FakeService.Created.Count -gt 0) { $w5FakeService.Created[0] } else { $null }
    $w5InstalledArguments = if ($null -ne $w5InstalledDefinition -and @($w5InstalledDefinition.Actions).Count -gt 0) { [string]@($w5InstalledDefinition.Actions)[0].Arguments } else { '' }
    $w5InstalledTriggers = if ($null -ne $w5InstalledDefinition) { & $w5DescribeTriggers $w5InstalledDefinition } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w5InstallError -and $null -ne $w5InstalledDefinition -and
            $w5InstalledTriggers -ceq '0:True:PT1M::0 8:True:PT10M::0 2:True::PT15M:1' -and
            [int]$w5InstalledDefinition.Settings.MultipleInstances -eq 2 -and
            [string]$w5InstalledDefinition.Settings.ExecutionTimeLimit -ceq 'PT1H' -and
            -not [bool]$w5InstalledDefinition.Settings.StartWhenAvailable -and
            $w5InstalledArguments.Contains("-File `"$w5ScriptPath`"") -and
            $w5InstalledArguments -match '-NoPause -RecoverServices$' -and
            $w5InstalledArguments -notmatch '-ConfigPath'
        ) `
        -Name 'ServiceRecovery/InstallBuildsRecoveryTaskOnFakeScheduler' `
        -Failure ("New-BRAVOTaskDefinition -TaskType ServiceRecovery: три тригери з Add-BRAVOServiceRecoveryTaskTriggers, IgnoreNew незалежно від глобального MultipleInstances=Queue, ExecutionTimeLimit PT1H, StartWhenAvailable=false, дія -File BRAVO_MAINTENANCE.ps1 ... -NoPause -RecoverServices без -ConfigPath в AUTO-режимі. " +
            "помилка='$w5InstallError' тригери='$w5InstalledTriggers' аргументи='$w5InstalledArguments'")

    # ============================================================
    # Проводка типу задачі: ValidateSet-и, taskPlans, очікувані аргументи
    # Diagnose, видалення в Uninstall, імпорт модуля, журнал типів запуску.
    # ============================================================
    $w5ValidateSetHas = {
        param([string]$Text, [string]$FunctionName)
        $function = & $w5FindFunction $Text $FunctionName
        if ($null -eq $function) { return $false }
        $attribute = @($function.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.AttributeAst] -and $node.TypeName.Name -eq 'ValidateSet'
                }, $true)) | Select-Object -First 1
        return ($null -ne $attribute -and @($attribute.PositionalArguments | ForEach-Object { $_.Value }) -contains 'ServiceRecovery')
    }
    $w5NewDefinitionFunction = & $w5FindFunction $w5InstallText 'New-BRAVOTaskDefinition'
    $w5NewDefinitionText = if ($null -ne $w5NewDefinitionFunction) { $w5NewDefinitionFunction.Extent.Text } else { '' }
    $w5DefinitionCheckFunction = & $w5FindFunction $w5DiagnoseText 'Test-BRAVOScheduledTaskDefinition'
    $w5DefinitionCheckText = if ($null -ne $w5DefinitionCheckFunction) { $w5DefinitionCheckFunction.Extent.Text } else { '' }
    $w5WiringChecks = [ordered]@{
        InstallValidateSet = (& $w5ValidateSetHas $w5InstallText 'New-BRAVOTaskDefinition')
        InstallSummaryValidateSet = (& $w5ValidateSetHas $w5InstallText 'Format-BRAVOInstalledTaskSummaryNextRun')
        InstallBuildsTriggers = $w5NewDefinitionText.Contains('Add-BRAVOServiceRecoveryTaskTriggers -Definition $definition')
        InstallRecoverServicesArgument = $w5NewDefinitionText.Contains('$actionArguments += " -RecoverServices"')
        InstallTaskPlan = $w5InstallText.Contains('[pscustomobject]@{ Type = "ServiceRecovery"; Settings = $serviceRecoverySettings }')
        InstallImportsModule = $w5InstallText.Contains('modules\BRAVO.ServiceRecovery\BRAVO.ServiceRecovery.psd1')
        InstallStartModeJournal = $w5InstallText.Contains('Get-BRAVOManagedServiceStartModeLines')
        DiagnoseValidateSet = (& $w5ValidateSetHas $w5DiagnoseText 'Format-BRAVODiagnoseTaskNextRun')
        DiagnoseArguments = $w5DiagnoseText.Contains("ServiceRecovery = @('-NoPause', '-RecoverServices')")
        DiagnoseLoop = $w5DiagnoseText.Contains('"RestoreVerify", "BackupCatchUp", "ServiceRecovery")) {')
        DiagnoseChecksDefinition = $w5DefinitionCheckText.Contains('Test-BRAVOServiceRecoveryTaskDefinition -Definition $definition')
        DiagnoseImportsModule = $w5DiagnoseText.Contains('modules\BRAVO.ServiceRecovery\BRAVO.ServiceRecovery.psd1')
        UninstallTaskName = $w5UninstallText.Contains('$taskNames += [string]$schedulerSettings.ServiceRecovery.TaskName')
    }
    $w5WiringMissing = @($w5WiringChecks.Keys | Where-Object { -not [bool]$w5WiringChecks[$_] })
    Test-BRAVOCondition `
        -Condition ($w5WiringMissing.Count -eq 0) `
        -Name 'ServiceRecovery/TaskTypeWiredIntoInstallDiagnoseUninstall' `
        -Failure "тип задачі ServiceRecovery: ValidateSet-и, тригери і -RecoverServices у New-BRAVOTaskDefinition, елемент taskPlans, імпорт BRAVO.ServiceRecovery, журнал типів запуску, очікувані аргументи і перевірка визначення в Diagnose, ім'я в Uninstall; бракує: [$($w5WiringMissing -join ', ')]"

    $w5NextRunModule = & $w5NewModule $w5SystemText @('Format-BRAVOSchedulerNextRun')
    $w5NextRunText = ''
    try {
        $w5NextRunText = [string](& $w5NextRunModule {
                Format-BRAVOSchedulerNextRun -TaskType 'ServiceRecovery' -NextRunTime (New-Object DateTime(2026, 10, 7, 10, 15, 0))
            })
    } catch {
        $w5NextRunText = "помилка: $($_.Exception.Message)"
    }
    Test-BRAVOCondition `
        -Condition ($w5NextRunText -match 'SCM' -and $w5NextRunText -match 'старту Windows' -and $w5NextRunText -match '15 хв' -and $w5NextRunText -match '07\.10\.2026 10:15') `
        -Name 'ServiceRecovery/TaskNextRunDescribesAllTriggers' `
        -Failure "Format-BRAVOSchedulerNextRun -TaskType ServiceRecovery: за подією SCM, після старту Windows, кожні 15 хв і дата наступної періодичної перевірки; отримано '$w5NextRunText'"

    # ============================================================
    # Похідний вузол schedulerSettings.ServiceRecovery: однаковий у
    # Derivation і legacy-гілці завантажувача, без нових ключів конфігурації;
    # кожне поле поіменно в allowlist config-parity.
    # ============================================================
    $w5NodeOf = {
        param([string]$Text)
        $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
        $assignment = @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -eq '$global:schedulerSettings.ServiceRecovery' -and
                    $node.Right.Extent.Text.TrimStart().StartsWith('@{')
                }, $true)) | Select-Object -First 1
        if ($null -eq $assignment) { return $null }
        $hashtable = @($assignment.Right.FindAll({ param($node) $node -is [Management.Automation.Language.HashtableAst] }, $true)) | Select-Object -First 1
        $map = [ordered]@{}
        foreach ($pair in @($hashtable.KeyValuePairs)) {
            $map[[string]$pair.Item1.Extent.Text] = [string]$pair.Item2.Extent.Text
        }
        return $map
    }
    $w5DerivedNode = & $w5NodeOf $w5DerivationText
    $w5LoaderNode = & $w5NodeOf $w5LoaderText
    $w5NodeDescribe = {
        param($Map)
        if ($null -eq $Map) { return '<немає>' }
        (@($Map.Keys | Where-Object { $_ -ne 'ScriptPath' } | Sort-Object | ForEach-Object { '{0}={1}' -f $_, $Map[$_] }) -join '; ')
    }
    $w5ParityMissing = @('Description', 'Enabled', 'ExecutionTimeLimitHours', 'ScriptPath', 'TaskName' |
            Where-Object { -not $w5ParityText.Contains("'schedulerSettings.ServiceRecovery.$_'") })
    Test-BRAVOCondition `
        -Condition (
            $null -ne $w5DerivedNode -and $null -ne $w5LoaderNode -and
            (& $w5NodeDescribe $w5DerivedNode) -ceq (& $w5NodeDescribe $w5LoaderNode) -and
            [string]$w5DerivedNode['TaskName'] -ceq "'BRAVO_SERVICE_RECOVERY'" -and
            [string]$w5DerivedNode['ExecutionTimeLimitHours'] -ceq '1' -and
            [string]$w5DerivedNode['Enabled'] -ceq '$serviceRecoveryMaintenanceEnabled' -and
            [string]$w5DerivedNode['ScriptPath'] -match "BRAVO_MAINTENANCE\.ps1'" -and
            $w5LoaderText.Contains("`$global:schedulerSettings.ServiceRecovery.ScriptPath = Join-Path `$RuntimeRoot 'BRAVO_MAINTENANCE.ps1'") -and
            $w5DerivationText.Contains('[bool]$global:schedulerSettings.Maintenance.Enabled') -and
            $w5ParityMissing.Count -eq 0
        ) `
        -Name 'ServiceRecovery/SchedulerNodeDerivedIdenticallyInDerivationAndLoader' `
        -Failure ("schedulerSettings.ServiceRecovery — похідний вузол (Enabled = Maintenance.Enabled, TaskName BRAVO_SERVICE_RECOVERY, ExecutionTimeLimitHours 1, ScriptPath BRAVO_MAINTENANCE.ps1), однаковий у Derivation і legacy-гілці BRAVO_CONFIG_LOADER, кожне поле в allowlist Test-BRAVOConfigFoundationParity. " +
            "derivation='$(& $w5NodeDescribe $w5DerivedNode)' loader='$(& $w5NodeDescribe $w5LoaderNode)' parity без=[$($w5ParityMissing -join ', ')]")

    # ============================================================
    # Тест 9: Health (FR-7) — справжні Get-ManagedServiceHealthIssues і
    # Start-BRAVOHealthServiceRecoveryTask зі стабами SCM/WMI/маркера/
    # планувальника; Start-Service має лишитися невикликаним.
    # ============================================================
    $w5HealthStubs = @'
function Write-HealthLog {
    param($Message, $Level)
    $script:W5HealthLog += @("$Level|$Message")
}
function Get-Service {
    param($Name, $DisplayName, $ErrorAction)
    $key = if (-not [string]::IsNullOrWhiteSpace([string]$Name)) { [string]$Name } else { [string]$DisplayName }
    if (-not $script:W5Services.ContainsKey($key)) { return $null }
    $spec = $script:W5Services[$key]
    return [pscustomobject]@{ Name = $key; Status = [string]$spec.Status; StartType = [string]$spec.StartType }
}
function Get-BRAVOWmiInstance { param($ClassName) return @() }
function Read-BRAVOServiceQuiescenceState { return $null }
function Get-BRAVOScheduledTaskState {
    param([string]$TaskPath, [string]$TaskName)
    $script:W5TaskQueries += @("$TaskPath|$TaskName")
    return $script:W5TaskState
}
function Start-ScheduledTask {
    param($InputObject, $TaskName, $TaskPath, $ErrorAction)
    $script:W5ScheduledStarts++
}
function Start-Service {
    param($Name, $InputObject, $ErrorAction)
    $script:W5ServiceStarts++
}
function Invoke-W5Health {
    param([hashtable]$Services, $TaskState, [bool]$RecoveryEnabled = $true, [bool]$RunThrows = $false)
    $script:W5Services = $Services
    $script:W5HealthLog = @()
    $script:W5TaskQueries = @()
    $script:W5TaskRuns = 0
    $script:W5ScheduledStarts = 0
    $script:W5ServiceStarts = 0
    $script:W5RunThrows = $RunThrows
    if ($null -ne $TaskState -and $null -ne $TaskState.Task -and [string]$TaskState.Provider -eq 'COM') {
        Add-Member -InputObject $TaskState.Task -MemberType ScriptMethod -Name Run -Value {
            param($Parameters)
            if ($script:W5RunThrows) { throw 'self-test: доступ заборонено' }
            $script:W5TaskRuns++
        } -Force
    }
    $script:W5TaskState = $TaskState
    $script:backupMonitoring = @{ CheckManagedServices = $true }
    $script:maintenanceSettings = [pscustomobject]@{
        Services = [pscustomobject]@{ BravoName = 'BRAVO'; ExchangeApiName = 'exchangAPI'; BravoWebEnabled = $false; BravoWebCandidates = @() }
    }
    $script:schedulerSettings = @{
        TaskPath = '\BRAVO\'
        ServiceRecovery = @{ Enabled = $RecoveryEnabled; TaskName = 'BRAVO_SERVICE_RECOVERY' }
    }
    $issues = @()
    $thrown = $null
    try { $issues = @(Get-ManagedServiceHealthIssues) } catch { $thrown = $_.Exception.Message }
    return [pscustomobject]@{
        Thrown = $thrown
        Issues = @($issues)
        Queries = @($script:W5TaskQueries)
        Runs = $script:W5TaskRuns
        ScheduledStarts = $script:W5ScheduledStarts
        ServiceStarts = $script:W5ServiceStarts
        Log = @($script:W5HealthLog)
    }
}
'@
    $w5HealthModule = & $w5NewModule ($w5HealthStubs + "`n" + $w5HealthText + "`n" + $w5SystemText) @(
        'Write-HealthLog', 'Get-Service', 'Get-BRAVOWmiInstance', 'Read-BRAVOServiceQuiescenceState', 'Get-BRAVOScheduledTaskState',
        'Start-ScheduledTask', 'Start-Service', 'Invoke-W5Health', 'Test-BRAVOSettingEnabled',
        'Get-ManagedServiceHealthIssues', 'Start-BRAVOHealthServiceRecoveryTask', 'Get-AlertFingerprint', 'Get-BRAVOHealthIssueField',
        'Get-BRAVOHealthIssueActionText', 'Get-BRAVOWin32ServiceInfo', 'Test-BRAVOServiceDisabledByOperator', 'Get-BRAVOServiceStartMode',
        'Get-BRAVOManagedServiceCondition')
    $w5RunHealth = {
        param([hashtable]$Arguments)
        & $w5HealthModule {
            param($HealthArguments)
            Set-StrictMode -Version 2.0
            Invoke-W5Health @HealthArguments
        } $Arguments
    }
    $w5ReadyTask = { param([string]$Provider = 'COM') [pscustomobject]@{ Exists = $true; State = 'Ready'; IsRunning = $false; Provider = $Provider; Task = [pscustomobject]@{ Name = 'BRAVO_SERVICE_RECOVERY' } } }
    $w5BothStopped = @{ BRAVO = @{ Status = 'Stopped'; StartType = 'Automatic' }; exchangAPI = @{ Status = 'Stopped'; StartType = 'Manual' } }
    $w5HealthDescribe = {
        param($Result)
        "помилка='$($Result.Thrown)' issues=[$(@($Result.Issues | ForEach-Object { '{0}/{1}/{2}' -f $_.Component, $_.Reason, $(if ($null -ne $_.PSObject.Properties['ActionText']) { $_.ActionText } else { '-' }) }) -join ' || ')] " +
            "запити=[$(@($Result.Queries) -join ', ')] run=$($Result.Runs) start-scheduledtask=$($Result.ScheduledStarts) start-service=$($Result.ServiceStarts)"
    }
    $w5ActionOf = {
        param($Issue)
        if ($null -eq $Issue -or $null -eq $Issue.PSObject.Properties['ActionText']) { return '' }
        return [string]$Issue.ActionText
    }

    $w5Started = & $w5RunHealth @{ Services = $w5BothStopped; TaskState = (& $w5ReadyTask) }
    $w5StartedModern = & $w5RunHealth @{ Services = @{ BRAVO = @{ Status = 'Stopped'; StartType = 'Automatic' } }; TaskState = (& $w5ReadyTask 'ScheduledTasks') }
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w5Started.Thrown -and @($w5Started.Issues).Count -eq 2 -and
            @($w5Started.Issues | Where-Object { [string]$_.Reason -ceq 'не запущена (стан: Stopped)' -and (& $w5ActionOf $_) -match 'запущено автоматичне відновлення' -and (& $w5ActionOf $_) -match 'RECOVER' }).Count -eq 2 -and
            (@($w5Started.Queries) -join ',') -ceq '\BRAVO\|BRAVO_SERVICE_RECOVERY' -and
            [int]$w5Started.Runs -eq 1 -and [int]$w5Started.ServiceStarts -eq 0 -and
            $null -eq $w5StartedModern.Thrown -and [int]$w5StartedModern.ScheduledStarts -eq 1 -and [int]$w5StartedModern.ServiceStarts -eq 0
        ) `
        -Name 'ServiceRecovery/HealthFailedStartsRecoveryTaskNotService' `
        -Failure ("Health: дві впалі (Failed+Stopped) служби — один запуск задачі BRAVO_SERVICE_RECOVERY (COM Task.Run або Start-ScheduledTask), Start-Service не викликається, issue з тим самим Reason і ActionText «запущено автоматичне відновлення ... RECOVER». " +
            "COM: $(& $w5HealthDescribe $w5Started) || ScheduledTasks: $(& $w5HealthDescribe $w5StartedModern)")

    $w5Missing = & $w5RunHealth @{
        Services = @{ BRAVO = @{ Status = 'Stopped'; StartType = 'Automatic' } }
        TaskState = [pscustomobject]@{ Exists = $false; State = 'NotFound'; IsRunning = $false; Provider = 'COM'; Task = $null }
    }
    $w5DisabledTask = & $w5RunHealth @{
        Services = @{ BRAVO = @{ Status = 'Stopped'; StartType = 'Automatic' } }
        TaskState = [pscustomobject]@{ Exists = $true; State = 'Disabled'; IsRunning = $false; Provider = 'COM'; Task = [pscustomobject]@{ Name = 'BRAVO_SERVICE_RECOVERY' } }
    }
    $w5TaskIssueOf = {
        param($Result)
        @($Result.Issues | Where-Object { [string]$_.Component -ceq 'Задача відновлення служб' }) | Select-Object -First 1
    }
    $w5MissingIssue = & $w5TaskIssueOf $w5Missing
    $w5DisabledIssue = & $w5TaskIssueOf $w5DisabledTask
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w5Missing.Thrown -and @($w5Missing.Issues).Count -eq 2 -and $null -ne $w5MissingIssue -and
            [string]$w5MissingIssue.Kind -ceq 'Service' -and [string]$w5MissingIssue.Location -ceq 'BRAVO_SERVICE_RECOVERY' -and
            [string]$w5MissingIssue.Reason -match 'відсутня або вимкнена' -and (& $w5ActionOf $w5MissingIssue) -match 'BRAVO_TASKS_INSTALL\.ps1' -and
            $null -eq $w5DisabledTask.Thrown -and @($w5DisabledTask.Issues).Count -eq 2 -and $null -ne $w5DisabledIssue -and
            [int]$w5DisabledTask.Runs -eq 0 -and [int]$w5Missing.ServiceStarts -eq 0 -and [int]$w5DisabledTask.ServiceStarts -eq 0
        ) `
        -Name 'ServiceRecovery/HealthMissingRecoveryTaskYieldsIssue' `
        -Failure ("Health: задача BRAVO_SERVICE_RECOVERY відсутня або вимкнена при впалій службі — окремий issue «Задача відновлення служб» (Location BRAVO_SERVICE_RECOVERY, дія BRAVO_TASKS_INSTALL.ps1), задача не запускається, служба теж. " +
            "відсутня: $(& $w5HealthDescribe $w5Missing) || вимкнена: $(& $w5HealthDescribe $w5DisabledTask)")

    $w5AlreadyRunning = & $w5RunHealth @{
        Services = $w5BothStopped
        TaskState = [pscustomobject]@{ Exists = $true; State = 'Running'; IsRunning = $true; Provider = 'COM'; Task = [pscustomobject]@{ Name = 'BRAVO_SERVICE_RECOVERY' } }
    }
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w5AlreadyRunning.Thrown -and @($w5AlreadyRunning.Issues).Count -eq 2 -and
            @($w5AlreadyRunning.Queries).Count -eq 1 -and [int]$w5AlreadyRunning.Runs -eq 0 -and [int]$w5AlreadyRunning.ServiceStarts -eq 0 -and
            @($w5AlreadyRunning.Issues | Where-Object { (& $w5ActionOf $_) -match 'вже виконується' }).Count -eq 2
        ) `
        -Name 'ServiceRecovery/HealthRunningTaskNotStartedTwice' `
        -Failure "Health: задача відновлення вже виконується — не запускати вдруге (один запит стану на прогін), ActionText «автоматичне відновлення вже виконується»: $(& $w5HealthDescribe $w5AlreadyRunning)"

    $w5DisabledService = & $w5RunHealth @{
        Services = @{ BRAVO = @{ Status = 'Stopped'; StartType = 'Disabled' }; exchangAPI = @{ Status = 'Running'; StartType = 'Automatic' } }
        TaskState = (& $w5ReadyTask)
    }
    $w5PausedService = & $w5RunHealth @{ Services = @{ BRAVO = @{ Status = 'Paused'; StartType = 'Automatic' } }; TaskState = (& $w5ReadyTask) }
    $w5RecoveryOff = & $w5RunHealth @{ Services = @{ BRAVO = @{ Status = 'Stopped'; StartType = 'Automatic' } }; TaskState = (& $w5ReadyTask); RecoveryEnabled = $false }
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w5DisabledService.Thrown -and @($w5DisabledService.Issues).Count -eq 0 -and @($w5DisabledService.Queries).Count -eq 0 -and
            $null -eq $w5PausedService.Thrown -and @($w5PausedService.Issues).Count -eq 1 -and @($w5PausedService.Queries).Count -eq 0 -and
            (& $w5ActionOf @($w5PausedService.Issues)[0]) -eq '' -and
            $null -eq $w5RecoveryOff.Thrown -and @($w5RecoveryOff.Issues).Count -eq 1 -and @($w5RecoveryOff.Queries).Count -eq 0 -and
            (& $w5ActionOf @($w5RecoveryOff.Issues)[0]) -eq '' -and
            [int]$w5DisabledService.ServiceStarts + [int]$w5PausedService.ServiceStarts + [int]$w5RecoveryOff.ServiceStarts -eq 0
        ) `
        -Name 'ServiceRecovery/HealthDisabledServiceStillNoIssue' `
        -Failure ("Health: Disabled від оператора — без issue і без задачі; призупинена служба (Paused) — issue як і раніше, задача не запускається (§0.3); задачу вимкнено в конфігурації (Maintenance вимкнений) — issue без запуску задачі. " +
            "Disabled: $(& $w5HealthDescribe $w5DisabledService) || Paused: $(& $w5HealthDescribe $w5PausedService) || вимкнено: $(& $w5HealthDescribe $w5RecoveryOff)")

    $w5RunFails = & $w5RunHealth @{ Services = @{ BRAVO = @{ Status = 'Stopped'; StartType = 'Automatic' } }; TaskState = (& $w5ReadyTask); RunThrows = $true }
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w5RunFails.Thrown -and @($w5RunFails.Issues).Count -eq 1 -and [int]$w5RunFails.ServiceStarts -eq 0 -and
            (& $w5ActionOf @($w5RunFails.Issues)[0]) -match 'не вдалося запустити задачу BRAVO_SERVICE_RECOVERY' -and
            (& $w5ActionOf @($w5RunFails.Issues)[0]) -match 'доступ заборонено' -and
            (& $w5ActionOf @($w5RunFails.Issues)[0]) -match 'BRAVO_MAINTENANCE\.ps1 -RecoverServices'
        ) `
        -Name 'ServiceRecovery/HealthRecoveryTaskStartFailureFallsBackToManual' `
        -Failure "Health: запуск задачі відновлення завершився помилкою — Health не падає, служба не запускається напряму, ActionText з причиною і ручним запуском BRAVO_MAINTENANCE.ps1 -RecoverServices: $(& $w5HealthDescribe $w5RunFails)"

    # Fingerprint алерту не залежить від ActionText: issue з дією відновлення
    # дає той самий fingerprint, що й issue у форматі до хвилі 5.
    $w5FingerprintError = $null
    $w5Fingerprints = [pscustomobject]@{ New = ''; Legacy = ''; Action = '' }
    try {
        $w5Fingerprints = & $w5HealthModule {
            param($Issue)
            Set-StrictMode -Version 2.0
            $legacy = [pscustomobject]@{
                Kind = 'Service'; Component = [string]$Issue.Component; Reason = [string]$Issue.Reason; FileName = ''
                LastWriteTime = $null; Location = [string]$Issue.Location; SizeBytes = $null; Details = @()
            }
            [pscustomobject]@{
                New = Get-AlertFingerprint -Issues @($Issue)
                Legacy = Get-AlertFingerprint -Issues @($legacy)
                Action = Get-BRAVOHealthIssueActionText -Issues @($Issue)
            }
        } (@($w5Started.Issues) | Select-Object -First 1)
    } catch {
        $w5FingerprintError = $_.Exception.Message
    }
    Test-BRAVOCondition `
        -Condition (
            $null -eq $w5FingerprintError -and $null -ne $w5Fingerprints -and
            -not [string]::IsNullOrWhiteSpace([string]$w5Fingerprints.New) -and
            [string]$w5Fingerprints.New -ceq [string]$w5Fingerprints.Legacy -and
            [string]$w5Fingerprints.Action -match 'запущено автоматичне відновлення'
        ) `
        -Name 'ServiceRecovery/HealthRecoveryActionKeepsAlertFingerprint' `
        -Failure "Health: issue впалої служби з ActionText відновлення має той самий fingerprint, що й issue до хвилі 5 (ActionText не входить у fingerprint), а дія алерту — текст про автоматичне відновлення: помилка='$w5FingerprintError' new='$($w5Fingerprints.New)' legacy='$($w5Fingerprints.Legacy)' дія='$($w5Fingerprints.Action)'"
}
