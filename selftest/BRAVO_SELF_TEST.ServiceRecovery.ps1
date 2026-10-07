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
        'New-BRAVOServiceRecoveryNotificationText'
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
        -Failure ("modules\BRAVO.ServiceRecovery має містити .psm1 і .psd1 (PowerShellVersion 3.0), що експортує рівно публічний API хвилі 3; " +
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
