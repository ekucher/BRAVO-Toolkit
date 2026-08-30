# Домен-фрагмент self-test: BRAVO_DATA_RESTORE (BRAVO.DataRestore). Dot-sourced
# з кореневого BRAVO_SELF_TEST.ps1 -- НЕ запускається напряму. Успадковує з
# викликача: $root, Test-BRAVOCondition, New-BRAVOSelfTestRuntimeModule,
# $script:failures. Витягнуто без зміни жодного тестового виразу чи -Name
# (behavior-preserving розбиття, Фаза 1 продовження: characterization
# baseline 93 тести DataRestore/*, рядки 7979-11279 оригінального файлу на
# момент витягнення).

    # ============================================================
    # BRAVO_DATA_RESTORE (rc.2): поведінкові тести чистих функцій
    # відновлення даних. Функції витягуються з runtime за AST в
    # ізольований модуль; залежності від журналу/форматування
    # підмінюються стабами в тому ж SourceText, щоб тест не залежав
    # ані від ініціалізованого журналу, ані від імпорту BRAVO.Console.
    # ============================================================
    $dataRestoreRuntimeTextForTests = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.DataRestore\BRAVO.DataRestore.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $dataRestoreTestStubs = @'
function Write-DataRestoreLog {
    param([AllowEmptyString()][string]$Message, [string]$Level = 'INFO', [switch]$Console)
}
function Format-BRAVOFileSize {
    param([long]$Bytes)
    return ("{0} B" -f $Bytes)
}
# Стан для round-5 симуляції служб (fifth restore safety review): реальні
# Get-Service/Stop-Service/Start-Service НІКОЛИ не викликаються цим
# самотестом — ці стаб-функції затінюють однойменні cmdlet-и лише
# всередині ізольованого $dataRestoreModule. New-BRAVOSelfTestRuntimeModule
# екстрагує ЛИШЕ визначення функцій (FunctionDefinitionAst) — верхньорівневі
# `$script:X = @{}` НЕ потрапили б у модуль, тому кожна стаб-функція сама
# лінькво ініціалізує обидва словники при першому виклику.
function Initialize-BRAVOSelfTestServiceState {
    if ($null -eq $script:BRAVOSelfTestServiceStates) { $script:BRAVOSelfTestServiceStates = @{} }
    if ($null -eq $script:BRAVOSelfTestServiceStuck) { $script:BRAVOSelfTestServiceStuck = @{} }
    if ($null -eq $script:BRAVOSelfTestServiceQueryThrows) { $script:BRAVOSelfTestServiceQueryThrows = @{} }
}
function Set-BRAVOSelfTestServiceState {
    param([string]$Name, [string]$Status)
    Initialize-BRAVOSelfTestServiceState
    $script:BRAVOSelfTestServiceStates[$Name] = $Status
}
function Set-BRAVOSelfTestServiceStuck {
    param([string]$Name, [bool]$Stuck)
    Initialize-BRAVOSelfTestServiceState
    $script:BRAVOSelfTestServiceStuck[$Name] = $Stuck
}
function Set-BRAVOSelfTestServiceQueryThrows {
    param([string]$Name, [bool]$Throws)
    Initialize-BRAVOSelfTestServiceState
    $script:BRAVOSelfTestServiceQueryThrows[$Name] = $Throws
}
function Get-Service {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name)
    Initialize-BRAVOSelfTestServiceState
    # round-7 P1: симуляція транзієнтної помилки SCM-запиту — окремо від
    # "null" (сервіс невідомий), щоб тест міг перевірити both null AND
    # throw незалежно.
    if ($script:BRAVOSelfTestServiceQueryThrows.ContainsKey($Name) -and $script:BRAVOSelfTestServiceQueryThrows[$Name]) {
        throw "симульована транзієнтна помилка SCM для $Name"
    }
    if (-not $script:BRAVOSelfTestServiceStates.ContainsKey($Name)) { return $null }
    # Status уже свіжий на момент створення об'єкта (читання з
    # $script:BRAVOSelfTestServiceStates щойно вище) — Refresh() тут
    # безпечний no-op, а не closure над module-scope зі свого боку.
    $serviceObject = [pscustomobject]@{ Name = $Name; Status = $script:BRAVOSelfTestServiceStates[$Name] }
    Add-Member -InputObject $serviceObject -MemberType ScriptMethod -Name Refresh -Value { }
    return $serviceObject
}
function Stop-Service {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name, [switch]$Force)
    Initialize-BRAVOSelfTestServiceState
    if (-not ($script:BRAVOSelfTestServiceStuck.ContainsKey($Name) -and $script:BRAVOSelfTestServiceStuck[$Name])) {
        $script:BRAVOSelfTestServiceStates[$Name] = 'Stopped'
    }
}
function Start-Service {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name)
    Initialize-BRAVOSelfTestServiceState
    $script:BRAVOSelfTestServiceStates[$Name] = 'Running'
}
# Стан для round-6 симуляції KillProcesses (fifth/sixth review): реальні
# Get-Process/Stop-Process НІКОЛИ не викликаються цим самотестом — ті самі
# стаб-функції затінюють однойменні cmdlet-и лише всередині ізольованого
# $dataRestoreModule, ніякий реальний процес не завершується.
function Initialize-BRAVOSelfTestProcessState {
    if ($null -eq $script:BRAVOSelfTestRunningProcessNames) { $script:BRAVOSelfTestRunningProcessNames = @{} }
    if ($null -eq $script:BRAVOSelfTestUnkillableProcessNames) { $script:BRAVOSelfTestUnkillableProcessNames = @{} }
}
function Set-BRAVOSelfTestProcessRunning {
    param([string]$Name, [bool]$Running)
    Initialize-BRAVOSelfTestProcessState
    $script:BRAVOSelfTestRunningProcessNames[$Name] = $Running
}
function Set-BRAVOSelfTestProcessUnkillable {
    param([string]$Name, [bool]$Unkillable)
    Initialize-BRAVOSelfTestProcessState
    $script:BRAVOSelfTestUnkillableProcessNames[$Name] = $Unkillable
}
function Get-Process {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name)
    Initialize-BRAVOSelfTestProcessState
    if ($script:BRAVOSelfTestRunningProcessNames.ContainsKey($Name) -and $script:BRAVOSelfTestRunningProcessNames[$Name]) {
        return [pscustomobject]@{ Name = $Name; Id = 999999 }
    }
    return $null
}
function Stop-Process {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)][object]$InputObject,
        [switch]$Force
    )
    process {
        Initialize-BRAVOSelfTestProcessState
        if ($null -eq $InputObject) { return }
        $procName = [string]$InputObject.Name
        if (-not ($script:BRAVOSelfTestUnkillableProcessNames.ContainsKey($procName) -and $script:BRAVOSelfTestUnkillableProcessNames[$procName])) {
            $script:BRAVOSelfTestRunningProcessNames[$procName] = $false
        }
    }
}
'@
    $dataRestoreModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($dataRestoreRuntimeTextForTests + [Environment]::NewLine + $dataRestoreTestStubs) `
        -FunctionNames @(
            'Write-DataRestoreLog',
            'Format-BRAVOFileSize',
            'Initialize-BRAVOSelfTestServiceState',
            'Set-BRAVOSelfTestServiceState',
            'Set-BRAVOSelfTestServiceStuck',
            'Set-BRAVOSelfTestServiceQueryThrows',
            'Get-Service',
            'Stop-Service',
            'Start-Service',
            'Initialize-BRAVOSelfTestProcessState',
            'Set-BRAVOSelfTestProcessRunning',
            'Set-BRAVOSelfTestProcessUnkillable',
            'Get-Process',
            'Stop-Process',
            'Test-BRAVODataRestorePathWithin',
            'Test-BRAVODataRestorePathEquals',
            'Test-BRAVODataRestorePathHasReparseAncestor',
            'Test-BRAVODataRestoreGenerationIdFormat',
            'Test-BRAVODataRestoreMinimumFreeSpaceGB',
            'Test-BRAVODataRestoreFullyQualifiedWindowsPath',
            'ConvertTo-BRAVODataRestoreElevationArgument',
            'Get-BRAVODataRestoreComponentSelection',
            'Get-BRAVODataRestoreLiveSourceMap',
            'Test-BRAVODataRestoreStagingSafe',
            'Get-BRAVODataRestorePlan',
            'Get-BRAVODataRestoreGenerationCandidates',
            'Test-BRAVODataRestoreFreeSpace',
            'Test-BRAVODataRestoreServicesAllStopped',
            'Stop-BRAVODataRestoreServices',
            'Restore-BRAVODataRestoreServices',
            'Invoke-BRAVODataRestoreQuiescence',
            'Invoke-BRAVODataRestoreServiceStateChange',
            'Test-BRAVODataRestoreExtractionResult',
            'Get-BRAVODataRestoreLockingProcessText',
            'Invoke-BRAVODataRestoreMoveAside',
            'Undo-BRAVODataRestoreMoveAside',
            'Undo-BRAVODataRestoreCompletedComponents',
            'Get-BRAVODataRestoreRollbackStatusUpdates',
            'Format-BRAVODataRestoreRollbackFailureText',
            'Invoke-BRAVODataRestoreTestFailPoint',
            'Test-BRAVODataRestoreWinSCPListingSucceeded',
            'Test-BRAVODataRestoreArchiveSize',
            'Get-BRAVODataRestoreGenerationIdSortKey',
            'Sort-BRAVODataRestoreManifestNamesByGenerationDescending',
            'New-BRAVODataRestoreWinSCPNamespaceManager'
        ) `
        -PreferLastDefinitionOnDuplicate

    # --- 1. Path guards: некоректний шлях трактується як заборонений ---
    $pathWithinTrue = & $dataRestoreModule {
        Test-BRAVODataRestorePathWithin -Path 'C:\DATA\MODEL\sub' -Directory 'C:\DATA\MODEL'
    }
    $pathWithinFalse = & $dataRestoreModule {
        Test-BRAVODataRestorePathWithin -Path 'C:\DATA\MODEL2' -Directory 'C:\DATA\MODEL'
    }
    $pathWithinSelf = & $dataRestoreModule {
        Test-BRAVODataRestorePathWithin -Path 'C:\DATA\MODEL' -Directory 'C:\DATA\MODEL'
    }
    $pathEqualsTrue = & $dataRestoreModule {
        Test-BRAVODataRestorePathEquals -First 'C:\DATA\model\' -Second 'C:\data\MODEL'
    }
    $pathEqualsInvalid = & $dataRestoreModule {
        Test-BRAVODataRestorePathEquals -First "C:\DATA\`0bad" -Second 'C:\DATA\MODEL'
    }
    Test-BRAVOCondition `
        -Condition (
            $pathWithinTrue -eq $true -and
            $pathWithinFalse -eq $false -and
            $pathWithinSelf -eq $false -and
            $pathEqualsTrue -eq $true -and
            $pathEqualsInvalid -eq $true
        ) `
        -Name "DataRestore/PathGuardsFailClosed" `
        -Failure "Test-BRAVODataRestorePathWithin/PathEquals: 'MODEL2' не всередині 'MODEL', сам каталог не є 'строго всередині', порівняння регістронечутливе, а некоректний шлях має трактуватися як заборонений (true), а не дозволений"

    # --- 2. Вибір компонентів: вимкнений явно запитаний -> відмова ---
    $selectionManifest = ConvertFrom-Json '{"components":{"MODEL":{"Enabled":true},"BLOG":{"Enabled":false},"BRAVOEXCH":{"Enabled":true}}}'
    $selectionAll = & $dataRestoreModule {
        param($m)
        Get-BRAVODataRestoreComponentSelection -Manifest $m -RequestedComponent 'All'
    } $selectionManifest
    $selectionDisabledRejected = $false
    try {
        [void](& $dataRestoreModule {
            param($m)
            Get-BRAVODataRestoreComponentSelection -Manifest $m -RequestedComponent 'BLOG'
        } $selectionManifest)
    } catch {
        $selectionDisabledRejected = $true
    }
    Test-BRAVOCondition `
        -Condition (
            (@($selectionAll) -join ',') -eq 'MODEL,BRAVOEXCH' -and
            $selectionDisabledRejected
        ) `
        -Name "DataRestore/ComponentSelectionRejectsDisabled" `
        -Failure "Get-BRAVODataRestoreComponentSelection має повертати лише увімкнені компоненти в канонічному порядку, а явно запитаний вимкнений компонент — відхиляти помилкою, а не мовчазним пропуском"

    # --- 3. План цілей: захищені розташування і непорожня ціль ---
    $planTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_PLAN_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        $planBackupRoot = Join-Path $planTestRoot 'BACKUP'
        $planRuntimeRoot = Join-Path $planTestRoot 'RUNTIME'
        $planStagingRoot = Join-Path $planBackupRoot 'RESTORE_STAGING'
        $planLiveRoot = Join-Path $planTestRoot 'LIVE'
        $planLiveModel = Join-Path $planLiveRoot 'MODEL'
        $planTarget = Join-Path $planTestRoot 'TARGET'
        foreach ($planDirectory in @($planBackupRoot, $planRuntimeRoot, $planStagingRoot, $planLiveModel, $planTarget)) {
            [void][IO.Directory]::CreateDirectory($planDirectory)
        }
        $planDefinitions = @([pscustomobject]@{ Type = 'MODEL'; Source = (Join-Path $planLiveModel 'model.gdb') })

        $planInvoke = {
            param($Module, $Mode, $TargetPath, $BackupRoot, $RuntimeRoot, $StagingRoot, $Definitions)
            & $Module {
                param($m, $t, $b, $r, $s, $d)
                Get-BRAVODataRestorePlan `
                    -ComponentTypes @('MODEL') `
                    -RestoreMode $m `
                    -RequestedTargetPath $t `
                    -BackupRoot $b `
                    -RuntimeRootPath $r `
                    -StagingRoot $s `
                    -ArchiveDefinitions $d `
                    -RunStamp '20260814_120000'
            } $Mode $TargetPath $BackupRoot $RuntimeRoot $StagingRoot $Definitions
        }

        $planOk = & $planInvoke $dataRestoreModule 'OutOfPlace' $planTarget $planBackupRoot $planRuntimeRoot $planStagingRoot $planDefinitions
        $planIntoBackupRoot = & $planInvoke $dataRestoreModule 'OutOfPlace' (Join-Path $planBackupRoot 'OUT') $planBackupRoot $planRuntimeRoot $planStagingRoot $planDefinitions
        $planAroundBackupRoot = & $planInvoke $dataRestoreModule 'OutOfPlace' $planTestRoot $planBackupRoot $planRuntimeRoot $planStagingRoot $planDefinitions
        $planIntoLiveSource = & $planInvoke $dataRestoreModule 'OutOfPlace' (Join-Path $planLiveModel 'OUT') $planBackupRoot $planRuntimeRoot $planStagingRoot $planDefinitions
        $planRelative = & $planInvoke $dataRestoreModule 'OutOfPlace' 'RELATIVE\PATH' $planBackupRoot $planRuntimeRoot $planStagingRoot $planDefinitions
        $planInPlaceWithTarget = & $planInvoke $dataRestoreModule 'InPlace' $planTarget $planBackupRoot $planRuntimeRoot $planStagingRoot $planDefinitions
        $planInPlaceOk = & $planInvoke $dataRestoreModule 'InPlace' '' $planBackupRoot $planRuntimeRoot $planStagingRoot $planDefinitions
        $planInPlaceNoSource = & $planInvoke $dataRestoreModule 'InPlace' '' $planBackupRoot $planRuntimeRoot $planStagingRoot @([pscustomobject]@{ Type = 'MODEL'; Source = '' })

        # Непорожня ціль компонента: нічого не перезаписуємо.
        [void][IO.Directory]::CreateDirectory((Join-Path $planTarget 'MODEL'))
        [IO.File]::WriteAllText((Join-Path (Join-Path $planTarget 'MODEL') 'existing.txt'), 'x')
        $planNonEmptyTarget = & $planInvoke $dataRestoreModule 'OutOfPlace' $planTarget $planBackupRoot $planRuntimeRoot $planStagingRoot $planDefinitions

        Test-BRAVOCondition `
            -Condition (
                $planOk.Success -and
                ([string]$planOk.Components[0].TargetDirectory) -eq (Join-Path $planTarget 'MODEL') -and
                -not $planIntoBackupRoot.Success -and
                -not $planAroundBackupRoot.Success -and
                -not $planIntoLiveSource.Success -and
                -not $planRelative.Success -and
                -not $planNonEmptyTarget.Success
            ) `
            -Name "DataRestore/PlanRejectsUnsafeOutOfPlaceTargets" `
            -Failure "Get-BRAVODataRestorePlan має відхиляти -TargetPath, що перетинається із захищеним розташуванням у БУДЬ-ЯКУ сторону вкладеності (BackupRoot/RuntimeRoot/staging/live-джерело), відносний шлях і непорожню ціль компонента"

        # Fourth restore safety review (PR #40): наперед існуюча, але
        # ПОРОЖНЯ ціль компонента теж має відхилятись (не лише непорожня) —
        # інакше runtime не міг би достовірно відрізнити "каталог створив
        # я" від "operator-owned каталог" у тому самому місці, звідки
        # cleanup при відмові пізніше безумовно видаляв би target.
        $planEmptyTargetRoot = Join-Path $planTestRoot 'TARGET_EMPTY'
        [void][IO.Directory]::CreateDirectory($planEmptyTargetRoot)
        [void][IO.Directory]::CreateDirectory((Join-Path $planEmptyTargetRoot 'MODEL'))
        $planPreExistingEmptyTarget = & $planInvoke $dataRestoreModule 'OutOfPlace' $planEmptyTargetRoot $planBackupRoot $planRuntimeRoot $planStagingRoot $planDefinitions
        Test-BRAVOCondition `
            -Condition (-not $planPreExistingEmptyTarget.Success) `
            -Name "DataRestore/PlanRejectsPreExistingEmptyOutOfPlaceComponentTarget" `
            -Failure "Get-BRAVODataRestorePlan (OutOfPlace) має відхиляти наперед існуючу ціль компонента, НАВІТЬ ПОРОЖНЮ — target МУСИТЬ бути відсутнім, щоб runtime міг створити й гарантовано володіти ним (і безпечно видалити лише його при відмові, не чіпаючи operator-owned каталог)"

        Test-BRAVOCondition `
            -Condition (
                -not $planInPlaceWithTarget.Success -and
                -not $planInPlaceNoSource.Success -and
                $planInPlaceOk.Success -and
                ([string]$planInPlaceOk.Components[0].TargetDirectory) -eq $planLiveModel -and
                ([string]$planInPlaceOk.Components[0].PrerestoreDirectory) -eq ("$planLiveModel.prerestore_20260814_120000")
            ) `
            -Name "DataRestore/PlanInPlaceUsesDiscoveryAndPrerestoreName" `
            -Failure "InPlace-план має забороняти -TargetPath, відхиляти невизначене live-джерело і давати ціль discovery разом із prerestore-іменем <live>.prerestore_<stamp>"
    } finally {
        if (Test-Path -LiteralPath $planTestRoot) {
            Remove-Item -LiteralPath $planTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 4. Free-space preflight: агрегація по томах + UNC-нотатка ---
    $freeSpaceTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_SPACE_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        [void][IO.Directory]::CreateDirectory($freeSpaceTestRoot)
        $freeSpaceOk = & $dataRestoreModule {
            param($dir)
            Test-BRAVODataRestoreFreeSpace `
                -Requirements @([pscustomobject]@{ TargetDirectory = $dir; RequiredBytes = [long]1024 }) `
                -MinimumFreeGigabytes 0.001
        } $freeSpaceTestRoot
        $freeSpaceImpossible = & $dataRestoreModule {
            param($dir)
            Test-BRAVODataRestoreFreeSpace `
                -Requirements @([pscustomobject]@{ TargetDirectory = $dir; RequiredBytes = [long]900000000000000 }) `
                -MinimumFreeGigabytes 1
        } $freeSpaceTestRoot
        $freeSpaceUnc = & $dataRestoreModule {
            Test-BRAVODataRestoreFreeSpace `
                -Requirements @([pscustomobject]@{ TargetDirectory = '\\\\nas-host\\share\\restore'; RequiredBytes = [long]1024 }) `
                -MinimumFreeGigabytes 1
        }
        Test-BRAVOCondition `
            -Condition (
                $freeSpaceOk.Success -and
                -not $freeSpaceImpossible.Success -and
                @($freeSpaceUnc.Notes).Count -gt 0
            ) `
            -Name "DataRestore/FreeSpacePreflightBlocksAndProbes" `
            -Failure "Test-BRAVODataRestoreFreeSpace має пропускати реалістичну вимогу, блокувати завідомо неможливу (з урахуванням резерву MinimumFreeSpaceGB) і для UNC-цілі лишати нотатку замість перевірки обсягу"
    } finally {
        if (Test-Path -LiteralPath $freeSpaceTestRoot) {
            Remove-Item -LiteralPath $freeSpaceTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 5. Post-verify: розбіжність із інвентаризацією архіву ---
    $verifyTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_VERIFY_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        [void][IO.Directory]::CreateDirectory($verifyTestRoot)
        [IO.File]::WriteAllBytes((Join-Path $verifyTestRoot 'a.bin'), (New-Object byte[] 10))
        [IO.File]::WriteAllBytes((Join-Path $verifyTestRoot 'b.bin'), (New-Object byte[] 20))
        $verifyMatch = & $dataRestoreModule {
            param($dir)
            Test-BRAVODataRestoreExtractionResult `
                -TargetDirectory $dir `
                -Inventory ([pscustomobject]@{ FileCount = 2; TotalUncompressedBytes = [long]30 })
        } $verifyTestRoot
        $verifyCountMismatch = & $dataRestoreModule {
            param($dir)
            Test-BRAVODataRestoreExtractionResult `
                -TargetDirectory $dir `
                -Inventory ([pscustomobject]@{ FileCount = 3; TotalUncompressedBytes = [long]30 })
        } $verifyTestRoot
        $verifySizeMismatch = & $dataRestoreModule {
            param($dir)
            Test-BRAVODataRestoreExtractionResult `
                -TargetDirectory $dir `
                -Inventory ([pscustomobject]@{ FileCount = 2; TotalUncompressedBytes = [long]31 })
        } $verifyTestRoot
        Test-BRAVOCondition `
            -Condition (
                $verifyMatch.Success -and
                -not $verifyCountMismatch.Success -and
                -not $verifySizeMismatch.Success
            ) `
            -Name "DataRestore/PostVerifyDetectsIncompleteExtraction" `
            -Failure "Test-BRAVODataRestoreExtractionResult має вимагати ТОЧНОГО збігу кількості файлів і сумарного розміру з інвентаризацією архіву"
    } finally {
        if (Test-Path -LiteralPath $verifyTestRoot) {
            Remove-Item -LiteralPath $verifyTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 6. P1-a: крос-компонентний rollback InPlace ---
    # Збій одного компонента не має лишати production зі змішаними
    # generation: вже відновлені компоненти цього прогону повертаються
    # назад, у зворотному порядку, і відмова одного з них не зупиняє
    # відкат решти.
    $crossRollbackRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_ROLLBACK_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    $lockedStream = $null
    try {
        [void][IO.Directory]::CreateDirectory($crossRollbackRoot)

        # A: класичний випадок — live замінено, prerestore зберігає старі дані.
        $liveA = Join-Path $crossRollbackRoot 'MODEL'
        $prerestoreA = Join-Path $crossRollbackRoot 'MODEL.prerestore_20260814_120000'
        [void][IO.Directory]::CreateDirectory($liveA)
        [void][IO.Directory]::CreateDirectory($prerestoreA)
        [IO.File]::WriteAllText((Join-Path $liveA 'restored.txt'), 'new')
        [IO.File]::WriteAllText((Join-Path $prerestoreA 'original.txt'), 'old')

        # B: live-каталогу до відновлення не було (MoveAsidePerformed=$false) —
        # відкат означає просто прибрати щойно створений каталог.
        $liveB = Join-Path $crossRollbackRoot 'BLOG'
        [void][IO.Directory]::CreateDirectory($liveB)
        [IO.File]::WriteAllText((Join-Path $liveB 'restored.txt'), 'new')

        $crossRollbackResult = & $dataRestoreModule {
            param($a, $pa, $b)
            Undo-BRAVODataRestoreCompletedComponents -CompletedComponents @(
                [pscustomobject]@{ Type = 'MODEL'; LiveDirectory = $a; PrerestoreDirectory = $pa; MoveAsidePerformed = $true },
                [pscustomobject]@{ Type = 'BLOG'; LiveDirectory = $b; PrerestoreDirectory = "$b.prerestore_x"; MoveAsidePerformed = $false }
            )
        } $liveA $prerestoreA $liveB

        Test-BRAVOCondition `
            -Condition (
                (@($crossRollbackResult.RolledBack) -join ',') -eq 'BLOG,MODEL' -and
                @($crossRollbackResult.Failures).Count -eq 0 -and
                (Test-Path -LiteralPath (Join-Path $liveA 'original.txt')) -and
                -not (Test-Path -LiteralPath (Join-Path $liveA 'restored.txt')) -and
                -not (Test-Path -LiteralPath $prerestoreA) -and
                -not (Test-Path -LiteralPath $liveB)
            ) `
            -Name "DataRestore/CrossComponentRollbackRestoresPreviousState" `
            -Failure "Undo-BRAVODataRestoreCompletedComponents має відкочувати вже відновлені компоненти у ЗВОРОТНОМУ порядку: повертати prerestore-копію на місце (MoveAsidePerformed=true) і прибирати щойно створений каталог (MoveAsidePerformed=false)"

        # Відмова відкату одного компонента не зупиняє відкат решти.
        # Сценарій B (F-2): збійний компонент має оброблятися ПЕРШИМ у
        # фактичному (reverse) порядку відкату, інакше тест не доводить
        # continuation — після нього просто не лишалося б кого відкочувати,
        # і реалізація з `break` після першої помилки пройшла б тест.
        # Вхід [MODEL2, BRAVOEXCH] -> reverse [BRAVOEXCH(fail), MODEL2(success)].
        $liveC = Join-Path $crossRollbackRoot 'BRAVOEXCH'
        $prerestoreC = Join-Path $crossRollbackRoot 'BRAVOEXCH.prerestore_20260814_120000'
        [void][IO.Directory]::CreateDirectory($liveC)
        [void][IO.Directory]::CreateDirectory($prerestoreC)
        [IO.File]::WriteAllText((Join-Path $liveC 'locked.bin'), 'lock me')
        [IO.File]::WriteAllText((Join-Path $prerestoreC 'original.txt'), 'old-bravoexch')
        # MODEL2 після збою BRAVOEXCH: має бути відкочений попри попередню помилку.
        $liveD = Join-Path $crossRollbackRoot 'MODEL2'
        $prerestoreD = Join-Path $crossRollbackRoot 'MODEL2.prerestore_20260814_120000'
        [void][IO.Directory]::CreateDirectory($liveD)
        [void][IO.Directory]::CreateDirectory($prerestoreD)
        [IO.File]::WriteAllText((Join-Path $liveD 'restored.txt'), 'new-model2')
        [IO.File]::WriteAllText((Join-Path $prerestoreD 'original.txt'), 'old-model2')
        $lockedStream = [IO.File]::Open(
            (Join-Path $liveC 'locked.bin'),
            [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        $partialRollbackResult = & $dataRestoreModule {
            param($c, $pc, $d, $pd)
            Undo-BRAVODataRestoreCompletedComponents -CompletedComponents @(
                [pscustomobject]@{ Type = 'MODEL2'; LiveDirectory = $d; PrerestoreDirectory = $pd; MoveAsidePerformed = $true },
                [pscustomobject]@{ Type = 'BRAVOEXCH'; LiveDirectory = $c; PrerestoreDirectory = $pc; MoveAsidePerformed = $true }
            )
        } $liveC $prerestoreC $liveD $prerestoreD

        Test-BRAVOCondition `
            -Condition (
                @($partialRollbackResult.Failures).Count -eq 1 -and
                ([string]@($partialRollbackResult.Failures)[0].Type) -eq 'BRAVOEXCH' -and
                -not [string]::IsNullOrWhiteSpace([string]@($partialRollbackResult.Failures)[0].Error) -and
                (@($partialRollbackResult.RolledBack) -join ',') -eq 'MODEL2' -and
                (Test-Path -LiteralPath $prerestoreC) -and
                (Test-Path -LiteralPath (Join-Path $liveD 'original.txt')) -and
                -not (Test-Path -LiteralPath (Join-Path $liveD 'restored.txt')) -and
                -not (Test-Path -LiteralPath $prerestoreD)
            ) `
            -Name "DataRestore/CrossComponentRollbackContinuesAfterFailure" `
            -Failure "Збій відкату компонента, який обробляється ПЕРШИМ, не повинен зупиняти відкат наступних: BRAVOEXCH має потрапити у Failures (Type+Error) із збереженою prerestore-копією, а MODEL2 — все одно повернутися до попереднього стану (original.txt на місці, prerestore-каталог зник)"

        # Сценарій B (продовження): термінальні статуси. Компонент, відкат
        # якого не завершився, НЕ може лишатися RESTORED.
        $statusUpdatesPartial = & $dataRestoreModule {
            param($r)
            Get-BRAVODataRestoreRollbackStatusUpdates -CrossRollbackResult $r -FailedComponent 'BLOG'
        } $partialRollbackResult
        $rolledBackUpdate = @($statusUpdatesPartial | Where-Object { $_.Component -eq 'MODEL2' })[0]
        $rollbackFailedUpdate = @($statusUpdatesPartial | Where-Object { $_.Component -eq 'BRAVOEXCH' })[0]
        Test-BRAVOCondition `
            -Condition (
                @($statusUpdatesPartial).Count -eq 2 -and
                [string]$rolledBackUpdate.Status -eq 'ROLLED_BACK' -and
                [string]$rollbackFailedUpdate.Status -eq 'ROLLBACK_FAILED' -and
                ([string]$rollbackFailedUpdate.Detail).Contains('відкат не завершено') -and
                ([string]$rollbackFailedUpdate.Detail).Contains('BLOG') -and
                ([string]$rolledBackUpdate.Detail).Contains('BLOG')
            ) `
            -Name "DataRestore/RollbackFailureYieldsTerminalRollbackFailedStatus" `
            -Failure "Компонент з невдалим відкатом має отримати термінальний статус ROLLBACK_FAILED із конкретною причиною й згадкою компонента, що спричинив відкат, а успішно відкочений — ROLLED_BACK"

        # Сценарій A: усі відкати успішні -> усі ROLLED_BACK, жодного
        # ROLLBACK_FAILED (перевірка на попередньому, успішному прогоні).
        $statusUpdatesFull = & $dataRestoreModule {
            param($r)
            Get-BRAVODataRestoreRollbackStatusUpdates -CrossRollbackResult $r -FailedComponent 'BRAVOEXCH'
        } $crossRollbackResult
        Test-BRAVOCondition `
            -Condition (
                @($statusUpdatesFull).Count -eq 2 -and
                @($statusUpdatesFull | Where-Object { [string]$_.Status -eq 'ROLLED_BACK' }).Count -eq 2 -and
                @($statusUpdatesFull | Where-Object { [string]$_.Status -eq 'ROLLBACK_FAILED' }).Count -eq 0 -and
                @($statusUpdatesFull | Where-Object { [string]$_.Status -eq 'RESTORED' }).Count -eq 0
            ) `
            -Name "DataRestore/FullCrossRollbackMarksEveryComponentRolledBack" `
            -Failure "Коли всі відкати успішні, кожен раніше відновлений компонент має стати ROLLED_BACK і жоден не може лишитися RESTORED"

        # Сценарій C: статуси мають бути узгоджені між ValidateSet, рендерингом
        # підсумку і фільтром prerestore-копій — інакше термінальний статус
        # існував би лише в одному місці.
        Test-BRAVOCondition `
            -Condition (
                $dataRestoreRuntimeTextForTests.Contains("'RESTORED', 'ROLLED_BACK', 'ROLLBACK_FAILED', 'FAILED', 'NOT_RUN'") -and
                $dataRestoreRuntimeTextForTests.Contains("'ROLLED_BACK' { 'ВІДКОЧЕНО' }") -and
                $dataRestoreRuntimeTextForTests.Contains("'ROLLBACK_FAILED' { 'ПОМИЛКА ВІДКАТУ' }") -and
                $dataRestoreRuntimeTextForTests.Contains("[string]`$_.Status -ne 'ROLLED_BACK'") -and
                $dataRestoreRuntimeTextForTests.Contains("[string]`$_.Status -eq 'ROLLBACK_FAILED'")
            ) `
            -Name "DataRestore/RollbackStatusesAreSurfacedConsistently" `
            -Failure "ROLLED_BACK і ROLLBACK_FAILED мають бути в ValidateSet, мати operator-facing текст у підсумку ('ВІДКОЧЕНО' / 'ПОМИЛКА ВІДКАТУ') і правильно впливати на список prerestore-копій (успішно відкочені — приховані, ROLLBACK_FAILED — показані з попередженням)"
    } finally {
        if ($null -ne $lockedStream) { $lockedStream.Dispose() }
        if (Test-Path -LiteralPath $crossRollbackRoot) {
            Remove-Item -LiteralPath $crossRollbackRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 6.1. B20 testability: deterministic cross-component rollback
    # failpoint (Invoke-BRAVODataRestoreTestFailPoint). Ізольовано, без
    # реального restore/Credential Manager/live E:\LIMS. Env-змінні
    # (two-factor guard) очищаються в finally, щоб не протекти в подальші
    # self-tests цього ж процесу. ---------------------------------------
    function Reset-BRAVODataRestoreTestFailPointEnv {
        Remove-Item -Path 'Env:\BRAVO_DATARESTORE_TEST_HOOKS' -ErrorAction SilentlyContinue
        Remove-Item -Path 'Env:\BRAVO_DATARESTORE_TEST_FAILPOINT' -ErrorAction SilentlyContinue
    }
    try {
        # Структурна перевірка: failpoint стоїть ПІСЛЯ підтвердженого
        # move-aside SUCCESS і ДО Invoke-BRAVOSevenZipExtraction, всередині
        # ТОГО САМОГО InPlace-блоку/try, що й реальне відновлення — без
        # окремого test-only catch навколо самого виклику.
        $moveAsideCallIndex = $dataRestoreRuntimeTextForTests.IndexOf('Invoke-BRAVODataRestoreMoveAside `')
        $moveAsidePerformedAssignIndex = $dataRestoreRuntimeTextForTests.IndexOf("`$moveAsidePerformed = [bool]`$moveAsideResult.Performed")
        $failPointCallIndex = $dataRestoreRuntimeTextForTests.IndexOf("Invoke-BRAVODataRestoreTestFailPoint -Point 'AfterMoveAside' -Component `$componentType")
        $extractionCallIndex = $dataRestoreRuntimeTextForTests.IndexOf('Invoke-BRAVOSevenZipExtraction `')
        # Немає окремого catch МІЖ MoveAside-блоком (де стоїть failpoint) і
        # самим циклом: перевіряємо, що між присвоєнням moveAsidePerformed і
        # викликом failpoint немає закриття try/відкриття нового catch —
        # тобто вони лишаються в одному блоці.
        $textBetweenAssignAndFailPoint = if ($moveAsidePerformedAssignIndex -ge 0 -and $failPointCallIndex -gt $moveAsidePerformedAssignIndex) {
            $dataRestoreRuntimeTextForTests.Substring($moveAsidePerformedAssignIndex, $failPointCallIndex - $moveAsidePerformedAssignIndex)
        } else { $null }
        Test-BRAVOCondition `
            -Condition (
                $moveAsideCallIndex -ge 0 -and
                $moveAsidePerformedAssignIndex -gt $moveAsideCallIndex -and
                $failPointCallIndex -gt $moveAsidePerformedAssignIndex -and
                $extractionCallIndex -gt $failPointCallIndex -and
                $null -ne $textBetweenAssignAndFailPoint -and
                -not $textBetweenAssignAndFailPoint.Contains('} catch {') -and
                -not $textBetweenAssignAndFailPoint.Contains('} try {')
            ) `
            -Name "DataRestore/TestFailPointCalledAfterMoveAsideBeforeExtraction" `
            -Failure "Invoke-BRAVODataRestoreTestFailPoint має викликатися СТРОГО між підтвердженим move-aside SUCCESS (`$moveAsidePerformed-присвоєнням) і Invoke-BRAVOSevenZipExtraction, у тому самому try/InPlace-блоці — без окремого test-only catch"

        # A. guard відсутній, failpoint заданий -> NO THROW.
        Reset-BRAVODataRestoreTestFailPointEnv
        $env:BRAVO_DATARESTORE_TEST_FAILPOINT = 'AfterMoveAside:BLOG'
        $threwA = $false
        try { [void](& $dataRestoreModule { Invoke-BRAVODataRestoreTestFailPoint -Point 'AfterMoveAside' -Component 'BLOG' }) } catch { $threwA = $true }

        # B. guard неправильний -> NO THROW.
        Reset-BRAVODataRestoreTestFailPointEnv
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'wrong'
        $env:BRAVO_DATARESTORE_TEST_FAILPOINT = 'AfterMoveAside:BLOG'
        $threwB = $false
        try { [void](& $dataRestoreModule { Invoke-BRAVODataRestoreTestFailPoint -Point 'AfterMoveAside' -Component 'BLOG' }) } catch { $threwB = $true }

        # C. guard валідний, failpoint відсутній -> NO THROW.
        Reset-BRAVODataRestoreTestFailPointEnv
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
        $threwC = $false
        try { [void](& $dataRestoreModule { Invoke-BRAVODataRestoreTestFailPoint -Point 'AfterMoveAside' -Component 'BLOG' }) } catch { $threwC = $true }

        # D. malformed failpoint (без ':') -> NO THROW.
        Reset-BRAVODataRestoreTestFailPointEnv
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
        $env:BRAVO_DATARESTORE_TEST_FAILPOINT = 'AfterMoveAsideBLOG'
        $threwD = $false
        try { [void](& $dataRestoreModule { Invoke-BRAVODataRestoreTestFailPoint -Point 'AfterMoveAside' -Component 'BLOG' }) } catch { $threwD = $true }

        # E. point mismatch -> NO THROW.
        Reset-BRAVODataRestoreTestFailPointEnv
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
        $env:BRAVO_DATARESTORE_TEST_FAILPOINT = 'AfterMoveAside:BLOG'
        $threwE = $false
        try { [void](& $dataRestoreModule { Invoke-BRAVODataRestoreTestFailPoint -Point 'BeforeExtraction' -Component 'BLOG' }) } catch { $threwE = $true }

        # F. component mismatch -> NO THROW.
        $threwF = $false
        try { [void](& $dataRestoreModule { Invoke-BRAVODataRestoreTestFailPoint -Point 'AfterMoveAside' -Component 'MODEL' }) } catch { $threwF = $true }

        # G. точний (case-insensitive) збіг на КАНОНІЧНИХ Point/Component ->
        # THROW із синтетичним маркером, без реального шляху/пароля/
        # webhook/секрету в тексті винятку.
        Reset-BRAVODataRestoreTestFailPointEnv
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
        $env:BRAVO_DATARESTORE_TEST_FAILPOINT = 'AfterMoveAside:BLOG'
        $threwG = $false
        $exceptionMessageG = $null
        try { [void](& $dataRestoreModule { Invoke-BRAVODataRestoreTestFailPoint -Point 'AfterMoveAside' -Component 'BLOG' }) } catch {
            $threwG = $true
            $exceptionMessageG = [string]$_.Exception.Message
        }

        # H. wildcard відхиляється (не exact match) -> NO THROW.
        Reset-BRAVODataRestoreTestFailPointEnv
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
        $env:BRAVO_DATARESTORE_TEST_FAILPOINT = 'AfterMoveAside:*'
        $threwH = $false
        try { [void](& $dataRestoreModule { Invoke-BRAVODataRestoreTestFailPoint -Point 'AfterMoveAside' -Component 'BLOG' }) } catch { $threwH = $true }

        # I. canonical allowlist: НЕканонічний Component (синтетичний BAZA)
        # -> NO THROW, навіть попри валідний guard і точний self-match
        # Point/Component. Component-allowlist: лише MODEL/BLOG/BRAVOEXCH.
        Reset-BRAVODataRestoreTestFailPointEnv
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
        $env:BRAVO_DATARESTORE_TEST_FAILPOINT = 'AfterMoveAside:BAZA'
        $threwI = $false
        try { [void](& $dataRestoreModule { Invoke-BRAVODataRestoreTestFailPoint -Point 'AfterMoveAside' -Component 'BAZA' }) } catch { $threwI = $true }

        # J. canonical allowlist: НЕканонічна Point (BeforeExtraction — точки
        # такої немає у виклику production pipeline) -> NO THROW, навіть із
        # канонічним Component і точним self-match.
        Reset-BRAVODataRestoreTestFailPointEnv
        $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
        $env:BRAVO_DATARESTORE_TEST_FAILPOINT = 'BeforeExtraction:BLOG'
        $threwJ = $false
        try { [void](& $dataRestoreModule { Invoke-BRAVODataRestoreTestFailPoint -Point 'BeforeExtraction' -Component 'BLOG' }) } catch { $threwJ = $true }

        Test-BRAVOCondition `
            -Condition (-not $threwA -and -not $threwB -and -not $threwC -and -not $threwD -and -not $threwE -and -not $threwF -and -not $threwH) `
            -Name "DataRestore/TestFailPointFailClosedOnGuardOrFormatMismatch" `
            -Failure "Invoke-BRAVODataRestoreTestFailPoint має лишатися no-op (без throw), якщо: guard відсутній (A), guard неправильний (B), failpoint відсутній при валідному guard (C), формат некоректний (D), Point не збігається (E), Component не збігається (F), або задано wildcard замість точного значення (H) — жодна з цих ситуацій не повинна активувати injection"
        Test-BRAVOCondition `
            -Condition (
                $threwG -and
                $exceptionMessageG.Contains('BRAVO_DATARESTORE_TEST_FAILPOINT') -and
                -not ($exceptionMessageG -match 'E:\\|\\LIMS|password|pwd|secret|token|https?://')
            ) `
            -Name "DataRestore/TestFailPointThrowsOnExactMatch" `
            -Failure "при ТОЧНОМУ (case-insensitive) збігу канонічних Point+Component (AfterMoveAside/BLOG) з двома валідними guard-змінними Invoke-BRAVODataRestoreTestFailPoint має кинути виняток із синтетичним маркером BRAVO_DATARESTORE_TEST_FAILPOINT, без жодного реального шляху/секрету в тексті"
        Test-BRAVOCondition `
            -Condition (-not $threwI -and -not $threwJ) `
            -Name "DataRestore/TestFailPointRejectsNonCanonicalPointOrComponent" `
            -Failure "Invoke-BRAVODataRestoreTestFailPoint має лишатися no-op для НЕканонічного Component (I: синтетичний BAZA, поза MODEL/BLOG/BRAVOEXCH) і НЕканонічної Point (J: BeforeExtraction, якої немає в production pipeline) — навіть при валідному guard і точному self-match аргументів виклику"

        # --- Поведінковий тест: production-подібна послідовність
        # MoveAside:A -> MoveAside:B -> FailPoint:B(throw) -> ІСНУЮЧИЙ catch
        # -> Rollback:B (Undo-BRAVODataRestoreMoveAside) -> completed A існує
        # -> Rollback:Completed A (Undo-BRAVODataRestoreCompletedComponents).
        # Використовує РЕАЛЬНІ production-функції (той самий $dataRestoreModule,
        # що й вище) на тимчасових каталогах — не копіює/не дублює алгоритм.
        $sequenceRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_FAILPOINT_SEQ_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
        try {
            [void][IO.Directory]::CreateDirectory($sequenceRoot)
            $liveSeqA = Join-Path $sequenceRoot 'MODEL'
            $prerestoreSeqA = Join-Path $sequenceRoot 'MODEL.prerestore_20260815_000000'
            $liveSeqB = Join-Path $sequenceRoot 'BLOG'
            $prerestoreSeqB = Join-Path $sequenceRoot 'BLOG.prerestore_20260815_000000'

            Reset-BRAVODataRestoreTestFailPointEnv
            $env:BRAVO_DATARESTORE_TEST_HOOKS = 'ACCEPTANCE_ONLY'
            $env:BRAVO_DATARESTORE_TEST_FAILPOINT = 'AfterMoveAside:BLOG'

            $sequenceResult = & $dataRestoreModule {
                param($liveA, $prerestoreA, $liveB, $prerestoreB)

                $sequenceLog = New-Object System.Collections.Generic.List[string]
                $completedInPlaceComponents = New-Object System.Collections.Generic.List[object]

                # --- Component A: move-aside реальний, успішний (real fixture,
                # не production-loop, лише прямий виклик реальної функції) ---
                [void][IO.Directory]::CreateDirectory($liveA)
                [IO.File]::WriteAllText((Join-Path $liveA 'original.txt'), 'old-model')
                [IO.Directory]::Move($liveA, $prerestoreA)
                [void][IO.Directory]::CreateDirectory($liveA)
                [IO.File]::WriteAllText((Join-Path $liveA 'restored.txt'), 'new-model')
                $sequenceLog.Add('MoveAside:A')
                $completedInPlaceComponents.Add([pscustomobject]@{
                    Type = 'MODEL'; LiveDirectory = $liveA; PrerestoreDirectory = $prerestoreA; MoveAsidePerformed = $true
                })

                # --- Component B: move-aside реальний, успішний, ПОТІМ
                # ТОЙ САМИЙ виклик failpoint, що й у production-циклі ---
                [void][IO.Directory]::CreateDirectory($liveB)
                [IO.File]::WriteAllText((Join-Path $liveB 'original.txt'), 'old-blog')
                [IO.Directory]::Move($liveB, $prerestoreB)
                [void][IO.Directory]::CreateDirectory($liveB)
                [IO.File]::WriteAllText((Join-Path $liveB 'restored.txt'), 'new-blog')
                $sequenceLog.Add('MoveAside:B')

                $caughtHere = $false
                try {
                    Invoke-BRAVODataRestoreTestFailPoint -Point 'AfterMoveAside' -Component 'BLOG'
                    $sequenceLog.Add('Extraction:B (НЕ МАЄ ВІДБУТИСЯ)')
                } catch {
                    # ТОЙ САМИЙ catch, що в production: спершу rollback
                    # поточного компонента B, потім — уже завершених (A).
                    $sequenceLog.Add('FailPoint:B')
                    $rollbackB = Undo-BRAVODataRestoreMoveAside `
                        -LiveDirectory $liveB -PrerestoreDirectory $prerestoreB -MoveAsidePerformed $true -TargetCreatedByThisRun $true
                    if ($rollbackB.Success) { $sequenceLog.Add('Rollback:B') }
                    if ($completedInPlaceComponents.Count -gt 0) {
                        $crossRollback = Undo-BRAVODataRestoreCompletedComponents `
                            -CompletedComponents @($completedInPlaceComponents.ToArray())
                        if (@($crossRollback.RolledBack) -contains 'MODEL') { $sequenceLog.Add('RollbackCompleted:A') }
                    }
                    $caughtHere = $true
                }

                [pscustomobject]@{
                    CaughtHere = $caughtHere
                    Sequence = $sequenceLog.ToArray()
                    LiveAHasOriginal = (Test-Path -LiteralPath (Join-Path $liveA 'original.txt'))
                    LiveAHasRestored = (Test-Path -LiteralPath (Join-Path $liveA 'restored.txt'))
                    LiveBHasOriginal = (Test-Path -LiteralPath (Join-Path $liveB 'original.txt'))
                    LiveBHasRestored = (Test-Path -LiteralPath (Join-Path $liveB 'restored.txt'))
                    PrerestoreAGone = -not (Test-Path -LiteralPath $prerestoreA)
                    PrerestoreBGone = -not (Test-Path -LiteralPath $prerestoreB)
                }
            } $liveSeqA $prerestoreSeqA $liveSeqB $prerestoreSeqB

            Test-BRAVOCondition `
                -Condition (
                    $sequenceResult.CaughtHere -and
                    (($sequenceResult.Sequence) -join ',') -eq 'MoveAside:A,MoveAside:B,FailPoint:B,Rollback:B,RollbackCompleted:A' -and
                    $sequenceResult.LiveAHasOriginal -and -not $sequenceResult.LiveAHasRestored -and
                    $sequenceResult.LiveBHasOriginal -and -not $sequenceResult.LiveBHasRestored -and
                    $sequenceResult.PrerestoreAGone -and $sequenceResult.PrerestoreBGone
                ) `
                -Name "DataRestore/TestFailPointFlowsIntoExistingCrossComponentRollback" `
                -Failure "Injected failpoint після move-aside компонента B має потрапляти в ІСНУЮЧИЙ production catch (без окремого test-only rollback шляху): спершу rollback поточного B, потім rollback уже завершеного A (реальні Undo-BRAVODataRestoreMoveAside/Undo-BRAVODataRestoreCompletedComponents) — обидва компоненти мають повернутися РІВНО до pre-run стану"
        } finally {
            if (Test-Path -LiteralPath $sequenceRoot) {
                Remove-Item -LiteralPath $sequenceRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } finally {
        Reset-BRAVODataRestoreTestFailPointEnv
    }

    # --- 6.2. Restore safety review (PR #40): move-aside FAILURE ніколи не
    # має видаляти оригінальні live-дані. Для InPlace TargetDirectory ===
    # LiveSourceDirectory — якщо move-aside провалюється (Success=false),
    # ЖОДНОЇ мутації ще не відбулось: production-catch не має права
    # викликати Undo-BRAVODataRestoreMoveAside (яка Remove-Item-ить
    # $LiveDirectory) на ще незайманому оригіналі. Реальна
    # Invoke-BRAVODataRestoreMoveAside на заблокованому каталозі + точна
    # armed-гілка з production-циклу (structural-перевірка нижче). ---------
    $moveAsideFailureRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_MOVEASIDE_FAIL_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    $lockedLiveStream = $null
    try {
        [void][IO.Directory]::CreateDirectory($moveAsideFailureRoot)
        $liveFail = Join-Path $moveAsideFailureRoot 'MODEL'
        $prerestoreFail = Join-Path $moveAsideFailureRoot 'MODEL.prerestore_20260815_010000'
        [void][IO.Directory]::CreateDirectory($liveFail)
        [IO.File]::WriteAllText((Join-Path $liveFail 'production.txt'), 'live-data-must-survive')
        # Ексклюзивний handle на файл ВСЕРЕДИНІ live-каталогу: на NTFS
        # Directory.Move каталогу з відкритим файлом усередині провалюється
        # (файл, не сам каталог, тримає handle) — той самий сценарій, що й
        # реальний "щось тримає дерево" з production.
        $lockedLiveStream = [IO.File]::Open(
            (Join-Path $liveFail 'production.txt'),
            [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)

        $moveAsideOutcome = & $dataRestoreModule {
            param($live, $prerestore)
            Invoke-BRAVODataRestoreMoveAside -LiveDirectory $live -PrerestoreDirectory $prerestore
        } $liveFail $prerestoreFail

        # Точна гілка з production-циклу (BRAVO.DataRestore.Runtime.ps1):
        # `$moveAsideArmed` стає true ЛИШЕ після Success=true; catch викликає
        # Undo-BRAVODataRestoreMoveAside ЛИШЕ якщо armed. Тут Success=false
        # -> Undo НЕ викликається, що й перевіряється нижче.
        $moveAsideArmedForTest = [bool]$moveAsideOutcome.Success
        if ($moveAsideArmedForTest) {
            [void](& $dataRestoreModule {
                param($live, $prerestore, $performed)
                Undo-BRAVODataRestoreMoveAside -LiveDirectory $live -PrerestoreDirectory $prerestore -MoveAsidePerformed $performed -TargetCreatedByThisRun $true
            } $liveFail $prerestoreFail ([bool]$moveAsideOutcome.Performed))
        }

        $lockedLiveStream.Dispose()
        $lockedLiveStream = $null

        Test-BRAVOCondition `
            -Condition (
                -not [bool]$moveAsideOutcome.Success -and
                -not [bool]$moveAsideOutcome.Performed -and
                -not $moveAsideArmedForTest -and
                (Test-Path -LiteralPath $liveFail -PathType Container) -and
                (Test-Path -LiteralPath (Join-Path $liveFail 'production.txt')) -and
                ([IO.File]::ReadAllText((Join-Path $liveFail 'production.txt'))) -eq 'live-data-must-survive' -and
                -not (Test-Path -LiteralPath $prerestoreFail)
            ) `
            -Name "DataRestore/MoveAsideFailurePreservesOriginalLiveData" `
            -Failure "коли move-aside провалюється (Success=false), транзакція компонента НЕ armed: production-catch не має права викликати Undo-BRAVODataRestoreMoveAside на оригінальному live-каталозі (TargetDirectory===LiveDirectory для InPlace) — інакше реальні production-дані видаляються, хоча жодна мутація ще не відбулась"

        Test-BRAVOCondition `
            -Condition (
                $dataRestoreRuntimeTextForTests.Contains('$moveAsideArmed = $false') -and
                $dataRestoreRuntimeTextForTests.Contains('$moveAsideArmed = $true') -and
                $dataRestoreRuntimeTextForTests.Contains('if ($moveAsideArmed) {') -and
                ($dataRestoreRuntimeTextForTests.IndexOf('$moveAsideArmed = $true') -lt $dataRestoreRuntimeTextForTests.IndexOf("Invoke-BRAVODataRestoreTestFailPoint -Point 'AfterMoveAside'"))
            ) `
            -Name "DataRestore/MoveAsideArmedFlagGatesCurrentComponentRollback" `
            -Failure "production-цикл має явний `$moveAsideArmed прапорець (false за замовчуванням, true лише після move-aside Success=true, до failpoint-виклику), і catch-гілка має перевіряти його ПЕРЕД викликом Undo-BRAVODataRestoreMoveAside для поточного компонента"
    } finally {
        if ($null -ne $lockedLiveStream) { $lockedLiveStream.Dispose() }
        if (Test-Path -LiteralPath $moveAsideFailureRoot) {
            Remove-Item -LiteralPath $moveAsideFailureRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 6.3. Restore safety review (PR #40): відкат САМОГО поточного
    # компонента, що провалився, теж може не завершитись — статус має
    # явно стати ROLLBACK_FAILED (не generic FAILED), а PrerestoreDirectory
    # — зберегтися для ручного повернення. ---------------------------------
    $currentRollbackFailureRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_CURRENT_ROLLBACK_FAIL_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    $lockedPartialStream = $null
    try {
        [void][IO.Directory]::CreateDirectory($currentRollbackFailureRoot)
        $liveRB = Join-Path $currentRollbackFailureRoot 'MODEL'
        $prerestoreRB = Join-Path $currentRollbackFailureRoot 'MODEL.prerestore_20260815_020000'
        # Стан ПІСЛЯ успішного move-aside + New-Item нової цілі + часткової
        # (невдалої) extraction — саме те, що бачить production-catch.
        [void][IO.Directory]::CreateDirectory($prerestoreRB)
        [IO.File]::WriteAllText((Join-Path $prerestoreRB 'original.txt'), 'old')
        [void][IO.Directory]::CreateDirectory($liveRB)
        [IO.File]::WriteAllText((Join-Path $liveRB 'partial.txt'), 'partial-extraction')
        $lockedPartialStream = [IO.File]::Open(
            (Join-Path $liveRB 'partial.txt'),
            [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)

        $rollbackOutcome = & $dataRestoreModule {
            param($live, $prerestore)
            Undo-BRAVODataRestoreMoveAside -LiveDirectory $live -PrerestoreDirectory $prerestore -MoveAsidePerformed $true -TargetCreatedByThisRun $true
        } $liveRB $prerestoreRB

        $lockedPartialStream.Dispose()
        $lockedPartialStream = $null

        Test-BRAVOCondition `
            -Condition (
                -not [bool]$rollbackOutcome.Success -and
                (Test-Path -LiteralPath $prerestoreRB) -and
                ([string]$rollbackOutcome.Error).Contains($prerestoreRB)
            ) `
            -Name "DataRestore/CurrentComponentRollbackFailurePreservesPrerestoreCopy" `
            -Failure "коли rollback самого поточного компонента (Undo-BRAVODataRestoreMoveAside) не вдається, prerestore-копія має лишитись на диску, а помилка — містити шлях до неї для ручного повернення"

        Test-BRAVOCondition `
            -Condition (
                $dataRestoreRuntimeTextForTests.Contains("`$currentComponentStatus = 'ROLLBACK_FAILED'") -and
                $dataRestoreRuntimeTextForTests.Contains('$currentComponentPrerestoreDirectory = $planComponent.PrerestoreDirectory') -and
                $dataRestoreRuntimeTextForTests.Contains('-Status $currentComponentStatus') -and
                $dataRestoreRuntimeTextForTests.Contains('-PrerestoreDirectory $currentComponentPrerestoreDirectory')
            ) `
            -Name "DataRestore/CurrentComponentOwnRollbackFailureYieldsRollbackFailedStatus" `
            -Failure "коли rollback ПОТОЧНОГО (провального) компонента сам не завершується, його термінальний статус має стати ROLLBACK_FAILED (не generic FAILED), а PrerestoreDirectory — потрапити в Add-BRAVODataRestoreComponentResult для показу оператору"
    } finally {
        if ($null -ne $lockedPartialStream) { $lockedPartialStream.Dispose() }
        if (Test-Path -LiteralPath $currentRollbackFailureRoot) {
            Remove-Item -LiteralPath $currentRollbackFailureRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 6.4. Restore safety review (PR #40): generationId зі ЗМІСТУ
    # manifest-а (недовірений вхід, особливо Source=SFTP) має пройти
    # канонічну формат-перевірку ПЕРЕД участю в Join-Path/staging-шляхах. ---
    $genIdValid1 = & $dataRestoreModule { Test-BRAVODataRestoreGenerationIdFormat -GenerationId '20260814_230004' }
    $genIdValid2 = & $dataRestoreModule { Test-BRAVODataRestoreGenerationIdFormat -GenerationId '20260814_230004_1' }
    $genIdTraversal1 = & $dataRestoreModule { Test-BRAVODataRestoreGenerationIdFormat -GenerationId '..\victim' }
    $genIdTraversal2 = & $dataRestoreModule { Test-BRAVODataRestoreGenerationIdFormat -GenerationId '../victim' }
    $genIdAbsolute = & $dataRestoreModule { Test-BRAVODataRestoreGenerationIdFormat -GenerationId 'C:\victim' }
    $genIdUnc = & $dataRestoreModule { Test-BRAVODataRestoreGenerationIdFormat -GenerationId '\\server\share' }
    $genIdWrongSeparator = & $dataRestoreModule { Test-BRAVODataRestoreGenerationIdFormat -GenerationId '20260814-230004' }
    $genIdArbitrary = & $dataRestoreModule { Test-BRAVODataRestoreGenerationIdFormat -GenerationId 'arbitrary text' }
    $genIdEmpty = & $dataRestoreModule { Test-BRAVODataRestoreGenerationIdFormat -GenerationId '' }
    Test-BRAVOCondition `
        -Condition (
            $genIdValid1 -eq $true -and
            $genIdValid2 -eq $true -and
            $genIdTraversal1 -eq $false -and
            $genIdTraversal2 -eq $false -and
            $genIdAbsolute -eq $false -and
            $genIdUnc -eq $false -and
            $genIdWrongSeparator -eq $false -and
            $genIdArbitrary -eq $false -and
            $genIdEmpty -eq $false
        ) `
        -Name "DataRestore/GenerationIdFormatRejectsPathTraversal" `
        -Failure "Test-BRAVODataRestoreGenerationIdFormat має приймати лише yyyyMMdd_HHmmss(_N) і відхиляти будь-що інше — відносні/абсолютні/UNC шляхи, неправильний роздільник, довільний текст, порожній рядок"

    # Containment-перевірка (defense-in-depth поверх формату): обчислений
    # staging-шлях generation має лежати ВСЕРЕДИНІ staging root — той самий
    # Test-BRAVODataRestorePathWithin, що й для OutOfPlace -TargetPath.
    $genIdContainmentOk = & $dataRestoreModule {
        Test-BRAVODataRestorePathWithin -Path 'C:\BACKUP\RESTORE_STAGING\20260814_230004' -Directory 'C:\BACKUP\RESTORE_STAGING'
    }
    $genIdContainmentEscape = & $dataRestoreModule {
        Test-BRAVODataRestorePathWithin -Path 'C:\BACKUP\RESTORE_STAGING\..\..\Windows\System32' -Directory 'C:\BACKUP\RESTORE_STAGING'
    }
    Test-BRAVOCondition `
        -Condition ($genIdContainmentOk -eq $true -and $genIdContainmentEscape -eq $false) `
        -Name "DataRestore/GenerationIdStagingPathContainmentAssertion" `
        -Failure "обчислений staging-шлях generation (stagingRoot + generationId) має проходити containment-перевірку Test-BRAVODataRestorePathWithin відносно staging root"

    Test-BRAVOCondition `
        -Condition (
            $dataRestoreRuntimeTextForTests.Contains('-not (Test-BRAVODataRestoreGenerationIdFormat -GenerationId $GenerationId)') -and
            $dataRestoreRuntimeTextForTests.Contains('-not (Test-BRAVODataRestoreGenerationIdFormat -GenerationId $script:dataRestoreSelectedGenerationId)') -and
            $dataRestoreRuntimeTextForTests.Contains('-not (Test-BRAVODataRestorePathWithin -Path $script:dataRestoreStagingGenerationRoot -Directory $stagingRootPath)')
        ) `
        -Name "DataRestore/GenerationIdValidatedAtCliAndManifestSelection" `
        -Failure "той самий канонічний Test-BRAVODataRestoreGenerationIdFormat має застосовуватись і до -GenerationId з командного рядка, і до generationId, прочитаного зі ЗМІСТУ обраного manifest-а, ПЕРЕД побудовою staging-шляху, плюс containment-перевірка обчисленого шляху"

    # --- 6.5. Restore safety review (PR #40): OutOfPlace має захищати УСІ
    # discovered live-джерела (MODEL/BLOG/BRAVOEXCH), а не лише запитаний
    # -Component — інакше відновлення MODEL могло б влучити у live BLOG. ---
    $multiSourceTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_MULTI_SOURCE_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        $multiBackupRoot = Join-Path $multiSourceTestRoot 'BACKUP'
        $multiRuntimeRoot = Join-Path $multiSourceTestRoot 'RUNTIME'
        $multiStagingRoot = Join-Path $multiBackupRoot 'RESTORE_STAGING'
        $multiLiveRoot = Join-Path $multiSourceTestRoot 'LIVE'
        $multiLiveModel = Join-Path $multiLiveRoot 'MODEL'
        $multiLiveBlog = Join-Path $multiLiveRoot 'BLOG'
        $multiLiveBravoexch = Join-Path $multiLiveRoot 'BRAVOEXCH'
        foreach ($multiDirectory in @($multiBackupRoot, $multiRuntimeRoot, $multiStagingRoot, $multiLiveModel, $multiLiveBlog, $multiLiveBravoexch)) {
            [void][IO.Directory]::CreateDirectory($multiDirectory)
        }
        $multiDefinitions = @(
            [pscustomobject]@{ Type = 'MODEL'; Source = (Join-Path $multiLiveModel 'model.gdb') },
            [pscustomobject]@{ Type = 'BLOG'; Source = (Join-Path $multiLiveBlog 'blog.db') },
            [pscustomobject]@{ Type = 'BRAVOEXCH'; Source = (Join-Path $multiLiveBravoexch 'exch.db') }
        )
        $multiPlanInvoke = {
            param($Module, $TargetPath, $Definitions)
            & $Module {
                param($t, $b, $r, $s, $d)
                Get-BRAVODataRestorePlan `
                    -ComponentTypes @('MODEL') `
                    -RestoreMode 'OutOfPlace' `
                    -RequestedTargetPath $t `
                    -BackupRoot $b `
                    -RuntimeRootPath $r `
                    -StagingRoot $s `
                    -ArchiveDefinitions $d `
                    -RunStamp '20260814_120000'
            } $TargetPath $multiBackupRoot $multiRuntimeRoot $multiStagingRoot $Definitions
        }
        # Запитано лише MODEL, але ціль перетинається з BLOG/BRAVOEXCH.
        $multiIntoBlog = & $multiPlanInvoke $dataRestoreModule (Join-Path $multiLiveBlog 'OUT') $multiDefinitions
        $multiEqualsBravoexch = & $multiPlanInvoke $dataRestoreModule $multiLiveBravoexch $multiDefinitions
        $multiParentOfBlog = & $multiPlanInvoke $dataRestoreModule $multiLiveRoot $multiDefinitions
        $multiSafeTarget = & $multiPlanInvoke $dataRestoreModule (Join-Path $multiSourceTestRoot 'SAFE_TARGET') $multiDefinitions

        Test-BRAVOCondition `
            -Condition (
                -not $multiIntoBlog.Success -and
                -not $multiEqualsBravoexch.Success -and
                -not $multiParentOfBlog.Success -and
                $multiSafeTarget.Success
            ) `
            -Name "DataRestore/OutOfPlaceProtectsAllDiscoveredLiveSourcesNotOnlyRequested" `
            -Failure "Get-BRAVODataRestorePlan (OutOfPlace) має відхиляти -TargetPath, що влучає в БУДЬ-ЯКЕ discovered live-джерело (навіть НЕ запитаного зараз компонента) — ціль всередині live BLOG, точний збіг з live BRAVOEXCH, і батьківський каталог, що містить live BLOG, мають відхилятись попри запит лише -Component MODEL; безпечна ціль поза всіма джерелами — приймається"
    } finally {
        if (Test-Path -LiteralPath $multiSourceTestRoot) {
            Remove-Item -LiteralPath $multiSourceTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 6.6. Restore safety review (PR #40): SFTP пошук COMPLETE generation
    # не має обриватись на перших 10 manifest-ах. Ізольований модуль:
    # реальна Invoke-BRAVODataRestoreSftpManifestFetch (той самий батчинг-
    # алгоритм), але з test double замість WinSCP.com (жодного мережевого
    # виклику). ------------------------------------------------------------
    $sftpFetchParseTokens = $null
    $sftpFetchParseErrors = $null
    $sftpFetchAst = [Management.Automation.Language.Parser]::ParseInput(
        $dataRestoreRuntimeTextForTests, [ref]$sftpFetchParseTokens, [ref]$sftpFetchParseErrors)
    $sftpFetchFunctionNames = @('Invoke-BRAVODataRestoreSftpManifestFetch', 'Get-BRAVODataRestoreSftpOperationTimeoutSeconds', 'Get-BRAVODataRestoreWinSCPDownloads', 'New-BRAVODataRestoreWinSCPNamespaceManager', 'Test-BRAVODataRestoreWinSCPListingSucceeded', 'Get-BRAVODataRestoreGenerationIdSortKey', 'Sort-BRAVODataRestoreManifestNamesByGenerationDescending')
    $sftpFetchFunctionTexts = @()
    foreach ($sftpFetchFunctionName in $sftpFetchFunctionNames) {
        $sftpFetchFunctionAst = @($sftpFetchAst.FindAll({
            param($candidate) $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $candidate.Name -eq $sftpFetchFunctionName
        }, $true)) | Select-Object -First 1
        if ($null -eq $sftpFetchFunctionAst) { throw "function not found for SFTP fetch isolation test: $sftpFetchFunctionName" }
        $sftpFetchFunctionTexts += $sftpFetchFunctionAst.Extent.Text
    }
    $sftpFetchStubs = @'
function Invoke-BRAVODataRestoreWinSCPScript {
    # Test double: без реального WinSCP.com/мережі. 'ls' повертає
    # маркерний Xml (парситься нижче тестовим Get-BRAVODataRestoreWinSCPListingNames);
    # 'get' матеріалізує локальний manifest-файл із фікстур сценарію і
    # будує СПРАВЖНІЙ XmlDocument у WinSCP-схемі (w:download/w:filename/
    # w:result), щоб РЕАЛЬНА Get-BRAVODataRestoreWinSCPDownloads могла його
    # розпарсити — саме так перевіряється fail-closed поведінка на
    # per-download відмові. Файл, відсутній у $script:BRAVOSelfTestSftpManifestContent,
    # симулює провалене завантаження (result success="false").
    param([string[]]$Commands, [int]$TimeoutSeconds)
    if (@($Commands) -match '^ls ') {
        # $script:BRAVOSelfTestSftpListingSucceeded (за замовчуванням true,
        # якщо сценарій не задав інакше) керує w:result success для
        # ls-fail-closed тесту нижче.
        $listingSucceeded = if ($null -eq $script:BRAVOSelfTestSftpListingSucceeded) { $true } else { [bool]$script:BRAVOSelfTestSftpListingSucceeded }
        $listingNamespaceUri = 'http://winscp.net/schema/session/1.0'
        $listingXmlDocument = New-Object System.Xml.XmlDocument
        $listingSessionNode = $listingXmlDocument.CreateElement('session', $listingNamespaceUri)
        [void]$listingXmlDocument.AppendChild($listingSessionNode)
        $lsNode = $listingXmlDocument.CreateElement('ls', $listingNamespaceUri)
        $lsResultNode = $listingXmlDocument.CreateElement('result', $listingNamespaceUri)
        [void]$lsResultNode.SetAttribute('success', $(if ($listingSucceeded) { 'true' } else { 'false' }))
        [void]$lsNode.AppendChild($lsResultNode)
        $filesNode = $listingXmlDocument.CreateElement('files', $listingNamespaceUri)
        foreach ($listingFileName in @($script:BRAVOSelfTestSftpListingNames)) {
            $fileNode = $listingXmlDocument.CreateElement('file', $listingNamespaceUri)
            $filenameNode = $listingXmlDocument.CreateElement('filename', $listingNamespaceUri)
            [void]$filenameNode.SetAttribute('value', $listingFileName)
            [void]$fileNode.AppendChild($filenameNode)
            [void]$filesNode.AppendChild($fileNode)
        }
        [void]$lsNode.AppendChild($filesNode)
        [void]$listingSessionNode.AppendChild($lsNode)
        return [pscustomobject]@{ Success = $true; Xml = $listingXmlDocument; Error = $null }
    }
    $namespaceUri = 'http://winscp.net/schema/session/1.0'
    $xmlDocument = New-Object System.Xml.XmlDocument
    $sessionNode = $xmlDocument.CreateElement('session', $namespaceUri)
    [void]$xmlDocument.AppendChild($sessionNode)
    foreach ($command in @($Commands)) {
        if ($command -match 'get "[^"]*/(?<name>[^"/]+)" "(?<local>[^"]+)"') {
            $manifestName = $Matches['name']
            $manifestContent = $script:BRAVOSelfTestSftpManifestContent[$manifestName]
            $downloadNode = $xmlDocument.CreateElement('download', $namespaceUri)
            $filenameNode = $xmlDocument.CreateElement('filename', $namespaceUri)
            [void]$filenameNode.SetAttribute('value', $manifestName)
            [void]$downloadNode.AppendChild($filenameNode)
            $resultNode = $xmlDocument.CreateElement('result', $namespaceUri)
            if ($null -ne $manifestContent) {
                [IO.File]::WriteAllText($Matches['local'], $manifestContent)
                [void]$resultNode.SetAttribute('success', 'true')
            } else {
                [void]$resultNode.SetAttribute('success', 'false')
                $messageNode = $xmlDocument.CreateElement('message', $namespaceUri)
                $messageNode.InnerText = 'simulated download failure'
                [void]$resultNode.AppendChild($messageNode)
            }
            [void]$downloadNode.AppendChild($resultNode)
            [void]$sessionNode.AppendChild($downloadNode)
        }
    }
    return [pscustomobject]@{ Success = $true; Xml = $xmlDocument; Error = $null }
}
'@
    # Get-BRAVODataRestoreWinSCPListingNames — РЕАЛЬНА production-функція
    # (не stub): тепер, коли 'ls' стаб вище будує справжній
    # schema-конформний XmlDocument, реальний парсер коректно його читає —
    # немає причини дублювати логіку окремим test double.
    $sftpFetchFunctionNames += 'Get-BRAVODataRestoreWinSCPListingNames'
    $sftpFetchFunctionAstForListing = @($sftpFetchAst.FindAll({
        param($candidate) $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $candidate.Name -eq 'Get-BRAVODataRestoreWinSCPListingNames'
    }, $true)) | Select-Object -First 1
    if ($null -eq $sftpFetchFunctionAstForListing) { throw "function not found for SFTP fetch isolation test: Get-BRAVODataRestoreWinSCPListingNames" }
    $sftpFetchFunctionTexts += $sftpFetchFunctionAstForListing.Extent.Text
    $sftpFetchModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($sftpFetchStubs + [Environment]::NewLine + ($sftpFetchFunctionTexts -join [Environment]::NewLine)) `
        -FunctionNames (@('Invoke-BRAVODataRestoreWinSCPScript') + $sftpFetchFunctionNames)

    function New-BRAVOSelfTestSftpManifestFixture {
        param([string]$GenerationId, [string]$Status)
        return (@{ generationId = $GenerationId; status = $Status } | ConvertTo-Json -Compress)
    }

    $sftpFetchTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_SFTP_FETCH_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        [void][IO.Directory]::CreateDirectory($sftpFetchTestRoot)

        # #1: найновіший manifest уже COMPLETE -> обирається без додаткових батчів.
        $stagingDir1 = Join-Path $sftpFetchTestRoot 'case1'
        $names1 = @("BRAVO_BACKUP_20260814_100000.json", "BRAVO_BACKUP_20260813_100000.json")
        $content1 = @{
            'BRAVO_BACKUP_20260814_100000.json' = (New-BRAVOSelfTestSftpManifestFixture '20260814_100000' 'COMPLETE')
            'BRAVO_BACKUP_20260813_100000.json' = (New-BRAVOSelfTestSftpManifestFixture '20260813_100000' 'COMPLETE')
        }
        $result1 = & $sftpFetchModule {
            param($dir, $names, $content)
            $script:sftpDirectories = @{ Manifest = '/remote/manifests' }
            $script:BRAVOSelfTestSftpListingNames = $names
            $script:BRAVOSelfTestSftpManifestContent = $content
            Invoke-BRAVODataRestoreSftpManifestFetch -StagingManifestDirectory $dir -RequestedGenerationId $null
        } $stagingDir1 $names1 $content1

        # #2: перші 10 (batch 1) — INCOMPLETE/FAILED, 11-й (batch 2) — COMPLETE.
        $stagingDir2 = Join-Path $sftpFetchTestRoot 'case2'
        $names2 = New-Object System.Collections.Generic.List[string]
        $content2 = @{}
        for ($i = 1; $i -le 10; $i++) {
            $genId = "202608{0:D2}_100000" -f (30 - $i)
            $name = "BRAVO_BACKUP_$genId.json"
            $names2.Add($name)
            $content2[$name] = (New-BRAVOSelfTestSftpManifestFixture $genId 'INCOMPLETE')
        }
        $oldestGenId = '20260801_090000'
        $oldestName = "BRAVO_BACKUP_$oldestGenId.json"
        $names2.Add($oldestName)
        $content2[$oldestName] = (New-BRAVOSelfTestSftpManifestFixture $oldestGenId 'COMPLETE')
        $result2 = & $sftpFetchModule {
            param($dir, $names, $content)
            $script:sftpDirectories = @{ Manifest = '/remote/manifests' }
            $script:BRAVOSelfTestSftpListingNames = @($names)
            $script:BRAVOSelfTestSftpManifestContent = $content
            Invoke-BRAVODataRestoreSftpManifestFetch -StagingManifestDirectory $dir -RequestedGenerationId $null
        } $stagingDir2 $names2.ToArray() $content2

        # #3: декілька COMPLETE -> обирається найновіший.
        $stagingDir3 = Join-Path $sftpFetchTestRoot 'case3'
        $names3 = @("BRAVO_BACKUP_20260814_100000.json", "BRAVO_BACKUP_20260813_100000.json", "BRAVO_BACKUP_20260812_100000.json")
        $content3 = @{
            'BRAVO_BACKUP_20260814_100000.json' = (New-BRAVOSelfTestSftpManifestFixture '20260814_100000' 'COMPLETE')
            'BRAVO_BACKUP_20260813_100000.json' = (New-BRAVOSelfTestSftpManifestFixture '20260813_100000' 'COMPLETE')
            'BRAVO_BACKUP_20260812_100000.json' = (New-BRAVOSelfTestSftpManifestFixture '20260812_100000' 'INCOMPLETE')
        }
        $result3 = & $sftpFetchModule {
            param($dir, $names, $content)
            $script:sftpDirectories = @{ Manifest = '/remote/manifests' }
            $script:BRAVOSelfTestSftpListingNames = $names
            $script:BRAVOSelfTestSftpManifestContent = $content
            Invoke-BRAVODataRestoreSftpManifestFetch -StagingManifestDirectory $dir -RequestedGenerationId $null
        } $stagingDir3 $names3 $content3

        # #4: жодного COMPLETE серед усіх кандидатів -> коректна відмова.
        $stagingDir4 = Join-Path $sftpFetchTestRoot 'case4'
        $names4 = @("BRAVO_BACKUP_20260814_100000.json")
        $content4 = @{ 'BRAVO_BACKUP_20260814_100000.json' = (New-BRAVOSelfTestSftpManifestFixture '20260814_100000' 'INCOMPLETE') }
        $threw4 = $false
        $errorMessage4 = $null
        try {
            [void](& $sftpFetchModule {
                param($dir, $names, $content)
                $script:sftpDirectories = @{ Manifest = '/remote/manifests' }
                $script:BRAVOSelfTestSftpListingNames = $names
                $script:BRAVOSelfTestSftpManifestContent = $content
                Invoke-BRAVODataRestoreSftpManifestFetch -StagingManifestDirectory $dir -RequestedGenerationId $null
            } $stagingDir4 $names4 $content4)
        } catch {
            $threw4 = $true
            $errorMessage4 = [string]$_.Exception.Message
        }

        # #5: явний GenerationId -> точна поведінка одного generation (batch-логіка не задіяна).
        $stagingDir5 = Join-Path $sftpFetchTestRoot 'case5'
        $names5 = @('BRAVO_BACKUP_20260810_100000.json')
        $content5 = @{ 'BRAVO_BACKUP_20260810_100000.json' = (New-BRAVOSelfTestSftpManifestFixture '20260810_100000' 'COMPLETE') }
        $result5 = & $sftpFetchModule {
            param($dir, $names, $content)
            $script:sftpDirectories = @{ Manifest = '/remote/manifests' }
            $script:BRAVOSelfTestSftpListingNames = $names
            $script:BRAVOSelfTestSftpManifestContent = $content
            Invoke-BRAVODataRestoreSftpManifestFetch -StagingManifestDirectory $dir -RequestedGenerationId '20260810_100000'
        } $stagingDir5 $names5 $content5

        Test-BRAVOCondition `
            -Condition ([string]$result1.Manifest.generationId -eq '20260814_100000') `
            -Name "DataRestore/SftpManifestSearchSelectsNewestComplete" `
            -Failure "коли найновіший manifest уже COMPLETE, саме він має бути обраний"
        Test-BRAVOCondition `
            -Condition ([string]$result2.Manifest.generationId -eq $oldestGenId) `
            -Name "DataRestore/SftpManifestSearchContinuesBeyondFirstBatchOfTen" `
            -Failure "коли серед перших 10 (найновіших) manifest-ів немає COMPLETE, пошук має продовжуватись на наступний батч, а не обриватись жорстким Select-Object -First 10"
        Test-BRAVOCondition `
            -Condition ([string]$result3.Manifest.generationId -eq '20260814_100000') `
            -Name "DataRestore/SftpManifestSearchSelectsNewestAmongMultipleComplete" `
            -Failure "коли COMPLETE декілька, має обиратись найновіший з-поміж них"
        Test-BRAVOCondition `
            -Condition ($threw4 -and -not [string]::IsNullOrWhiteSpace($errorMessage4)) `
            -Name "DataRestore/SftpManifestSearchFailsCorrectlyWhenNoComplete" `
            -Failure "коли серед УСІХ переглянутих кандидатів немає жодного COMPLETE, функція має завершитись зрозумілою помилкою, а не мовчазним null"
        Test-BRAVOCondition `
            -Condition ([string]$result5.Manifest.generationId -eq '20260810_100000') `
            -Name "DataRestore/SftpManifestSearchExplicitGenerationIdUnaffectedByBatching" `
            -Failure "явний -RequestedGenerationId (генерація #5) має зберігати точну поведінку одного generation, не зачеплену батч-пошуком"
    } finally {
        if (Test-Path -LiteralPath $sftpFetchTestRoot) {
            Remove-Item -LiteralPath $sftpFetchTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 6.7. Second restore safety review (PR #40): SFTP batch identity +
    # fail-closed on partial download failure. Той самий ізольований
    # $sftpFetchModule (реальна Invoke-BRAVODataRestoreSftpManifestFetch),
    # доповнений сценаріями: (a) filename generationId != JSON generationId,
    # (b) найновіший manifest у батчі FAILED завантаження. -----------------
    $sftpFetchTestRoot2 = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_SFTP_FETCH2_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        [void][IO.Directory]::CreateDirectory($sftpFetchTestRoot2)

        # #6: explicit RequestedGenerationId, filename matches, JSON content
        # generationId is a DIFFERENT (but validly-formatted) generation ->
        # REJECT (не accepted лише тому, що формат валідний).
        $stagingDir6 = Join-Path $sftpFetchTestRoot2 'case6'
        $names6 = @('BRAVO_BACKUP_20260815_120000.json')
        $content6 = @{ 'BRAVO_BACKUP_20260815_120000.json' = (New-BRAVOSelfTestSftpManifestFixture '20260814_230004' 'COMPLETE') }
        $threw6 = $false
        try {
            [void](& $sftpFetchModule {
                param($dir, $names, $content)
                $script:sftpDirectories = @{ Manifest = '/remote/manifests' }
                $script:BRAVOSelfTestSftpListingNames = $names
                $script:BRAVOSelfTestSftpManifestContent = $content
                Invoke-BRAVODataRestoreSftpManifestFetch -StagingManifestDirectory $dir -RequestedGenerationId '20260815_120000'
            } $stagingDir6 $names6 $content6)
        } catch { $threw6 = $true }

        # #7: automatic selection (no RequestedGenerationId) — newest manifest
        # has mismatched filename/JSON identity, older one is genuinely
        # COMPLETE and consistent -> fail-closed skip of the suspicious one,
        # older valid one selected (not silently trusting the mismatched JSON).
        $stagingDir7 = Join-Path $sftpFetchTestRoot2 'case7'
        $names7 = @('BRAVO_BACKUP_20260815_120000.json', 'BRAVO_BACKUP_20260814_090000.json')
        $content7 = @{
            'BRAVO_BACKUP_20260815_120000.json' = (New-BRAVOSelfTestSftpManifestFixture '20260814_230004' 'COMPLETE')
            'BRAVO_BACKUP_20260814_090000.json' = (New-BRAVOSelfTestSftpManifestFixture '20260814_090000' 'COMPLETE')
        }
        $result7 = & $sftpFetchModule {
            param($dir, $names, $content)
            $script:sftpDirectories = @{ Manifest = '/remote/manifests' }
            $script:BRAVOSelfTestSftpListingNames = $names
            $script:BRAVOSelfTestSftpManifestContent = $content
            Invoke-BRAVODataRestoreSftpManifestFetch -StagingManifestDirectory $dir -RequestedGenerationId $null
        } $stagingDir7 $names7 $content7

        Test-BRAVOCondition `
            -Condition ($threw6) `
            -Name "DataRestore/SftpManifestRejectsFilenameJsonIdentityMismatchExplicit" `
            -Failure "явний -RequestedGenerationId має відхилятись, якщо ім'я файлу manifest-а і generationId усередині JSON не збігаються, навіть якщо обидва мають валідний формат"
        Test-BRAVOCondition `
            -Condition ([string]$result7.Manifest.generationId -eq '20260814_090000') `
            -Name "DataRestore/SftpManifestAutomaticSelectionSkipsIdentityMismatch" `
            -Failure "автоматичний вибір (без explicit GenerationId) має пропускати manifest із розбіжністю ім'я/JSON generationId fail-closed і обирати наступний дійсно узгоджений COMPLETE"

        # #8: newest manifest download FAILS in WinSCP per-download XML
        # (Success=true overall, per-file result failed) while an OLDER
        # manifest in the SAME batch downloads fine and is COMPLETE ->
        # MUST throw (fail closed), must NOT silently select the older one.
        $stagingDir8 = Join-Path $sftpFetchTestRoot2 'case8'
        $names8 = @('BRAVO_BACKUP_20260815_120000.json', 'BRAVO_BACKUP_20260814_090000.json')
        $content8 = @{
            # newest deliberately NOT materialized locally (simulates failed download)
            'BRAVO_BACKUP_20260814_090000.json' = (New-BRAVOSelfTestSftpManifestFixture '20260814_090000' 'COMPLETE')
        }
        $threw8 = $false
        $errorMessage8 = $null
        try {
            [void](& $sftpFetchModule {
                param($dir, $names, $content)
                $script:sftpDirectories = @{ Manifest = '/remote/manifests' }
                $script:BRAVOSelfTestSftpListingNames = $names
                $script:BRAVOSelfTestSftpManifestContent = $content
                Invoke-BRAVODataRestoreSftpManifestFetch -StagingManifestDirectory $dir -RequestedGenerationId $null
            } $stagingDir8 $names8 $content8)
        } catch {
            $threw8 = $true
            $errorMessage8 = [string]$_.Exception.Message
        }
        Test-BRAVOCondition `
            -Condition ($threw8 -and -not [string]::IsNullOrWhiteSpace($errorMessage8)) `
            -Name "DataRestore/SftpManifestBatchFailsClosedOnPartialDownloadFailure" `
            -Failure "коли завантаження НАЙНОВІШОГО manifest-а в батчі не підтверджено XML-журналом WinSCP (навіть якщо старіший у тому ж батчі завантажився й є COMPLETE), функція має ЗАВЕРШИТИСЬ ПОМИЛКОЮ — не тихо понижуватись до старішої generation через transient мережеву відмову"
    } finally {
        if (Test-Path -LiteralPath $sftpFetchTestRoot2) {
            Remove-Item -LiteralPath $sftpFetchTestRoot2 -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 6.8. Second restore safety review (PR #40): Local manifest identity
    # (canonical Get-BRAVORestoreGenerationManifest, BRAVO.ArchiveHelpers —
    # спільний з BRAVO_RESTORE_TEST.ps1, тому виправлення тут закриває обидва
    # споживачі одразу). Реальний Import-Module, реальні файли на диску. ----
    Remove-Module -Name 'BRAVO.ArchiveHelpers' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.ArchiveHelpers\BRAVO.ArchiveHelpers.psd1") -Force -ErrorAction Stop

    function New-BRAVOSelfTestLocalManifestFixture {
        param([string]$ManifestsRoot, [string]$FileNameGenerationId, [string]$JsonGenerationId, [string]$Status)
        $manifestPath = Join-Path $ManifestsRoot ("BRAVO_BACKUP_{0}.json" -f $FileNameGenerationId)
        $manifestBody = @{ generationId = $JsonGenerationId; status = $Status } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($manifestPath, $manifestBody)
    }

    $localIdentityTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_LOCAL_IDENTITY_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        # Case A: requested=X, filename=X, JSON=X -> PASS.
        $caseARoot = Join-Path $localIdentityTestRoot 'caseA'
        $caseAManifests = Join-Path $caseARoot 'MANIFESTS'
        [void][IO.Directory]::CreateDirectory($caseAManifests)
        New-BRAVOSelfTestLocalManifestFixture -ManifestsRoot $caseAManifests -FileNameGenerationId '20260814_100000' -JsonGenerationId '20260814_100000' -Status 'COMPLETE'
        $selectedA = Get-BRAVORestoreGenerationManifest -BackupRoot $caseARoot -RequestedGenerationId '20260814_100000'

        # Case B: requested=X, filename=X, JSON=Y (mismatch) -> REJECT.
        $caseBRoot = Join-Path $localIdentityTestRoot 'caseB'
        $caseBManifests = Join-Path $caseBRoot 'MANIFESTS'
        [void][IO.Directory]::CreateDirectory($caseBManifests)
        New-BRAVOSelfTestLocalManifestFixture -ManifestsRoot $caseBManifests -FileNameGenerationId '20260814_100000' -JsonGenerationId '20260813_090000' -Status 'COMPLETE'
        $threwB = $false
        try { [void](Get-BRAVORestoreGenerationManifest -BackupRoot $caseBRoot -RequestedGenerationId '20260814_100000') } catch { $threwB = $true }

        # Case C: automatic selection — newest filename=X/JSON=Y mismatched,
        # older filename=Z/JSON=Z consistent -> older selected, fail-closed
        # skip of the mismatched newest (никогда не обираємо lишень за JSON).
        $caseCRoot = Join-Path $localIdentityTestRoot 'caseC'
        $caseCManifests = Join-Path $caseCRoot 'MANIFESTS'
        [void][IO.Directory]::CreateDirectory($caseCManifests)
        New-BRAVOSelfTestLocalManifestFixture -ManifestsRoot $caseCManifests -FileNameGenerationId '20260815_100000' -JsonGenerationId '20260814_010000' -Status 'COMPLETE'
        New-BRAVOSelfTestLocalManifestFixture -ManifestsRoot $caseCManifests -FileNameGenerationId '20260814_090000' -JsonGenerationId '20260814_090000' -Status 'COMPLETE'
        $selectedC = Get-BRAVORestoreGenerationManifest -BackupRoot $caseCRoot

        # Case D: malformed JSON generationId (не проходить canonical формат) -> REJECT.
        $caseDRoot = Join-Path $localIdentityTestRoot 'caseD'
        $caseDManifests = Join-Path $caseDRoot 'MANIFESTS'
        [void][IO.Directory]::CreateDirectory($caseDManifests)
        New-BRAVOSelfTestLocalManifestFixture -ManifestsRoot $caseDManifests -FileNameGenerationId '20260814_100000' -JsonGenerationId 'not-a-generation-id' -Status 'COMPLETE'
        $threwD = $false
        try { [void](Get-BRAVORestoreGenerationManifest -BackupRoot $caseDRoot -RequestedGenerationId '20260814_100000') } catch { $threwD = $true }

        # Case E: автоматичний вибір — НАЙНОВІШИЙ manifest нечитабельний
        # (пошкоджений JSON), старіший валідний -> старіший обирається,
        # але аномалія НЕ мовчазна: повертається у SkippedManifests
        # (P2-дефект «мовчазний пропуск нечитабельного manifest»).
        $caseERoot = Join-Path $localIdentityTestRoot 'caseE'
        $caseEManifests = Join-Path $caseERoot 'MANIFESTS'
        [void][IO.Directory]::CreateDirectory($caseEManifests)
        [IO.File]::WriteAllText((Join-Path $caseEManifests 'BRAVO_BACKUP_20260816_100000.json'), '{ це не валідний JSON !!')
        New-BRAVOSelfTestLocalManifestFixture -ManifestsRoot $caseEManifests -FileNameGenerationId '20260814_090000' -JsonGenerationId '20260814_090000' -Status 'COMPLETE'
        $selectedE = Get-BRAVORestoreGenerationManifest -BackupRoot $caseERoot

        # Case F: той самий пошкоджений manifest, але з явним
        # -RequestedGenerationId -> як і раніше, THROW (поведінка explicit
        # запиту не змінилась).
        $threwF = $false
        try { [void](Get-BRAVORestoreGenerationManifest -BackupRoot $caseERoot -RequestedGenerationId '20260816_100000') } catch { $threwF = $true }

        Test-BRAVOCondition `
            -Condition (
                [string]$selectedE.Manifest.generationId -eq '20260814_090000' -and
                @($selectedE.SkippedManifests).Count -eq 1 -and
                ([string]@($selectedE.SkippedManifests)[0].Reason).Contains('не прочитано') -and
                @($selectedC.SkippedManifests).Count -eq 1 -and
                ([string]@($selectedC.SkippedManifests)[0].Reason).Contains('identity mismatch') -and
                @($selectedA.SkippedManifests).Count -eq 0 -and
                $threwF
            ) `
            -Name "DataRestore/AutoSelectReportsSkippedManifestAnomalies" `
            -Failure "fail-closed пропуск manifest-ів під час АВТОМАТИЧНОГО вибору generation не має бути мовчазним: (E) нечитабельний найновіший manifest -> старіший обраний, аномалія 'не прочитано' у SkippedManifests; (C) identity mismatch звітується; (A) чистий вибір -> SkippedManifests порожній; (F) explicit -RequestedGenerationId на пошкодженому manifest далі кидає помилку"

        Test-BRAVOCondition `
            -Condition (
                [string]$selectedA.Manifest.generationId -eq '20260814_100000' -and
                $threwB -and
                [string]$selectedC.Manifest.generationId -eq '20260814_090000' -and
                $threwD
            ) `
            -Name "DataRestore/LocalManifestIdentityMustMatchFilenameAndRequested" `
            -Failure "Get-BRAVORestoreGenerationManifest (BRAVO.ArchiveHelpers, canonical для Local і SFTP) має вимагати ТОЧНОГО збігу filename-generationId і JSON generationId: (A) requested=filename=JSON проходить; (B) requested=filename != JSON відхиляється; (C) автоматичний вибір пропускає невідповідний найновіший і бере наступний узгоджений; (D) невалідний формат JSON generationId відхиляється"
    } finally {
        Remove-Module -Name 'BRAVO.ArchiveHelpers' -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $localIdentityTestRoot) {
            Remove-Item -LiteralPath $localIdentityTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 6.9. Second restore safety review (PR #40): ACL copy failure must
    # roll back the component (not continue extraction with only inherited
    # permissions). Structural: throw replaces silent WARNING+continue, and
    # flows into the SAME catch that already performs Undo-BRAVODataRestoreMoveAside
    # / cross-component rollback — no new ACL-only rollback path. ----------
    Test-BRAVOCondition `
        -Condition (
            $dataRestoreRuntimeTextForTests.Contains('throw "перенесення ACL на $($planComponent.TargetDirectory) не вдалося: $($_.Exception.Message)"') -and
            -not $dataRestoreRuntimeTextForTests.Contains('Не вдалося перенести ACL на $($planComponent.TargetDirectory)')
        ) `
        -Name "DataRestore/AclCopyFailureIsComponentFailureNotWarning" `
        -Failure "провал Copy-BRAVODataRestoreDirectoryAcl для InPlace має кидати виняток (component failure), а не зводитись до WARNING із продовженням extraction у каталог лише з успадкованими правами"
    $aclThrowIndex = $dataRestoreRuntimeTextForTests.IndexOf('throw "перенесення ACL на $($planComponent.TargetDirectory) не вдалося')
    $extractionCallIndexForAcl = $dataRestoreRuntimeTextForTests.IndexOf('Invoke-BRAVOSevenZipExtraction `')
    $catchBlockIndexForAcl = $dataRestoreRuntimeTextForTests.IndexOf('$currentComponentStatus = ''FAILED''')
    Test-BRAVOCondition `
        -Condition (
            $aclThrowIndex -gt 0 -and
            $extractionCallIndexForAcl -gt $aclThrowIndex -and
            $catchBlockIndexForAcl -gt 0 -and
            $catchBlockIndexForAcl -gt $aclThrowIndex
        ) `
        -Name "DataRestore/AclCopyFailureOccursBeforeExtractionAndReusesExistingCatch" `
        -Failure "ACL copy має відбуватись ДО Invoke-BRAVOSevenZipExtraction, а throw при її провалі має потрапляти в ТОЙ САМИЙ catch, що вже виконує rollback (без окремого ACL-only rollback шляху)"

    # --- 6.10. Second restore safety review (PR #40): write-probe не має
    # створюватись усередині InPlace live-каталогу — лише в батьківському. --
    $probeTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_PROBE_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        $probeLiveParent = Join-Path $probeTestRoot 'LIVE_PARENT'
        $probeLiveDirectory = Join-Path $probeLiveParent 'MODEL'
        [void][IO.Directory]::CreateDirectory($probeLiveDirectory)
        [IO.File]::WriteAllText((Join-Path $probeLiveDirectory 'production.txt'), 'live-data')

        # Без ProbeDirectory (старий контракт / OutOfPlace) — тест лише
        # підтверджує, що явний ProbeDirectory ПЕРЕВАЖАЄ TargetDirectory.
        $probeResultWithDirective = & $dataRestoreModule {
            param($liveDir, $parentDir)
            Test-BRAVODataRestoreFreeSpace `
                -Requirements @([pscustomobject]@{ TargetDirectory = $liveDir; RequiredBytes = [long]1024; ProbeDirectory = $parentDir }) `
                -MinimumFreeGigabytes 0.001
        } $probeLiveDirectory $probeLiveParent

        $liveTreeEntriesAfterProbe = @(Get-ChildItem -LiteralPath $probeLiveDirectory -Force)
        $probeArtifactsLeftInParent = @(Get-ChildItem -LiteralPath $probeLiveParent -Filter 'BRAVO_DATA_RESTORE_PROBE_*.tmp' -File -ErrorAction SilentlyContinue)

        Test-BRAVOCondition `
            -Condition (
                $probeResultWithDirective.Success -and
                $liveTreeEntriesAfterProbe.Count -eq 1 -and
                $liveTreeEntriesAfterProbe[0].Name -eq 'production.txt' -and
                $probeArtifactsLeftInParent.Count -eq 0
            ) `
            -Name "DataRestore/FreeSpaceProbeHonorsExplicitProbeDirectoryOutsideLiveTree" `
            -Failure "коли Requirements містить ProbeDirectory, Test-BRAVODataRestoreFreeSpace має писати write-probe ТУДИ (і гарантовано прибирати його), а НЕ всередину live TargetDirectory — live-дерево має лишитись незмінним (лише production.txt)"

        Test-BRAVOCondition `
            -Condition (
                $dataRestoreRuntimeTextForTests.Contains('$requirementProbeDirectory = Split-Path -Path ([string]$planComponent.TargetDirectory) -Parent') -and
                $dataRestoreRuntimeTextForTests.Contains('if ($Mode -eq ''InPlace'') {') -and
                $dataRestoreRuntimeTextForTests.Contains('ProbeDirectory = $requirementProbeDirectory')
            ) `
            -Name "DataRestore/InPlacePreflightPassesParentAsProbeDirectory" `
            -Failure "виклик Test-BRAVODataRestoreFreeSpace для InPlace має передавати ProbeDirectory = батьківський каталог live-джерела, а не (мовчазний дефолт) сам TargetDirectory"
    } finally {
        if (Test-Path -LiteralPath $probeTestRoot) {
            Remove-Item -LiteralPath $probeTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 6.10.1. B4 acceptance defect (9257157/PHASE 3): SFTP staging
    # free-space requirement (stagingRequirements) МАЄ оголошувати
    # ProbeDirectory на кожному requirement-об'єкті. Set-StrictMode
    # успадковується від конфігураційного завантажувача (див. коментар на
    # початку Runtime.ps1) — звернення до НЕОГОЛОШЕНОЇ властивості
    # pscustomobject під StrictMode кидає PropertyNotFoundException, а не
    # мовчазно повертає $null. До фіксу stagingRequirements будувався БЕЗ
    # ProbeDirectory -> Test-BRAVODataRestoreFreeSpace падав на першому ж
    # requirement -> НЕОЧІКУВАНА ПОМИЛКА -> exit 90 ще ДО завантаження
    # staging-даних (кожен -Source SFTP restore). Тест відтворює саме цей
    # механізм на РЕАЛЬНІЙ Test-BRAVODataRestoreFreeSpace під явним
    # Set-StrictMode: без ProbeDirectory — кидає; з ProbeDirectory (навіть
    # $null, як фактично будує стейджинг-код) — проходить.
    $stagingProbeTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_STAGING_PROBE_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        [void][IO.Directory]::CreateDirectory($stagingProbeTestRoot)

        $stagingProbeMissingThrew = & $dataRestoreModule {
            param($dir)
            Set-StrictMode -Version Latest
            try {
                # Той самий "голий" літерал, який мав stagingRequirements ДО
                # фіксу — без властивості ProbeDirectory.
                $requirement = [pscustomobject]@{ TargetDirectory = $dir; RequiredBytes = [long]1024 }
                Test-BRAVODataRestoreFreeSpace -Requirements @($requirement) -MinimumFreeGigabytes 0.001 | Out-Null
                return $false
            } catch [System.Management.Automation.PropertyNotFoundException] {
                return $true
            }
        } $stagingProbeTestRoot

        $stagingProbeDeclaredResult = & $dataRestoreModule {
            param($dir)
            Set-StrictMode -Version Latest
            # Та сама форма, яку зараз (після фіксу) реально будує SFTP
            # staging-preflight: ProbeDirectory явно оголошено як $null
            # (staging-каталог — не live production-джерело, walk-up до
            # найближчого наявного батьківського каталогу лишається у силі).
            $requirement = [pscustomobject]@{ TargetDirectory = $dir; RequiredBytes = [long]1024; ProbeDirectory = $null }
            Test-BRAVODataRestoreFreeSpace -Requirements @($requirement) -MinimumFreeGigabytes 0.001
        } $stagingProbeTestRoot

        Test-BRAVOCondition `
            -Condition (
                $stagingProbeMissingThrew -and
                $stagingProbeDeclaredResult.Success -and
                $dataRestoreRuntimeTextForTests.Contains('$stagingRequirements += [pscustomobject]@{') -and
                $dataRestoreRuntimeTextForTests.Contains('ProbeDirectory = $null')
            ) `
            -Name "DataRestore/SftpStagingFreeSpaceRequirementDeclaresProbeDirectory" `
            -Failure "SFTP staging free-space requirement (stagingRequirements) МАЄ оголошувати ProbeDirectory (навіть `$null) на кожному об'єкті — під успадкованим Set-StrictMode звернення до неоголошеної властивості кидає PropertyNotFoundException -> InternalError exit 90 ще ДО завантаження staging-даних (regression B4, 9257157 PHASE 3 acceptance)"
    } finally {
        if (Test-Path -LiteralPath $stagingProbeTestRoot) {
            Remove-Item -LiteralPath $stagingProbeTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 6.11. Second restore safety review (PR #40): WinSCP-скрипт
    # DataRestore тепер створюється через canonical New-BRAVOWinSCPTemporaryScriptPath
    # (protected DACL з моменту створення), а прибирається через
    # Remove-BRAVOWinSCPSensitiveTemporaryScript — не raw WriteAllLines/Remove-Item. --
    Test-BRAVOCondition `
        -Condition (
            $dataRestoreRuntimeTextForTests.Contains('$temporaryScriptPath = New-BRAVOWinSCPTemporaryScriptPath') -and
            $dataRestoreRuntimeTextForTests.Contains('Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $temporaryScriptPath') -and
            -not $dataRestoreRuntimeTextForTests.Contains('$temporaryScriptPath = Join-Path $temporaryRoot "$temporaryName.txt"')
        ) `
        -Name "DataRestore/WinSCPScriptUsesProtectedCanonicalCreation" `
        -Failure "Invoke-BRAVODataRestoreWinSCPScript має створювати командний файл (містить SFTP URL з обліковими даними) через canonical New-BRAVOWinSCPTemporaryScriptPath (BRAVO.ArchiveRuntime, той самий helper, що Archive) — не через звичайний Join-Path+WriteAllLines у потенційно широкодоступному temp-каталозі"
    Test-BRAVOCondition `
        -Condition (
            $archiveRuntimeModuleText.Contains('function New-BRAVOWinSCPTemporaryScriptPath') -and
            $archiveRuntimeModuleText.Contains('function Remove-BRAVOWinSCPSensitiveTemporaryScript') -and
            $archiveRuntimeModuleText.Contains('function Clear-BRAVOStaleWinSCPSensitiveTemporaryScripts') -and
            -not $archiveScriptText.Contains('function New-BRAVOWinSCPTemporaryScriptPath')
        ) `
        -Name "DataRestore/ProtectedWinSCPScriptCreationIsCanonicalSharedOwner" `
        -Failure "protected WinSCP script creation має мати ОДНУ canonical реалізацію в BRAVO.ArchiveRuntime (спільній для Archive і DataRestore), а не окрему копію в Archive.Runtime.ps1"

    $dataRestoreImportsArchiveRuntime = $dataRestoreRuntimeTextForTests -match "'BRAVO\.ArchiveRuntime'"
    Test-BRAVOCondition `
        -Condition ([bool]$dataRestoreImportsArchiveRuntime) `
        -Name "DataRestore/ImportsArchiveRuntimeForSharedWinSCPScriptHelper" `
        -Failure "BRAVO.DataRestore.Runtime.ps1 має імпортувати BRAVO.ArchiveRuntime, щоб мати доступ до canonical New-BRAVOWinSCPTemporaryScriptPath/Remove-BRAVOWinSCPSensitiveTemporaryScript"

    # --- 6.12. Second restore safety review (PR #40): служби мають
    # лишатись зупиненими, якщо rollback (поточного компонента або раніше
    # завершених) не гарантовано довершився. Structural: явний прапорець
    # виставляється у ROZNI відповідних точках і гейтить фінальний finally. --
    Test-BRAVOCondition `
        -Condition (
            $dataRestoreRuntimeTextForTests.Contains('$script:dataRestoreRollbackIncomplete = $false') -and
            $dataRestoreRuntimeTextForTests.Contains('if ($script:dataRestoreRollbackIncomplete) {') -and
            $dataRestoreRuntimeTextForTests.Contains('} elseif ($script:dataRestoreServicesStopped -and $null -ne $script:dataRestoreServiceSnapshot) {')
        ) `
        -Name "DataRestore/RollbackIncompleteFlagGatesServiceRestoration" `
        -Failure "фінальний finally має пропускати Restore-BRAVODataRestoreServices, коли `$script:dataRestoreRollbackIncomplete=true (elseif, не окрема безумовна гілка) — інакше служби можуть піднятись поверх невизначеного стану filesystem"
    $rollbackIncompleteSetCount = @([regex]::Matches($dataRestoreRuntimeTextForTests, '\$script:dataRestoreRollbackIncomplete = \$true')).Count
    Test-BRAVOCondition `
        -Condition ($rollbackIncompleteSetCount -eq 2) `
        -Name "DataRestore/RollbackIncompleteFlagSetOnBothCurrentAndCrossRollbackFailure" `
        -Failure "`$script:dataRestoreRollbackIncomplete має виставлятись РІВНО у двох місцях: провал rollback поточного компонента і провал крос-компонентного rollback"

    # --- 6.13. Second restore safety review (PR #40): -ListGenerations не
    # має вимагати 7za.exe (лише WinSCP для SFTP-лістингу, якщо взагалі). ---
    Test-BRAVOCondition `
        -Condition (
            $dataRestoreRuntimeTextForTests.Contains('$requiredTools = @()') -and
            $dataRestoreRuntimeTextForTests.Contains('if (-not $ListGenerations) { $requiredTools += ''7za.exe'' }') -and
            $dataRestoreRuntimeTextForTests.Contains("if (`$Source -eq 'SFTP') { `$requiredTools += 'WinSCP.com' }")
        ) `
        -Name "DataRestore/ListGenerationsDoesNotRequireSevenZip" `
        -Failure "required tools мають похідати з фактичної операції: -ListGenerations (Local або SFTP) ніколи не має вимагати 7za.exe; лише реальне відновлення (не -ListGenerations) додає 7za.exe, а SFTP окремо додає WinSCP.com"

    # --- 6.13b. DEV-LIMS acceptance defect (5.1.0-rc.2, exit 90): для
    # -ListGenerations -Source Local $requiredTools legitimately обчислюється
    # як порожній масив (див. 6.13 вище), але Test-BRAVODataRestoreToolIntegrity
    # мала [Parameter(Mandatory=$true)][string[]]$ToolNames БЕЗ
    # AllowEmptyCollection() — PowerShell 5.1 відхиляє порожній масив, поданий
    # у mandatory-параметр, як "значення не надано", що падало з
    # ParameterBindingException ще ДО Enter-BRAVODataRestoreOperationLock
    # (canonical InternalError, exit 90). Той самий контракт
    # [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] вже
    # використовується у цьому файлі для ManifestNames/CompletedComponents/
    # Failures — тепер ToolNames узгоджений з ними. ---------------------------
    Test-BRAVOCondition `
        -Condition (
            $dataRestoreRuntimeTextForTests.Contains('function Test-BRAVODataRestoreToolIntegrity {') -and
            $dataRestoreRuntimeTextForTests.Contains('param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ToolNames)')
        ) `
        -Name "DataRestore/ToolIntegrityAllowsEmptyToolSet" `
        -Failure 'Test-BRAVODataRestoreToolIntegrity -ToolNames $ToolNames мусить мати [AllowEmptyCollection()] — для -ListGenerations -Source Local $requiredTools=@() є легітимним, задокументованим (не помилковим) входом; без цього атрибута PowerShell 5.1 відхиляє порожній масив у mandatory string[]-параметрі й canonical B1 (-ListGenerations) завершується exit 90 ще до захоплення operation lock'

    # --- 6.14. Third restore safety review (PR #40): SFTP ls-лістинг має
    # бути fail-closed (Success=true журналу WinSCP не гарантує, що сама
    # ls-операція успішна — той самий контракт, що вже перевіряється для
    # download). ------------------------------------------------------------
    function New-BRAVOSelfTestWinSCPListingXml {
        param([bool]$Success, [string[]]$FileNames)
        $namespaceUri = 'http://winscp.net/schema/session/1.0'
        $xmlDocument = New-Object System.Xml.XmlDocument
        $sessionNode = $xmlDocument.CreateElement('session', $namespaceUri)
        [void]$xmlDocument.AppendChild($sessionNode)
        $lsNode = $xmlDocument.CreateElement('ls', $namespaceUri)
        $resultNode = $xmlDocument.CreateElement('result', $namespaceUri)
        [void]$resultNode.SetAttribute('success', $(if ($Success) { 'true' } else { 'false' }))
        [void]$lsNode.AppendChild($resultNode)
        $filesNode = $xmlDocument.CreateElement('files', $namespaceUri)
        foreach ($fileName in @($FileNames)) {
            $fileNode = $xmlDocument.CreateElement('file', $namespaceUri)
            $filenameNode = $xmlDocument.CreateElement('filename', $namespaceUri)
            [void]$filenameNode.SetAttribute('value', $fileName)
            [void]$fileNode.AppendChild($filenameNode)
            [void]$filesNode.AppendChild($fileNode)
        }
        [void]$lsNode.AppendChild($filesNode)
        [void]$sessionNode.AppendChild($lsNode)
        return $xmlDocument
    }
    $listingSucceededTrue = & $dataRestoreModule {
        param($xml) Test-BRAVODataRestoreWinSCPListingSucceeded -Xml $xml
    } (New-BRAVOSelfTestWinSCPListingXml -Success $true -FileNames @('BRAVO_BACKUP_20260815_120000.json'))
    $listingSucceededFalse = & $dataRestoreModule {
        param($xml) Test-BRAVODataRestoreWinSCPListingSucceeded -Xml $xml
    } (New-BRAVOSelfTestWinSCPListingXml -Success $false -FileNames @('BRAVO_BACKUP_20260814_090000.json'))
    $listingSucceededNoXml = & $dataRestoreModule {
        Test-BRAVODataRestoreWinSCPListingSucceeded -Xml $null
    }
    Test-BRAVOCondition `
        -Condition ($listingSucceededTrue -eq $true -and $listingSucceededFalse -eq $false -and $listingSucceededNoXml -eq $false) `
        -Name "DataRestore/WinSCPListingSuccessIsValidatedFailClosed" `
        -Failure "Test-BRAVODataRestoreWinSCPListingSucceeded має повертати true лише коли XML-журнал МІСТИТЬ ls-результат із success=true; відсутній Xml або result success=false мають fail-closed повертати false"

    Test-BRAVOCondition `
        -Condition (
            $dataRestoreRuntimeTextForTests.Contains('if (-not (Test-BRAVODataRestoreWinSCPListingSucceeded -Xml $listingSession.Xml)) {') -and
            ($dataRestoreRuntimeTextForTests.IndexOf('if (-not (Test-BRAVODataRestoreWinSCPListingSucceeded -Xml $listingSession.Xml)) {') -lt
                $dataRestoreRuntimeTextForTests.IndexOf('Get-BRAVODataRestoreWinSCPListingNames -Xml $listingSession.Xml |'))
        ) `
        -Name "DataRestore/SftpManifestFetchValidatesListingBeforeUsingNames" `
        -Failure "Invoke-BRAVODataRestoreSftpManifestFetch має перевіряти Test-BRAVODataRestoreWinSCPListingSucceeded ПЕРЕД використанням Get-BRAVODataRestoreWinSCPListingNames — інакше перерваний/частковий лістинг може мовчазно приховати найновіші manifest-и"

    # Наскрізний behavioral-тест: ls result success=false, файли в XML
    # ПРИСУТНІ (частковий лістинг) -> реальна Invoke-BRAVODataRestoreSftpManifestFetch
    # має fail-closed кинути виняток, а не мовчазно продовжити з неповним списком.
    $lsFailClosedTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_LS_FAILCLOSED_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        [void][IO.Directory]::CreateDirectory($lsFailClosedTestRoot)
        $lsFailClosedThrew = $false
        try {
            [void](& $sftpFetchModule {
                param($dir)
                $script:sftpDirectories = @{ Manifest = '/remote/manifests' }
                $script:BRAVOSelfTestSftpListingSucceeded = $false
                $script:BRAVOSelfTestSftpListingNames = @('BRAVO_BACKUP_20260814_090000.json')
                $script:BRAVOSelfTestSftpManifestContent = @{}
                Invoke-BRAVODataRestoreSftpManifestFetch -StagingManifestDirectory $dir -RequestedGenerationId $null
            } $lsFailClosedTestRoot)
        } catch {
            $lsFailClosedThrew = $true
        }
        Test-BRAVOCondition `
            -Condition $lsFailClosedThrew `
            -Name "DataRestore/SftpManifestFetchThrowsOnUnsuccessfulListing" `
            -Failure "коли XML-журнал WinSCP позначає саму ls-операцію як неуспішну (result success=false), навіть якщо в журналі є частковий список файлів, Invoke-BRAVODataRestoreSftpManifestFetch має fail-closed кинути виняток, а не обирати generation з неповного переліку"
    } finally {
        if (Test-Path -LiteralPath $lsFailClosedTestRoot) {
            Remove-Item -LiteralPath $lsFailClosedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        # $sftpFetchModule — той самий екземпляр модуля переперевикористовується
        # нижче; його script-scope стан (BRAVOSelfTestSftpListingSucceeded)
        # переживає між викликами `& $sftpFetchModule { ... }` — скинути явно,
        # щоб не протекти false у наступні тести цього модуля.
        [void](& $sftpFetchModule { $script:BRAVOSelfTestSftpListingSucceeded = $true })
    }

    # --- 6.15. Third restore safety review (PR #40): числове (не
    # лексикографічне) сортування collision-suffix при виборі SFTP backup-ів. --
    $sortKey9 = & $dataRestoreModule { Get-BRAVODataRestoreGenerationIdSortKey -GenerationId '20260815_120000_9' }
    $sortKey10 = & $dataRestoreModule { Get-BRAVODataRestoreGenerationIdSortKey -GenerationId '20260815_120000_10' }
    $sortKeyNoSuffix = & $dataRestoreModule { Get-BRAVODataRestoreGenerationIdSortKey -GenerationId '20260815_120000' }
    Test-BRAVOCondition `
        -Condition (
            $sortKey9.Timestamp -eq $sortKey10.Timestamp -and
            $sortKey9.Suffix -eq 9 -and $sortKey10.Suffix -eq 10 -and
            $sortKeyNoSuffix.Suffix -eq 0
        ) `
        -Name "DataRestore/GenerationIdSortKeyParsesTimestampAndNumericSuffix" `
        -Failure "Get-BRAVODataRestoreGenerationIdSortKey має розбирати timestamp окремо від suffix (числовий int, 0 за замовчуванням без suffix), а не порівнювати рядок"

    # --- 6.19c. Fourth restore safety review (PR #40): collision-suffix
    # ПОЗА Int32-діапазоном (недовірене SFTP-ім'я) не повинен валити ані
    # формат-валідацію, ані sort-key необробленим OverflowException. ------
    $genIdFormatSuffixMax = & $dataRestoreModule { Test-BRAVODataRestoreGenerationIdFormat -GenerationId '20260815_120000_2147483647' }
    $genIdFormatSuffixOverflow = & $dataRestoreModule { Test-BRAVODataRestoreGenerationIdFormat -GenerationId '20260815_120000_2147483648' }
    $genIdFormatSuffixHugeOverflow = & $dataRestoreModule { Test-BRAVODataRestoreGenerationIdFormat -GenerationId '20260815_120000_999999999999999999999' }
    $sortKeyOverflowThrew = $false
    $sortKeyOverflow = $null
    try {
        $sortKeyOverflow = & $dataRestoreModule { Get-BRAVODataRestoreGenerationIdSortKey -GenerationId '20260815_120000_2147483648' }
    } catch { $sortKeyOverflowThrew = $true }
    Test-BRAVOCondition `
        -Condition (
            $genIdFormatSuffixMax -eq $true -and
            $genIdFormatSuffixOverflow -eq $false -and
            $genIdFormatSuffixHugeOverflow -eq $false -and
            -not $sortKeyOverflowThrew -and $null -ne $sortKeyOverflow -and
            $sortKeyOverflow.Timestamp -eq [datetime]::MinValue -and $sortKeyOverflow.Suffix -eq 0
        ) `
        -Name "DataRestore/GenerationIdSuffixOverflowNeverThrows" `
        -Failure "Test-BRAVODataRestoreGenerationIdFormat має приймати suffix у межах Int32 (напр. 2147483647) і відхиляти будь-який суфікс поза цим діапазоном як недопустимий формат; Get-BRAVODataRestoreGenerationIdSortKey не повинен кидати OverflowException навіть при виклику напряму з недовіреним suffix — некоректний формат трактується як найстаріший ключ, а не crash"

    # --- 6.19d. Fourth restore safety review (PR #40): недовірений
    # component.ArchiveSize (SFTP manifest) — відсутнє/нульове/від'ємне/
    # нечислове значення відхиляється ДО участі в free-space preflight. ----
    $archiveSizeValidBytes = [long]0
    $archiveSizeValidOk = & $dataRestoreModule {
        param($value, [ref]$out)
        Test-BRAVODataRestoreArchiveSize -Value $value -ValidatedBytes $out
    } 123456789 ([ref]$archiveSizeValidBytes)
    $archiveSizeMissingBytes = [long]0
    $archiveSizeMissingOk = & $dataRestoreModule {
        param($value, [ref]$out)
        Test-BRAVODataRestoreArchiveSize -Value $value -ValidatedBytes $out
    } $null ([ref]$archiveSizeMissingBytes)
    $archiveSizeZeroBytes = [long]0
    $archiveSizeZeroOk = & $dataRestoreModule {
        param($value, [ref]$out)
        Test-BRAVODataRestoreArchiveSize -Value $value -ValidatedBytes $out
    } 0 ([ref]$archiveSizeZeroBytes)
    $archiveSizeNegativeBytes = [long]0
    $archiveSizeNegativeOk = & $dataRestoreModule {
        param($value, [ref]$out)
        Test-BRAVODataRestoreArchiveSize -Value $value -ValidatedBytes $out
    } (-1) ([ref]$archiveSizeNegativeBytes)
    $archiveSizeNonNumericBytes = [long]0
    $archiveSizeNonNumericOk = & $dataRestoreModule {
        param($value, [ref]$out)
        Test-BRAVODataRestoreArchiveSize -Value $value -ValidatedBytes $out
    } 'not-a-number' ([ref]$archiveSizeNonNumericBytes)
    Test-BRAVOCondition `
        -Condition (
            $archiveSizeValidOk -eq $true -and $archiveSizeValidBytes -eq 123456789 -and
            $archiveSizeMissingOk -eq $false -and $archiveSizeMissingBytes -eq 0 -and
            $archiveSizeZeroOk -eq $false -and $archiveSizeZeroBytes -eq 0 -and
            $archiveSizeNegativeOk -eq $false -and $archiveSizeNegativeBytes -eq 0 -and
            $archiveSizeNonNumericOk -eq $false -and $archiveSizeNonNumericBytes -eq 0
        ) `
        -Name "DataRestore/ArchiveSizeValidationRejectsUntrustedValues" `
        -Failure "Test-BRAVODataRestoreArchiveSize має приймати лише додатне ціле; відсутнє/нульове/від'ємне/нечислове значення component.ArchiveSize (недовірений SFTP manifest) має відхилятись ДО участі у free-space preflight"

    $unorderedManifestNames = @(
        'BRAVO_BACKUP_20260815_120000_9.json',
        'BRAVO_BACKUP_20260815_120000_10.json',
        'BRAVO_BACKUP_20260815_120000_11.json',
        'BRAVO_BACKUP_20260815_120000_8.json'
    )
    $orderedManifestNames = & $dataRestoreModule {
        param($names) Sort-BRAVODataRestoreManifestNamesByGenerationDescending -ManifestNames $names
    } $unorderedManifestNames
    Test-BRAVOCondition `
        -Condition (($orderedManifestNames -join ',') -eq (
            'BRAVO_BACKUP_20260815_120000_11.json,BRAVO_BACKUP_20260815_120000_10.json,BRAVO_BACKUP_20260815_120000_9.json,BRAVO_BACKUP_20260815_120000_8.json'
        )) `
        -Name "DataRestore/ManifestNamesSortNumericallyNotLexicographically" `
        -Failure "Sort-BRAVODataRestoreManifestNamesByGenerationDescending має впорядковувати _8/_9/_10/_11 ЧИСЛОВО (11,10,9,8), а не лексикографічним рядковим порядком, де '_9' помилково йде перед '_10'"

    # Наскрізний behavioral-тест через реальну Invoke-BRAVODataRestoreSftpManifestFetch:
    # найновіший COMPLETE має ЧИСЛОВИЙ suffix 10, старший (лексикографічно
    # "більший" рядок) suffix 9 теж COMPLETE, але новіший.
    $sftpFetchTestRoot3 = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_SFTP_FETCH3_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        [void][IO.Directory]::CreateDirectory($sftpFetchTestRoot3)
        $names9 = @('BRAVO_BACKUP_20260815_120000_9.json', 'BRAVO_BACKUP_20260815_120000_10.json')
        $content9 = @{
            'BRAVO_BACKUP_20260815_120000_9.json' = (New-BRAVOSelfTestSftpManifestFixture '20260815_120000_9' 'COMPLETE')
            'BRAVO_BACKUP_20260815_120000_10.json' = (New-BRAVOSelfTestSftpManifestFixture '20260815_120000_10' 'COMPLETE')
        }
        $result9 = & $sftpFetchModule {
            param($dir, $names, $content)
            $script:sftpDirectories = @{ Manifest = '/remote/manifests' }
            $script:BRAVOSelfTestSftpListingNames = $names
            $script:BRAVOSelfTestSftpManifestContent = $content
            Invoke-BRAVODataRestoreSftpManifestFetch -StagingManifestDirectory $dir -RequestedGenerationId $null
        } $sftpFetchTestRoot3 $names9 $content9
        Test-BRAVOCondition `
            -Condition ([string]$result9.Manifest.generationId -eq '20260815_120000_10') `
            -Name "DataRestore/SftpManifestFetchSelectsNumericallyNewestCollisionSuffix" `
            -Failure "коли доступні _9 і _10 COMPLETE-manifest-и того самого timestamp, має обиратись ЧИСЛОВО новіший _10, а не '_9' (лексикографічно 'більший' рядок)"
    } finally {
        if (Test-Path -LiteralPath $sftpFetchTestRoot3) {
            Remove-Item -LiteralPath $sftpFetchTestRoot3 -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 6.16. Third restore safety review (PR #40): InPlace-план має
    # відхиляти будь-яку пару селектованих live-джерел, що збігаються чи
    # вкладені одне в одне (в будь-яку сторону), сусідні шляхи — приймати. ---
    $intersectTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_INTERSECT_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        $intersectBackupRoot = Join-Path $intersectTestRoot 'BACKUP'
        $intersectRuntimeRoot = Join-Path $intersectTestRoot 'RUNTIME'
        $intersectStagingRoot = Join-Path $intersectBackupRoot 'RESTORE_STAGING'
        foreach ($intersectDirectory in @($intersectBackupRoot, $intersectRuntimeRoot, $intersectStagingRoot)) {
            [void][IO.Directory]::CreateDirectory($intersectDirectory)
        }
        $intersectPlanInvoke = {
            param($Module, $Definitions)
            & $Module {
                param($b, $r, $s, $d)
                Get-BRAVODataRestorePlan `
                    -ComponentTypes @('MODEL', 'BLOG') `
                    -RestoreMode 'InPlace' `
                    -RequestedTargetPath '' `
                    -BackupRoot $b `
                    -RuntimeRootPath $r `
                    -StagingRoot $s `
                    -ArchiveDefinitions $d `
                    -RunStamp '20260815_130000'
            } $intersectBackupRoot $intersectRuntimeRoot $intersectStagingRoot $Definitions
        }
        # Child/parent: MODEL = C:\LIMS\MODEL (нижче), BLOG = C:\LIMS (батько).
        $intersectParentChildRoot = Join-Path $intersectTestRoot 'LIMS'
        [void][IO.Directory]::CreateDirectory((Join-Path $intersectParentChildRoot 'MODEL'))
        $childParentDefinitions = @(
            [pscustomobject]@{ Type = 'MODEL'; Source = (Join-Path $intersectParentChildRoot 'MODEL\model.gdb') },
            [pscustomobject]@{ Type = 'BLOG'; Source = (Join-Path $intersectParentChildRoot 'blog.db') }
        )
        $childParentPlan = & $intersectPlanInvoke $dataRestoreModule $childParentDefinitions

        # Точний збіг: MODEL і BLOG обидва в тому самому каталозі.
        $equalRoot = Join-Path $intersectTestRoot 'SAME'
        [void][IO.Directory]::CreateDirectory($equalRoot)
        $equalDefinitions = @(
            [pscustomobject]@{ Type = 'MODEL'; Source = (Join-Path $equalRoot 'model.gdb') },
            [pscustomobject]@{ Type = 'BLOG'; Source = (Join-Path $equalRoot 'blog.db') }
        )
        $equalPlan = & $intersectPlanInvoke $dataRestoreModule $equalDefinitions

        # Сусідні (sibling) каталоги — мають ПРОЙТИ.
        $siblingRoot = Join-Path $intersectTestRoot 'SIBLING'
        [void][IO.Directory]::CreateDirectory((Join-Path $siblingRoot 'Model'))
        [void][IO.Directory]::CreateDirectory((Join-Path $siblingRoot 'Blog'))
        $siblingDefinitions = @(
            [pscustomobject]@{ Type = 'MODEL'; Source = (Join-Path $siblingRoot 'Model\model.gdb') },
            [pscustomobject]@{ Type = 'BLOG'; Source = (Join-Path $siblingRoot 'Blog\blog.db') }
        )
        $siblingPlan = & $intersectPlanInvoke $dataRestoreModule $siblingDefinitions

        Test-BRAVOCondition `
            -Condition (
                -not $childParentPlan.Success -and
                -not $equalPlan.Success -and
                $siblingPlan.Success
            ) `
            -Name "DataRestore/InPlacePlanRejectsIntersectingComponentDirectories" `
            -Failure "Get-BRAVODataRestorePlan (InPlace) має відхиляти пару компонентів, чиї live-джерела збігаються АБО одне вкладене в інше (в будь-яку сторону) — move-aside пізнішого компонента знищив би дані раніше відновленого; сусідні (непересічні) каталоги мають прийматись"
    } finally {
        if (Test-Path -LiteralPath $intersectTestRoot) {
            Remove-Item -LiteralPath $intersectTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 6.19b. Fourth restore safety review (PR #40): коли -Component
    # обирає ЛИШЕ ОДИН компонент, InPlace-план має відхиляти перетин із
    # НЕвибраним компонентом теж — не лише з іншими вибраними. -----------
    $singleSelectIntersectRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_SINGLE_SELECT_INTERSECT_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        $singleSelectBackupRoot = Join-Path $singleSelectIntersectRoot 'BACKUP'
        $singleSelectRuntimeRoot = Join-Path $singleSelectIntersectRoot 'RUNTIME'
        $singleSelectStagingRoot = Join-Path $singleSelectBackupRoot 'RESTORE_STAGING'
        foreach ($singleSelectDirectory in @($singleSelectBackupRoot, $singleSelectRuntimeRoot, $singleSelectStagingRoot)) {
            [void][IO.Directory]::CreateDirectory($singleSelectDirectory)
        }
        $singleSelectPlanInvoke = {
            param($Module, $ComponentTypes, $Definitions)
            & $Module {
                param($b, $r, $s, $d, $c)
                Get-BRAVODataRestorePlan `
                    -ComponentTypes $c `
                    -RestoreMode 'InPlace' `
                    -RequestedTargetPath '' `
                    -BackupRoot $b `
                    -RuntimeRootPath $r `
                    -StagingRoot $s `
                    -ArchiveDefinitions $d `
                    -RunStamp '20260815_190000'
            } $singleSelectBackupRoot $singleSelectRuntimeRoot $singleSelectStagingRoot $Definitions $ComponentTypes
        }
        # MODEL (обраний, самотньо) = C:\LIMS (батько); BLOG (НЕ обраний) =
        # C:\LIMS\BLOG (дитина обраного). Discovery/ArchiveDefinitions
        # завжди містять ОБИДВА (реальна поведінка), навіть коли -Component
        # запитав лише MODEL.
        $singleSelectRoot = Join-Path $singleSelectIntersectRoot 'LIMS'
        [void][IO.Directory]::CreateDirectory((Join-Path $singleSelectRoot 'BLOG'))
        $singleSelectDefinitions = @(
            [pscustomobject]@{ Type = 'MODEL'; Source = (Join-Path $singleSelectRoot 'model.gdb') },
            [pscustomobject]@{ Type = 'BLOG'; Source = (Join-Path $singleSelectRoot 'BLOG\blog.db') }
        )
        $singleSelectModelOnlyPlan = & $singleSelectPlanInvoke $dataRestoreModule @('MODEL') $singleSelectDefinitions
        $singleSelectAllPlan = & $singleSelectPlanInvoke $dataRestoreModule @('MODEL', 'BLOG') $singleSelectDefinitions

        # Контроль: той самий -Component MODEL, але BLOG (НЕ обраний) —
        # безпечний сусідній каталог, має ПРОЙТИ.
        $singleSelectSafeRoot = Join-Path $singleSelectIntersectRoot 'SAFE'
        [void][IO.Directory]::CreateDirectory((Join-Path $singleSelectSafeRoot 'Model'))
        [void][IO.Directory]::CreateDirectory((Join-Path $singleSelectSafeRoot 'Blog'))
        $singleSelectSafeDefinitions = @(
            [pscustomobject]@{ Type = 'MODEL'; Source = (Join-Path $singleSelectSafeRoot 'Model\model.gdb') },
            [pscustomobject]@{ Type = 'BLOG'; Source = (Join-Path $singleSelectSafeRoot 'Blog\blog.db') }
        )
        $singleSelectSafePlan = & $singleSelectPlanInvoke $dataRestoreModule @('MODEL') $singleSelectSafeDefinitions

        Test-BRAVOCondition `
            -Condition (
                -not $singleSelectModelOnlyPlan.Success -and
                -not $singleSelectAllPlan.Success -and
                $singleSelectSafePlan.Success
            ) `
            -Name "DataRestore/InPlacePlanChecksSelectedComponentAgainstAllDiscoveredLiveSources" `
            -Failure "коли -Component обирає ЛИШЕ MODEL, а НЕвибраний BLOG фізично вкладений у MODEL (чи навпаки), Get-BRAVODataRestorePlan має відхиляти план так само, як при явному виборі обох — попарна перевірка лише серед ВИБРАНИХ компонентів пропустила б цей випадок; безпечний (непересічний) сусідній BLOG має й далі проходити при виборі лише MODEL"
    } finally {
        if (Test-Path -LiteralPath $singleSelectIntersectRoot) {
            Remove-Item -LiteralPath $singleSelectIntersectRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 6.19e. Fourth restore safety review (PR #40): -ListGenerations
    # -Source SFTP (окрема preview-гілка від вибору generation при
    # відновленні) має підтверджувати ls-результат через
    # Test-BRAVODataRestoreWinSCPListingSucceeded, перевіряти per-download
    # результат кожного запитаного manifest-а й не показувати запис із
    # розбіжністю filename/JSON generationId як звичайний валідний. Повний
    # інтерактивний CLI-потік не витягується за AST (не чиста функція) —
    # текстова перевірка коду, той самий підхід, що вже застосовується для
    # ACL-fatal перевірки (6.17) у цьому файлі. ---------------------------
    Test-BRAVOCondition `
        -Condition (
            $dataRestoreRuntimeTextForTests.Contains('-Commands @("ls `"$remoteManifestDirectory`"")') -and
            ($dataRestoreRuntimeTextForTests.IndexOf(
                'if (-not (Test-BRAVODataRestoreWinSCPListingSucceeded -Xml $listingSession.Xml)) {',
                $dataRestoreRuntimeTextForTests.IndexOf('SFTP-перегляд: завантажуємо до 10 найновіших')
            )) -gt 0 -and
            $dataRestoreRuntimeTextForTests.Contains('$listDownloadResults = @(Get-BRAVODataRestoreWinSCPDownloads -Xml $listDownloadSession.Xml)') -and
            $dataRestoreRuntimeTextForTests.Contains('ЗАВАНТАЖЕННЯ НЕ ПІДТВЕРДЖЕНО') -and
            $dataRestoreRuntimeTextForTests.Contains('НЕЗБІЖНІСТЬ generationId')
        ) `
        -Name "DataRestore/ListGenerationsSftpValidatesListingAndPerDownloadResults" `
        -Failure "-ListGenerations -Source SFTP має підтверджувати ls-результат через Test-BRAVODataRestoreWinSCPListingSucceeded (той самий контракт, що вже застосовується при виборі generation), перевіряти per-download результат КОЖНОГО запитаного manifest-а через Get-BRAVODataRestoreWinSCPDownloads, і не показувати manifest із розбіжністю ім'я-файлу/JSON generationId як звичайний валідний запис"

    # --- 6.17. Third restore safety review (PR #40): OutOfPlace protective
    # ACL failure має бути fatal (fail-closed), не WARNING+continue. --------
    Test-BRAVOCondition `
        -Condition (
            $dataRestoreRuntimeTextForTests.Contains('Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "захисний ACL для нового out-of-place кореня не застосовано: $aclFailureReason"') -and
            -not $dataRestoreRuntimeTextForTests.Contains('Не вдалося застосувати захисний ACL до $($restorePlan.TargetRoot)')
        ) `
        -Name "DataRestore/OutOfPlaceAclFailureIsFatalNotWarning" `
        -Failure "провал Set-BRAVODataRestoreCreatedDirectoryAcl для нового out-of-place кореня має завершувати прогін через Stop-BRAVODataRestoreRun, а не зводитись до WARNING із продовженням extraction у незахищений каталог"
    $aclAbortSetupIndex = $dataRestoreRuntimeTextForTests.IndexOf('$createdTargetRoot = $true')
    $aclAbortCleanupIndex = $dataRestoreRuntimeTextForTests.IndexOf('Remove-Item -LiteralPath $restorePlan.TargetRoot -Recurse -Force -ErrorAction Stop')
    $aclAbortStopIndex = $dataRestoreRuntimeTextForTests.IndexOf('Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "захисний ACL')
    $extractionLoopIndex = $dataRestoreRuntimeTextForTests.IndexOf('foreach ($planComponent in $restorePlan.Components) {', $aclAbortSetupIndex)
    Test-BRAVOCondition `
        -Condition (
            $aclAbortSetupIndex -gt 0 -and
            $aclAbortCleanupIndex -gt $aclAbortSetupIndex -and
            $aclAbortStopIndex -gt $aclAbortCleanupIndex -and
            $extractionLoopIndex -gt $aclAbortStopIndex
        ) `
        -Name "DataRestore/OutOfPlaceAclFailureCleansUpBeforeAbortingBeforeExtraction" `
        -Failure "при провалі захисного ACL: спершу спроба прибрати ЩОЙНО СТВОРЕНИЙ (цим прогоном) порожній корінь, потім Stop-BRAVODataRestoreRun — усе це СТРОГО до циклу відновлення компонентів (extraction не повинна викликатись)"

    # --- 6.18. Third restore safety review (PR #40): InPlace restore-target
    # має братись із canonical discovery (RestoreTargetDirectories), а не
    # лише з existence-якісного ArchiveDefinitions.Source — інакше відсутній
    # (видалений) BRAVOEXCH-каталог блокує саме той disaster-restore, що
    # мав би його відновити. -------------------------------------------------
    $missingTargetTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_MISSING_TARGET_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        $missingBackupRoot = Join-Path $missingTargetTestRoot 'BACKUP'
        $missingRuntimeRoot = Join-Path $missingTargetTestRoot 'RUNTIME'
        $missingStagingRoot = Join-Path $missingBackupRoot 'RESTORE_STAGING'
        foreach ($missingDirectory in @($missingBackupRoot, $missingRuntimeRoot, $missingStagingRoot)) {
            [void][IO.Directory]::CreateDirectory($missingDirectory)
        }
        # BRAVOEXCH фізично відсутній -> ArchiveDefinitions.Source=$null
        # (той самий existence-якісний контракт, що BRAVO.config), АЛЕ
        # canonical RestoreTargetDirectories['BRAVOEXCH'] визначений
        # (bravoDiscoveryResult.BRAVOEXCH_SOURCE) — логічна ціль ІСНУЄ, хоч
        # фізичного каталогу зараз немає.
        $missingBravoexchLogicalParent = Join-Path $missingTargetTestRoot 'LIMS'
        [void][IO.Directory]::CreateDirectory($missingBravoexchLogicalParent)
        $missingDefinitions = @(
            [pscustomobject]@{ Type = 'BRAVOEXCH'; Source = $null }
        )
        $missingRestoreTargets = @{ BRAVOEXCH = (Join-Path $missingBravoexchLogicalParent 'BRAVOEXCH') }

        $noFallbackPlan = & $dataRestoreModule {
            param($b, $r, $s, $d)
            Get-BRAVODataRestorePlan `
                -ComponentTypes @('BRAVOEXCH') `
                -RestoreMode 'InPlace' `
                -RequestedTargetPath '' `
                -BackupRoot $b `
                -RuntimeRootPath $r `
                -StagingRoot $s `
                -ArchiveDefinitions $d `
                -RunStamp '20260815_140000'
        } $missingBackupRoot $missingRuntimeRoot $missingStagingRoot $missingDefinitions

        $withFallbackPlan = & $dataRestoreModule {
            param($b, $r, $s, $d, $rt)
            Get-BRAVODataRestorePlan `
                -ComponentTypes @('BRAVOEXCH') `
                -RestoreMode 'InPlace' `
                -RequestedTargetPath '' `
                -BackupRoot $b `
                -RuntimeRootPath $r `
                -StagingRoot $s `
                -ArchiveDefinitions $d `
                -RestoreTargetDirectories $rt `
                -RunStamp '20260815_140000'
        } $missingBackupRoot $missingRuntimeRoot $missingStagingRoot $missingDefinitions $missingRestoreTargets

        Test-BRAVOCondition `
            -Condition (
                -not $noFallbackPlan.Success -and
                $withFallbackPlan.Success -and
                ([string]$withFallbackPlan.Components[0].TargetDirectory) -eq (Join-Path $missingBravoexchLogicalParent 'BRAVOEXCH') -and
                ([string]$withFallbackPlan.Components[0].PrerestoreDirectory).StartsWith((Join-Path $missingBravoexchLogicalParent 'BRAVOEXCH') + '.prerestore_')
            ) `
            -Name "DataRestore/InPlacePlanUsesCanonicalRestoreTargetWhenBackupSourceMissing" `
            -Failure "коли ArchiveDefinitions.Source відсутній (BRAVOEXCH фізично видалений — типовий disaster-restore сценарій), Get-BRAVODataRestorePlan без RestoreTargetDirectories має fail-closed відмовляти, АЛЕ з canonical RestoreTargetDirectories (bravoDiscoveryResult.BRAVOEXCH_SOURCE) — успішно побудувати план із правильним TargetDirectory/PrerestoreDirectory"
    } finally {
        if (Test-Path -LiteralPath $missingTargetTestRoot) {
            Remove-Item -LiteralPath $missingTargetTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 6.19. Third/fourth restore safety review (PR #40): verified archive
    # має бути прив'язаний до Component+generationId через canonical
    # per-component каталог (НЕ через поточне значення ArchivePrefix —
    # четверта хвиля review: ArchivePrefix ротується з часом (README.md),
    # старі архіви лишаються legitimate під СТАРИМ префіксом), і не лише до
    # integrity/SHA512. Реальний Import-Module ArchiveHelpers, синтетичні
    # артефакти на TEMP. --------------------------
    Remove-Module -Name 'BRAVO.ArchiveHelpers' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.ArchiveHelpers\BRAVO.ArchiveHelpers.psd1") -Force -ErrorAction Stop

    function New-BRAVOSelfTestVerifiedArchiveFixture {
        param([string]$Directory, [string]$ArchiveName)
        [void][IO.Directory]::CreateDirectory($Directory)
        $archivePath = Join-Path $Directory $ArchiveName
        [IO.File]::WriteAllBytes($archivePath, (New-Object byte[] 64))
        $hash = (Get-BRAVOFileHash -Path $archivePath -Algorithm SHA512).Hash.ToUpperInvariant()
        $hashPath = "$archivePath.sha512"
        [IO.File]::WriteAllText($hashPath, "$hash *$ArchiveName")
        return [pscustomobject]@{ ArchivePath = $archivePath; HashPath = $hashPath }
    }

    $bindingTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_ARCHIVE_BINDING_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        [void][IO.Directory]::CreateDirectory($bindingTestRoot)
        $modelNameTemplate = '{0}_{1}.mdz'
        $blogNameTemplate = '{0}_blog_{1}.mdz'
        $generationIdFixture = '20260815_150000'
        # Canonical per-component каталоги (аналог archiveDefinitions[Type].Destination) —
        # ЄДИНЕ джерело component identity в новій реалізації.
        $modelComponentDirectory = Join-Path $bindingTestRoot 'MODEL'
        $blogComponentDirectory = Join-Path $bindingTestRoot 'BLOG'

        # PASS: справжній MODEL-архів поточної generation у СВОЄМУ каталозі,
        # з canonical ім'ям (довільний ArchivePrefix — параметр більше не
        # впливає на результат).
        $currentPrefixFixture = 'INST'
        $correctModelName = $modelNameTemplate -f $currentPrefixFixture, $generationIdFixture
        $correctModelArtifact = New-BRAVOSelfTestVerifiedArchiveFixture -Directory $modelComponentDirectory -ArchiveName $correctModelName
        $passManifest = ConvertFrom-Json (@{
            generationId = $generationIdFixture
            components = @{
                MODEL = @{ Enabled = $true; CreateSuccess = $true; IntegritySuccess = $true; HashSuccess = $true; ArchivePath = $correctModelArtifact.ArchivePath; HashPath = $correctModelArtifact.HashPath }
            }
        } | ConvertTo-Json -Depth 5)
        $passResult = $null
        $passThrew = $false
        try {
            $passResult = Get-BRAVOVerifiedGenerationArchive -Manifest $passManifest -Component 'MODEL' -NameTemplate $modelNameTemplate -ComponentDirectory $modelComponentDirectory
        } catch { $passThrew = $true }

        # PASS (четверта хвиля review — ArchivePrefix rotation): архів
        # тієї самої generation, у ТОМУ Ж каталозі компонента, але
        # створений під СТАРИМ, ІНШИМ за поточний, префіксом — має
        # ЛИШАТИСЬ відновлюваним, бо identity більше не залежить від
        # конкретного значення ArchivePrefix.
        $rotatedPrefixFixture = 'OLDPREFIX'
        $rotatedModelName = $modelNameTemplate -f $rotatedPrefixFixture, $generationIdFixture
        $rotatedModelArtifact = New-BRAVOSelfTestVerifiedArchiveFixture -Directory (Join-Path $bindingTestRoot 'MODEL_rotated') -ArchiveName $rotatedModelName
        # Той самий canonical каталог компонента, лише інша generation-тека
        # (ізольований тимчасовий каталог заради чистоти фікстури) — ключове:
        # ComponentDirectory нижче ВКАЗУЄ саме на каталог, де фізично лежить
        # цей ротований архів, так само як реальний Destination завжди
        # вказує на каталог компонента незалежно від того, під яким
        # ArchivePrefix у ньому історично накопичувались архіви.
        $rotatedManifest = ConvertFrom-Json (@{
            generationId = $generationIdFixture
            components = @{
                MODEL = @{ Enabled = $true; CreateSuccess = $true; IntegritySuccess = $true; HashSuccess = $true; ArchivePath = $rotatedModelArtifact.ArchivePath; HashPath = $rotatedModelArtifact.HashPath }
            }
        } | ConvertTo-Json -Depth 5)
        $rotatedResult = $null
        $rotatedThrew = $false
        try {
            $rotatedResult = Get-BRAVOVerifiedGenerationArchive -Manifest $rotatedManifest -Component 'MODEL' -NameTemplate $modelNameTemplate -ComponentDirectory (Join-Path $bindingTestRoot 'MODEL_rotated')
        } catch { $rotatedThrew = $true }

        # REJECT: MODEL-запис вказує на реальний, криптографічно валідний
        # BLOG-артефакт (та узгоджений sidecar) тієї самої generation, що
        # фізично лежить у СВОЄМУ (BLOG) каталозі — не в canonical
        # каталозі MODEL, переданому як ComponentDirectory.
        $substitutedBlogName = $blogNameTemplate -f $currentPrefixFixture, $generationIdFixture
        $substitutedBlogArtifact = New-BRAVOSelfTestVerifiedArchiveFixture -Directory $blogComponentDirectory -ArchiveName $substitutedBlogName
        $substitutedManifest = ConvertFrom-Json (@{
            generationId = $generationIdFixture
            components = @{
                MODEL = @{ Enabled = $true; CreateSuccess = $true; IntegritySuccess = $true; HashSuccess = $true; ArchivePath = $substitutedBlogArtifact.ArchivePath; HashPath = $substitutedBlogArtifact.HashPath }
            }
        } | ConvertTo-Json -Depth 5)
        $substitutedThrew = $false
        try {
            [void](Get-BRAVOVerifiedGenerationArchive -Manifest $substitutedManifest -Component 'MODEL' -NameTemplate $modelNameTemplate -ComponentDirectory $modelComponentDirectory)
        } catch { $substitutedThrew = $true }

        # REJECT: валідний MODEL-артефакт у СВОЄМУ каталозі, але ІНШОЇ
        # generation.
        $wrongGenerationId = '20260810_000000'
        $wrongGenerationName = $modelNameTemplate -f $currentPrefixFixture, $wrongGenerationId
        $wrongGenerationArtifact = New-BRAVOSelfTestVerifiedArchiveFixture -Directory $modelComponentDirectory -ArchiveName $wrongGenerationName
        $wrongGenerationManifest = ConvertFrom-Json (@{
            generationId = $generationIdFixture
            components = @{
                MODEL = @{ Enabled = $true; CreateSuccess = $true; IntegritySuccess = $true; HashSuccess = $true; ArchivePath = $wrongGenerationArtifact.ArchivePath; HashPath = $wrongGenerationArtifact.HashPath }
            }
        } | ConvertTo-Json -Depth 5)
        $wrongGenerationThrew = $false
        try {
            [void](Get-BRAVOVerifiedGenerationArchive -Manifest $wrongGenerationManifest -Component 'MODEL' -NameTemplate $modelNameTemplate -ComponentDirectory $modelComponentDirectory)
        } catch { $wrongGenerationThrew = $true }

        Test-BRAVOCondition `
            -Condition (
                -not $passThrew -and $null -ne $passResult -and ([string]$passResult.Name) -eq $correctModelName -and
                -not $rotatedThrew -and $null -ne $rotatedResult -and ([string]$rotatedResult.Name) -eq $rotatedModelName -and
                $substitutedThrew -and
                $wrongGenerationThrew
            ) `
            -Name "DataRestore/VerifiedArchiveBoundToComponentAndGeneration" `
            -Failure "Get-BRAVOVerifiedGenerationArchive має приймати лише артефакт, що фізично лежить у canonical каталозі запитаного Component і чиє ім'я закінчується суфіксом Manifest.generationId — правильний MODEL (будь-яким ArchivePrefix, у т.ч. відмінним від поточного — ротація префіксу) проходить; криптографічно валідний, але ПІДСТАВЛЕНИЙ BLOG-артефакт (лежить у СВОЄМУ каталозі, не в MODEL) і валідний MODEL-артефакт ІНШОЇ generation мають відхилятись, навіть попри коректний SHA512/sidecar"
    } finally {
        Remove-Module -Name 'BRAVO.ArchiveHelpers' -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $bindingTestRoot) {
            Remove-Item -LiteralPath $bindingTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # ================================================================
    # Fifth restore safety review (PR #40): 5 нових findings (1 P1, 4 P2)
    # понад попередні 25. Усі тести нижче — детерміновані, ізольовані
    # (temp-дерева, реальні production-функції через AST-екстракцію того
    # самого $dataRestoreModule; служби симулюються стаб-функціями, що
    # затінюють Get-Service/Stop-Service/Start-Service лише всередині
    # модуля — жодна реальна служба/UAC/SFTP не використовується).
    # ================================================================

    # --- 6.20a. Staging-preflight МУСИТЬ відхиляти -StagingPath, що
    # перетинається з live MODEL/BLOG/BRAVOEXCH, ДО будь-якого SFTP
    # filesystem-запису; типовий staging усередині BackupRoot має
    # проходити. -----------------------------------------------------
    $stagingSafetyTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_STAGING_SAFETY_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        $stagingSafetyBackupRoot = Join-Path $stagingSafetyTestRoot 'BACKUP'
        $stagingSafetyRuntimeRoot = Join-Path $stagingSafetyTestRoot 'RUNTIME'
        $stagingSafetyModel = Join-Path $stagingSafetyTestRoot 'LIVE\MODEL'
        $stagingSafetyBlog = Join-Path $stagingSafetyTestRoot 'LIVE\BLOG'
        $stagingSafetyBravoexch = Join-Path $stagingSafetyTestRoot 'LIVE\BRAVOEXCH'
        foreach ($stagingSafetyDirectory in @($stagingSafetyBackupRoot, $stagingSafetyRuntimeRoot, $stagingSafetyModel, $stagingSafetyBlog, $stagingSafetyBravoexch)) {
            [void][IO.Directory]::CreateDirectory($stagingSafetyDirectory)
        }
        $stagingSafetyLiveSources = @{
            MODEL = $stagingSafetyModel
            BLOG = $stagingSafetyBlog
            BRAVOEXCH = $stagingSafetyBravoexch
        }
        $stagingSafetyInvoke = {
            param($Module, $Staging, $Runtime, $LiveSources)
            & $Module {
                param($s, $r, $l)
                Test-BRAVODataRestoreStagingSafe -StagingRoot $s -RuntimeRootPath $r -LiveSources $l
            } $Staging $Runtime $LiveSources
        }
        $stagingEqualsModel = & $stagingSafetyInvoke $dataRestoreModule $stagingSafetyModel $stagingSafetyRuntimeRoot $stagingSafetyLiveSources
        $stagingInsideBlog = & $stagingSafetyInvoke $dataRestoreModule (Join-Path $stagingSafetyBlog 'sub') $stagingSafetyRuntimeRoot $stagingSafetyLiveSources
        $stagingParentOfBravoexch = & $stagingSafetyInvoke $dataRestoreModule (Split-Path $stagingSafetyBravoexch -Parent) $stagingSafetyRuntimeRoot $stagingSafetyLiveSources
        $stagingSafeDefault = Join-Path $stagingSafetyBackupRoot 'RESTORE_STAGING'
        [void][IO.Directory]::CreateDirectory($stagingSafeDefault)
        $stagingSafeResult = & $stagingSafetyInvoke $dataRestoreModule $stagingSafeDefault $stagingSafetyRuntimeRoot $stagingSafetyLiveSources

        Test-BRAVOCondition `
            -Condition (
                -not $stagingEqualsModel.Success -and
                -not $stagingInsideBlog.Success -and
                -not $stagingParentOfBravoexch.Success -and
                $stagingSafeResult.Success
            ) `
            -Name "DataRestore/StagingSafetyRejectsIntersectionWithLiveSources" `
            -Failure "Test-BRAVODataRestoreStagingSafe має відхиляти -StagingPath, що дорівнює, вкладений у, чи є батьківським до будь-якого live MODEL/BLOG/BRAVOEXCH; типовий staging усередині BackupRoot\RESTORE_STAGING має прийматись"
    } finally {
        if (Test-Path -LiteralPath $stagingSafetyTestRoot) {
            Remove-Item -LiteralPath $stagingSafetyTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 6.20b. Ordering: staging-preflight МУСИТЬ виконуватись у
    # основному pipeline ДО Invoke-BRAVODataRestoreSftpManifestFetch
    # (перший SFTP filesystem-запис) — текстова перевірка порядку, той
    # самий підхід, що вже застосовується для інших pipeline-інваріантів у
    # цьому файлі. -----------------------------------------------------
    $stagingPreflightCallIndex = $dataRestoreRuntimeTextForTests.IndexOf('$stagingSafety = Test-BRAVODataRestoreStagingSafe')
    $manifestFetchCallIndex = $dataRestoreRuntimeTextForTests.IndexOf('$sftpSelected = Invoke-BRAVODataRestoreSftpManifestFetch')
    Test-BRAVOCondition `
        -Condition (
            $stagingPreflightCallIndex -gt 0 -and
            $manifestFetchCallIndex -gt $stagingPreflightCallIndex
        ) `
        -Name "DataRestore/StagingSafetyPreflightRunsBeforeSftpManifestFetch" `
        -Failure "Test-BRAVODataRestoreStagingSafe має викликатись у основному pipeline ДО Invoke-BRAVODataRestoreSftpManifestFetch — інакше зловмисний/помилковий -StagingPath міг би отримати SFTP-запис ДО перевірки перетину з live-джерелами"

    # --- 6.21a. Reparse-point (junction) alias не повинен обходити
    # перевірку live-джерела/StagingPath — Test-BRAVODataRestorePathHasReparseAncestor
    # має fail-closed відхиляти шлях, чий наявний предок (включно із самим
    # шляхом) є reparse-точкою; звичайний фізичний каталог без
    # reparse-предків має проходити. -----------------------------------
    $reparseTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_REPARSE_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        $reparseLiveBlog = Join-Path $reparseTestRoot 'LIVE\BLOG'
        $reparseSafeParent = Join-Path $reparseTestRoot 'SAFE'
        [void][IO.Directory]::CreateDirectory($reparseLiveBlog)
        [void][IO.Directory]::CreateDirectory($reparseSafeParent)
        $reparseDirectLink = Join-Path $reparseTestRoot 'DIRECT_LINK'
        [void](New-Item -ItemType Junction -Path $reparseDirectLink -Target $reparseLiveBlog -ErrorAction Stop)
        $reparseParentLink = Join-Path $reparseTestRoot 'PARENT_LINK'
        [void](New-Item -ItemType Junction -Path $reparseParentLink -Target (Join-Path $reparseTestRoot 'LIVE') -ErrorAction Stop)

        $reparseInvoke = {
            param($Module, $Path)
            & $Module { param($p) Test-BRAVODataRestorePathHasReparseAncestor -Path $p } $Path
        }
        $reparseDirectResult = & $reparseInvoke $dataRestoreModule $reparseDirectLink
        $reparseChildOfDirectResult = & $reparseInvoke $dataRestoreModule (Join-Path $reparseDirectLink 'NEW')
        $reparseChildOfParentLinkResult = & $reparseInvoke $dataRestoreModule (Join-Path $reparseParentLink 'BLOG\NEW')
        $reparseSafeChildResult = & $reparseInvoke $dataRestoreModule (Join-Path $reparseSafeParent 'NEW')
        $reparseMalformedResult = & $reparseInvoke $dataRestoreModule "C:\`0invalid"

        Test-BRAVOCondition `
            -Condition (
                $reparseDirectResult -eq $true -and
                $reparseChildOfDirectResult -eq $true -and
                $reparseChildOfParentLinkResult -eq $true -and
                $reparseSafeChildResult -eq $false -and
                $reparseMalformedResult -eq $true
            ) `
            -Name "DataRestore/ReparseAncestorDetectionFailsClosed" `
            -Failure "Test-BRAVODataRestorePathHasReparseAncestor має fail-closed відхиляти (true) сам junction, дитину під ним, дитину під junction-предком і некоректний шлях; звичайний фізичний каталог без reparse-предків має проходити (false)"

        # --- 6.21b. Інтеграція: OutOfPlace -TargetPath, що є junction-
        # аліасом на live BLOG, має відхилятись планом — лексична
        # перевірка (GetFullPath) не бачить фізичної цілі. -------------
        $reparsePlanInvoke = {
            param($Module, $Target, $Definitions, $Backup, $Runtime, $Staging)
            & $Module {
                param($t, $d, $b, $r, $s)
                Get-BRAVODataRestorePlan `
                    -ComponentTypes @('BLOG') `
                    -RestoreMode 'OutOfPlace' `
                    -RequestedTargetPath $t `
                    -BackupRoot $b `
                    -RuntimeRootPath $r `
                    -StagingRoot $s `
                    -ArchiveDefinitions $d `
                    -RunStamp '20260816_090000'
            } $Target $Definitions $Backup $Runtime $Staging
        }
        $reparsePlanBackup = Join-Path $reparseTestRoot 'BACKUP'
        $reparsePlanRuntime = Join-Path $reparseTestRoot 'RUNTIME'
        $reparsePlanStaging = Join-Path $reparsePlanBackup 'RESTORE_STAGING'
        foreach ($reparsePlanDirectory in @($reparsePlanBackup, $reparsePlanRuntime, $reparsePlanStaging)) {
            [void][IO.Directory]::CreateDirectory($reparsePlanDirectory)
        }
        $reparsePlanDefinitions = @(
            [pscustomobject]@{ Type = 'BLOG'; Source = (Join-Path $reparseLiveBlog 'blog.db') }
        )
        $reparsePlanResult = & $reparsePlanInvoke $dataRestoreModule $reparseDirectLink $reparsePlanDefinitions $reparsePlanBackup $reparsePlanRuntime $reparsePlanStaging

        Test-BRAVOCondition `
            -Condition (-not $reparsePlanResult.Success) `
            -Name "DataRestore/PlanRejectsJunctionAliasedOutOfPlaceTarget" `
            -Failure "Get-BRAVODataRestorePlan (OutOfPlace) має відхиляти -TargetPath, що фізично є junction/symlink (чи має reparse-предка) — лексичне порівняння GetFullPath не бачить фізичної цілі, яка може вести всередину live production-дерева"
    } finally {
        if (Test-Path -LiteralPath $reparseTestRoot) {
            Remove-Item -LiteralPath $reparseTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 6.22. Служба, чий знімок мав WasRunning=$false (Stopped/
    # StartPending), але яка встигла перейти у нестабільний стан ДО
    # виклику зупинки (гонитва зі знімком), усе одно має бути зупинена;
    # неможливість зупинити (stuck) має провалювати
    # Stop-BRAVODataRestoreServices; фінальний бар'єр
    # Test-BRAVODataRestoreServicesAllStopped має бачити той самий
    # поточний стан. -----------------------------------------------------
    $serviceStopInvoke = {
        param($Module, $Snapshot, $StopTimeout, $PollInterval)
        & $Module {
            param($snap, $stopT, $poll)
            Stop-BRAVODataRestoreServices -Snapshot $snap -StopTimeoutSeconds $stopT -PollIntervalSeconds $poll
        } $Snapshot $StopTimeout $PollInterval
    }
    $serviceBarrierInvoke = {
        param($Module, $Snapshot)
        & $Module { param($snap) Test-BRAVODataRestoreServicesAllStopped -Snapshot $snap } $Snapshot
    }
    $serviceSetStateInvoke = {
        param($Module, $Name, $Status)
        & $Module { param($n, $st) Set-BRAVOSelfTestServiceState -Name $n -Status $st } $Name $Status
    }
    $serviceSetStuckInvoke = {
        param($Module, $Name, $Stuck)
        & $Module { param($n, $s) Set-BRAVOSelfTestServiceStuck -Name $n -Stuck $s } $Name $Stuck
    }

    # Сценарій A: WasRunning=$true (Running на знімку) -> зупиняється, як і раніше.
    [void](& $serviceSetStateInvoke $dataRestoreModule 'SVC_RUNNING' 'Running')
    $snapshotRunning = @([pscustomobject]@{ Key = 'A'; Name = 'SVC_RUNNING'; Managed = $true; WasRunning = $true; KillProcesses = @() })
    $failuresRunning = & $serviceStopInvoke $dataRestoreModule $snapshotRunning 5 1

    # Сценарій B: WasRunning=$false (Stopped на знімку), АЛЕ фактичний
    # поточний стан на момент зупинки — Running (гонитва зі знімком).
    [void](& $serviceSetStateInvoke $dataRestoreModule 'SVC_RACE' 'Running')
    $snapshotRace = @([pscustomobject]@{ Key = 'B'; Name = 'SVC_RACE'; Managed = $true; WasRunning = $false; KillProcesses = @() })
    $failuresRace = & $serviceStopInvoke $dataRestoreModule $snapshotRace 5 1
    $barrierAfterRace = & $serviceBarrierInvoke $dataRestoreModule $snapshotRace

    # Сценарій C: Managed=$true, WasRunning=$false, поточний стан уже
    # Stopped -> без помилок, бар'єр проходить.
    [void](& $serviceSetStateInvoke $dataRestoreModule 'SVC_ALREADY_STOPPED' 'Stopped')
    $snapshotAlreadyStopped = @([pscustomobject]@{ Key = 'C'; Name = 'SVC_ALREADY_STOPPED'; Managed = $true; WasRunning = $false; KillProcesses = @() })
    $failuresAlreadyStopped = & $serviceStopInvoke $dataRestoreModule $snapshotAlreadyStopped 5 1
    $barrierAlreadyStopped = & $serviceBarrierInvoke $dataRestoreModule $snapshotAlreadyStopped

    # Сценарій D: StartPending на знімку (WasRunning=$false), фактичний
    # стан StartPending і НЕ переходить у Stopped (stuck) ->
    # Stop-BRAVODataRestoreServices повертає помилку, фінальний бар'єр теж
    # бачить небезпечний стан.
    [void](& $serviceSetStateInvoke $dataRestoreModule 'SVC_STUCK' 'StartPending')
    [void](& $serviceSetStuckInvoke $dataRestoreModule 'SVC_STUCK' $true)
    $snapshotStuck = @([pscustomobject]@{ Key = 'D'; Name = 'SVC_STUCK'; Managed = $true; WasRunning = $false; KillProcesses = @() })
    $failuresStuck = & $serviceStopInvoke $dataRestoreModule $snapshotStuck 1 1
    $barrierStuck = & $serviceBarrierInvoke $dataRestoreModule $snapshotStuck

    Test-BRAVOCondition `
        -Condition (
            @($failuresRunning).Count -eq 0 -and
            @($failuresRace).Count -eq 0 -and
            @($barrierAfterRace).Count -eq 0 -and
            @($failuresAlreadyStopped).Count -eq 0 -and
            @($barrierAlreadyStopped).Count -eq 0 -and
            @($failuresStuck).Count -gt 0 -and
            @($barrierStuck).Count -gt 0
        ) `
        -Name "DataRestore/StopServicesReevaluatesCurrentStateNotSnapshotIntent" `
        -Failure "Stop-BRAVODataRestoreServices має зупиняти КОЖНУ керовану службу, чий ПОТОЧНИЙ стан відмінний від Stopped, незалежно від WasRunning знімка (гонитва зі знімком), і повертати помилку, якщо службу не вдалось перевести у Stopped; фінальний бар'єр Test-BRAVODataRestoreServicesAllStopped має відображати той самий поточний стан"

    # --- 6.23a. Елевований дочірній процес: GenerationId з впровадженим
    # перемикачем МУСИТЬ провалювати той самий канонічний
    # Test-BRAVODataRestoreGenerationIdFormat, що застосовується скрізь
    # інде — це і є перевірка "ДО елевації" з правильним значенням. -----
    $elevationGenIdInjectedForce = & $dataRestoreModule { Test-BRAVODataRestoreGenerationIdFormat -GenerationId '20260815_120000 -Force' }
    $elevationGenIdInjectedSkipHealth = & $dataRestoreModule { Test-BRAVODataRestoreGenerationIdFormat -GenerationId '20260815_120000 -SkipHealthCheck' }
    $elevationGenIdValid = & $dataRestoreModule { Test-BRAVODataRestoreGenerationIdFormat -GenerationId '20260815_120000' }
    Test-BRAVOCondition `
        -Condition (
            -not $elevationGenIdInjectedForce -and
            -not $elevationGenIdInjectedSkipHealth -and
            $elevationGenIdValid
        ) `
        -Name "DataRestore/ElevationGenerationIdInjectionRejected" `
        -Failure "GenerationId з впровадженим перемикачем ('20260815_120000 -Force' чи '...-SkipHealthCheck') має провалювати Test-BRAVODataRestoreGenerationIdFormat — той самий канонічний контракт, що застосовується ДО елевації; валідний '20260815_120000' має проходити"

    # --- 6.23b. Ordering: канонічна перевірка формату МУСИТЬ виконуватись
    # ДО побудови $elevatedArguments і Start-Process — інакше рядок уже
    # розщепив би CreateProcess дочірнього процесу до моменту перевірки. --
    $elevationValidationIndex = $dataRestoreRuntimeTextForTests.IndexOf('-not (Test-BRAVODataRestoreGenerationIdFormat -GenerationId $GenerationId)) {')
    $elevationArgumentsBuildIndex = $dataRestoreRuntimeTextForTests.IndexOf('$elevatedArguments = @(')
    $elevationStartProcessIndex = $dataRestoreRuntimeTextForTests.IndexOf('Start-Process powershell.exe -ArgumentList $elevatedArguments -Verb RunAs')
    Test-BRAVOCondition `
        -Condition (
            $elevationValidationIndex -gt 0 -and
            $elevationArgumentsBuildIndex -gt $elevationValidationIndex -and
            $elevationStartProcessIndex -gt $elevationArgumentsBuildIndex
        ) `
        -Name "DataRestore/ElevationValidatesGenerationIdBeforeBuildingArguments" `
        -Failure "-GenerationId має валідуватись Test-BRAVODataRestoreGenerationIdFormat ДО побудови `$elevatedArguments і ДО Start-Process -Verb RunAs — перевірка ПІСЛЯ елевації вже не бачить впровадженого вмісту, бо рядок уже розщепив CreateProcess дочірнього процесу"

    # --- 6.23c. ConvertTo-BRAVODataRestoreElevationArgument: кожне
    # значення стає РІВНО одним елементом командного рядка (Win32/
    # CommandLineToArgvW round-trip правило) незалежно від вмісту. -------
    $elevationArgSpace = & $dataRestoreModule { ConvertTo-BRAVODataRestoreElevationArgument -Value '20260815_120000 -Force' }
    $elevationArgPath = & $dataRestoreModule { ConvertTo-BRAVODataRestoreElevationArgument -Value 'C:\Program Files\BRAVO' }
    $elevationArgTrailingBackslash = & $dataRestoreModule { ConvertTo-BRAVODataRestoreElevationArgument -Value 'C:\Program Files\BRAVO\' }
    $elevationArgEmbeddedQuote = & $dataRestoreModule { ConvertTo-BRAVODataRestoreElevationArgument -Value 'C:\evil"desc' }
    Test-BRAVOCondition `
        -Condition (
            $elevationArgSpace -ceq '"20260815_120000 -Force"' -and
            $elevationArgPath -ceq '"C:\Program Files\BRAVO"' -and
            $elevationArgTrailingBackslash -ceq '"C:\Program Files\BRAVO\\"' -and
            $elevationArgEmbeddedQuote -ceq '"C:\evil\"desc"'
        ) `
        -Name "DataRestore/ElevationArgumentQuotingIsSingleTokenSafe" `
        -Failure "ConvertTo-BRAVODataRestoreElevationArgument має обгортати значення в лапки за Win32/CommandLineToArgvW правилом (подвоєння trailing backslash перед закриваючою лапкою, екранування вбудованих лапок) — значення з пробілом (напр. впроваджений перемикач) має ставати РІВНО одним дочірнім аргументом, а не розщеплюватись на кілька"

    # --- 6.23d. Кожне forwarded-значення (GenerationId, TargetPath,
    # StagingPath, ConfigPath, EntryScriptPath) проходить через той самий
    # канонічний ConvertTo-BRAVODataRestoreElevationArgument. -------------
    Test-BRAVOCondition `
        -Condition (
            $dataRestoreRuntimeTextForTests.Contains('(ConvertTo-BRAVODataRestoreElevationArgument -Value $EntryScriptPath)') -and
            $dataRestoreRuntimeTextForTests.Contains('(ConvertTo-BRAVODataRestoreElevationArgument -Value $GenerationId)') -and
            $dataRestoreRuntimeTextForTests.Contains('(ConvertTo-BRAVODataRestoreElevationArgument -Value $TargetPath)') -and
            $dataRestoreRuntimeTextForTests.Contains('(ConvertTo-BRAVODataRestoreElevationArgument -Value $StagingPath)') -and
            $dataRestoreRuntimeTextForTests.Contains('(ConvertTo-BRAVODataRestoreElevationArgument -Value $ConfigPath)')
        ) `
        -Name "DataRestore/ElevationForwardsEveryValueThroughCanonicalQuoting" `
        -Failure "Усі значення, що форвардяться елевованому дочірньому процесу (EntryScriptPath/GenerationId/TargetPath/StagingPath/ConfigPath), мають проходити через один канонічний ConvertTo-BRAVODataRestoreElevationArgument — без цього одне значення могло б стати кількома child-аргументами"

    # --- 6.24. MinimumFreeSpaceGB: 0/позитивне приймається;
    # від'ємне/NaN/+Inf/-Inf/непарсиме відхиляється. ----------------------
    $freeSpaceGbZero = [double]0
    $minFreeGbZeroOk = & $dataRestoreModule { param($v) $out = [double]0; $r = Test-BRAVODataRestoreMinimumFreeSpaceGB -Value $v -ValidatedGigabytes ([ref]$out); [pscustomobject]@{ Result = $r; Validated = $out } } 0
    $minFreeGbPositiveOk = & $dataRestoreModule { param($v) $out = [double]0; $r = Test-BRAVODataRestoreMinimumFreeSpaceGB -Value $v -ValidatedGigabytes ([ref]$out); [pscustomobject]@{ Result = $r; Validated = $out } } 20
    $minFreeGbNegativeRejected = & $dataRestoreModule { param($v) $out = [double]0; Test-BRAVODataRestoreMinimumFreeSpaceGB -Value $v -ValidatedGigabytes ([ref]$out) } (-100)
    $minFreeGbNaNRejected = & $dataRestoreModule { param($v) $out = [double]0; Test-BRAVODataRestoreMinimumFreeSpaceGB -Value $v -ValidatedGigabytes ([ref]$out) } ([double]::NaN)
    $minFreeGbPositiveInfinityRejected = & $dataRestoreModule { param($v) $out = [double]0; Test-BRAVODataRestoreMinimumFreeSpaceGB -Value $v -ValidatedGigabytes ([ref]$out) } ([double]::PositiveInfinity)
    $minFreeGbNegativeInfinityRejected = & $dataRestoreModule { param($v) $out = [double]0; Test-BRAVODataRestoreMinimumFreeSpaceGB -Value $v -ValidatedGigabytes ([ref]$out) } ([double]::NegativeInfinity)
    $minFreeGbUnparseableRejected = & $dataRestoreModule { param($v) $out = [double]0; Test-BRAVODataRestoreMinimumFreeSpaceGB -Value $v -ValidatedGigabytes ([ref]$out) } 'not-a-number'
    Test-BRAVOCondition `
        -Condition (
            $minFreeGbZeroOk.Result -eq $true -and $minFreeGbZeroOk.Validated -eq 0 -and
            $minFreeGbPositiveOk.Result -eq $true -and $minFreeGbPositiveOk.Validated -eq 20 -and
            -not $minFreeGbNegativeRejected -and
            -not $minFreeGbNaNRejected -and
            -not $minFreeGbPositiveInfinityRejected -and
            -not $minFreeGbNegativeInfinityRejected -and
            -not $minFreeGbUnparseableRejected
        ) `
        -Name "DataRestore/MinimumFreeSpaceGBRejectsNegativeNonFiniteValues" `
        -Failure "Test-BRAVODataRestoreMinimumFreeSpaceGB має приймати 0 і додатні значення, і відхиляти від'ємні, NaN, +Infinity, -Infinity та непарсимі значення — інакше free-space preflight міг би хибно пройти з від'ємним резервом"

    # ================================================================
    # Sixth restore safety review (PR #40): 7 нових findings (2 P1, 5 P2)
    # понад попередні 30. Усі тести нижче — детерміновані, ізольовані;
    # служби/процеси симулюються стаб-функціями всередині того самого
    # $dataRestoreModule — жодна реальна служба/процес/UAC/SFTP не
    # використовується.
    # ================================================================

    # --- 6.25a. InPlace live-джерело, що фізично є junction (чи має
    # reparse-предка), має відхилятись планом — той самий канонічний
    # Test-BRAVODataRestorePathHasReparseAncestor, що вже захищає
    # OutOfPlace/staging. -------------------------------------------------
    $inPlaceReparseTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_INPLACE_REPARSE_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        $inPlaceReparseBackupRoot = Join-Path $inPlaceReparseTestRoot 'BACKUP'
        $inPlaceReparseRuntimeRoot = Join-Path $inPlaceReparseTestRoot 'RUNTIME'
        $inPlaceReparseStagingRoot = Join-Path $inPlaceReparseBackupRoot 'RESTORE_STAGING'
        $inPlaceReparseRealBlog = Join-Path $inPlaceReparseTestRoot 'REAL\BLOG'
        $inPlaceReparseSafeModel = Join-Path $inPlaceReparseTestRoot 'SAFE\MODEL'
        foreach ($inPlaceReparseDirectory in @($inPlaceReparseBackupRoot, $inPlaceReparseRuntimeRoot, $inPlaceReparseStagingRoot, $inPlaceReparseRealBlog, $inPlaceReparseSafeModel)) {
            [void][IO.Directory]::CreateDirectory($inPlaceReparseDirectory)
        }
        $inPlaceReparseLink = Join-Path $inPlaceReparseTestRoot 'MODEL_LINK'
        [void](New-Item -ItemType Junction -Path $inPlaceReparseLink -Target $inPlaceReparseRealBlog -ErrorAction Stop)

        $inPlacePlanInvoke = {
            param($Module, $Definitions, $Backup, $Runtime, $Staging)
            & $Module {
                param($d, $b, $r, $s)
                Get-BRAVODataRestorePlan `
                    -ComponentTypes @('MODEL') `
                    -RestoreMode 'InPlace' `
                    -RequestedTargetPath '' `
                    -BackupRoot $b `
                    -RuntimeRootPath $r `
                    -StagingRoot $s `
                    -ArchiveDefinitions $d `
                    -RunStamp '20260816_100000'
            } $Definitions $Backup $Runtime $Staging
        }

        $reparseDefinitions = @([pscustomobject]@{ Type = 'MODEL'; Source = (Join-Path $inPlaceReparseLink 'model.gdb') })
        $reparsePlanResult = & $inPlacePlanInvoke $dataRestoreModule $reparseDefinitions $inPlaceReparseBackupRoot $inPlaceReparseRuntimeRoot $inPlaceReparseStagingRoot

        $safeDefinitions = @([pscustomobject]@{ Type = 'MODEL'; Source = (Join-Path $inPlaceReparseSafeModel 'model.gdb') })
        $safePlanResult = & $inPlacePlanInvoke $dataRestoreModule $safeDefinitions $inPlaceReparseBackupRoot $inPlaceReparseRuntimeRoot $inPlaceReparseStagingRoot

        Test-BRAVOCondition `
            -Condition (
                -not $reparsePlanResult.Success -and
                $safePlanResult.Success
            ) `
            -Name "DataRestore/InPlacePlanRejectsReparseAliasedLiveSource" `
            -Failure "Get-BRAVODataRestorePlan (InPlace) має відхиляти обране live-джерело, що фізично є junction/symlink (чи має reparse-предка) — лексичні Test-BRAVODataRestorePathEquals/-PathWithin не бачать, що такий шлях реально веде в інший захищений каталог; звичайне фізичне джерело має проходити"
    } finally {
        if (Test-Path -LiteralPath $inPlaceReparseTestRoot) {
            Remove-Item -LiteralPath $inPlaceReparseTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 6.25b. Ordering: staging-preflight для -ListGenerations -Source
    # SFTP МУСИТЬ виконуватись ДО створення "_list_<guid>", і той самий
    # live-source map, обчислений один раз, використовується і тут, і
    # пізніше нормальним SFTP-потоком (без дублювання виведення). ---------
    $dataRestoreStagingLiveSourcesIndex = $dataRestoreRuntimeTextForTests.IndexOf('$dataRestoreStagingLiveSources = Get-BRAVODataRestoreLiveSourceMap')
    $listModeHeaderIndex = $dataRestoreRuntimeTextForTests.IndexOf('РЕЖИМ ПЕРЕГЛЯДУ')
    $listStagingSafetyCallIndex = $dataRestoreRuntimeTextForTests.IndexOf('$listStagingSafety = Test-BRAVODataRestoreStagingSafe')
    $listStagingDirectoryCreateIndex = $dataRestoreRuntimeTextForTests.IndexOf('$listStagingDirectory = Join-Path')
    $normalStagingSafetyCallIndex = $dataRestoreRuntimeTextForTests.IndexOf('$stagingSafety = Test-BRAVODataRestoreStagingSafe')
    Test-BRAVOCondition `
        -Condition (
            $dataRestoreStagingLiveSourcesIndex -gt 0 -and
            $listModeHeaderIndex -gt $dataRestoreStagingLiveSourcesIndex -and
            $listStagingSafetyCallIndex -gt $listModeHeaderIndex -and
            $listStagingDirectoryCreateIndex -gt $listStagingSafetyCallIndex -and
            $normalStagingSafetyCallIndex -gt $listStagingDirectoryCreateIndex
        ) `
        -Name "DataRestore/ListGenerationsSftpAppliesStagingSafetyBeforeListDirectory" `
        -Failure "-ListGenerations -Source SFTP має викликати Test-BRAVODataRestoreStagingSafe ДО створення _list_<guid> — той самий live-source map (Get-BRAVODataRestoreLiveSourceMap), обчислений один раз РАНІШЕ за режим перегляду, має повторно використовуватись і нормальним SFTP restore-потоком нижче, без дублювання виведення"

    # --- 6.25c. Атомарне володіння новим OutOfPlace TargetRoot: без
    # -Force New-Item провалюється, якщо каталог з'явився паралельно —
    # $createdTargetRoot встановлюється в true ЛИШЕ після підтвердженого
    # створення, а не мовчазного прийняття чужого каталогу. ----------------
    Test-BRAVOCondition `
        -Condition (
            $dataRestoreRuntimeTextForTests.Contains('[void](New-Item -ItemType Directory -Path $restorePlan.TargetRoot -ErrorAction Stop)') -and
            -not $dataRestoreRuntimeTextForTests.Contains('New-Item -ItemType Directory -Path $restorePlan.TargetRoot -Force') -and
            $dataRestoreRuntimeTextForTests.Contains('Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "ціль out-of-place кореня з''явилася між плануванням і створенням (не створено цим прогоном)') -and
            ($dataRestoreRuntimeTextForTests.IndexOf('$createdTargetRoot = $true', $dataRestoreRuntimeTextForTests.IndexOf('[void](New-Item -ItemType Directory -Path $restorePlan.TargetRoot -ErrorAction Stop)'))) -gt 0
        ) `
        -Name "DataRestore/OutOfPlaceTargetRootCreationIsRaceSafe" `
        -Failure "Створення нового OutOfPlace TargetRoot має відбуватись БЕЗ -Force (щоб New-Item провалився, якщо каталог з'явився паралельно між Test-Path і цим викликом) і абортувати через Stop-BRAVODataRestoreRun замість мовчазного прийняття чужого каталогу як `$createdTargetRoot=true"

    # --- 6.26a. Invoke-BRAVODataRestoreQuiescence: configured KillProcesses
    # завершуються НЕЗАЛЕЖНО від того, чи пов'язана служба вже Stopped. ----
    $quiescenceSetStateInvoke = {
        param($Module, $Name, $Status)
        & $Module { param($n, $st) Set-BRAVOSelfTestServiceState -Name $n -Status $st } $Name $Status
    }
    $quiescenceSetProcessInvoke = {
        param($Module, $Name, $Running)
        & $Module { param($n, $r) Set-BRAVOSelfTestProcessRunning -Name $n -Running $r } $Name $Running
    }
    $quiescenceSetUnkillableInvoke = {
        param($Module, $Name, $Unkillable)
        & $Module { param($n, $u) Set-BRAVOSelfTestProcessUnkillable -Name $n -Unkillable $u } $Name $Unkillable
    }
    $quiescenceProcessRunningInvoke = {
        param($Module, $Name)
        & $Module { param($n) [bool](Get-Process -Name $n -ErrorAction SilentlyContinue) } $Name
    }
    $quiescenceInvoke = {
        param($Module, $Snapshot, $StopTimeout, $PollInterval)
        & $Module {
            param($snap, $stopT, $poll)
            Invoke-BRAVODataRestoreQuiescence -Snapshot $snap -StopTimeoutSeconds $stopT -PollIntervalSeconds $poll
        } $Snapshot $StopTimeout $PollInterval
    }

    # A: служба вже Stopped, orphan-процес живий -> процес завершується
    # навіть без потреби зупиняти службу.
    [void](& $quiescenceSetStateInvoke $dataRestoreModule 'SVC_Q_A' 'Stopped')
    [void](& $quiescenceSetProcessInvoke $dataRestoreModule 'Bis_Q_A' $true)
    $snapshotQA = @([pscustomobject]@{ Key = 'A'; Name = 'SVC_Q_A'; Managed = $true; WasRunning = $false; KillProcesses = @('Bis_Q_A') })
    $failuresQA = & $quiescenceInvoke $dataRestoreModule $snapshotQA 5 1
    $processStillRunningQA = & $quiescenceProcessRunningInvoke $dataRestoreModule 'Bis_Q_A'

    # B: служба Running + процес живий -> обидва приводяться в тишу.
    [void](& $quiescenceSetStateInvoke $dataRestoreModule 'SVC_Q_B' 'Running')
    [void](& $quiescenceSetProcessInvoke $dataRestoreModule 'Bis_Q_B' $true)
    $snapshotQB = @([pscustomobject]@{ Key = 'B'; Name = 'SVC_Q_B'; Managed = $true; WasRunning = $true; KillProcesses = @('Bis_Q_B') })
    $failuresQB = & $quiescenceInvoke $dataRestoreModule $snapshotQB 5 1
    $processStillRunningQB = & $quiescenceProcessRunningInvoke $dataRestoreModule 'Bis_Q_B'

    # C: процес неможливо завершити (симуляція) -> Invoke-BRAVODataRestoreQuiescence
    # має провалитись через фінальний бар'єр, навіть якщо служба в нормі.
    [void](& $quiescenceSetStateInvoke $dataRestoreModule 'SVC_Q_C' 'Stopped')
    [void](& $quiescenceSetProcessInvoke $dataRestoreModule 'Bis_Q_C' $true)
    [void](& $quiescenceSetUnkillableInvoke $dataRestoreModule 'Bis_Q_C' $true)
    $snapshotQC = @([pscustomobject]@{ Key = 'C'; Name = 'SVC_Q_C'; Managed = $true; WasRunning = $false; KillProcesses = @('Bis_Q_C') })
    $failuresQC = & $quiescenceInvoke $dataRestoreModule $snapshotQC 1 1

    Test-BRAVOCondition `
        -Condition (
            @($failuresQA).Count -eq 0 -and -not $processStillRunningQA -and
            @($failuresQB).Count -eq 0 -and -not $processStillRunningQB -and
            @($failuresQC).Count -gt 0
        ) `
        -Name "DataRestore/QuiescenceTerminatesLingeringProcessesIndependentOfServiceState" `
        -Failure "Invoke-BRAVODataRestoreQuiescence (через Stop-BRAVODataRestoreServices) має завершувати configured KillProcesses незалежно від того, чи пов'язана служба вже Stopped — orphan-процес не зникає разом зі станом 'Stopped'; процес, що неможливо завершити, має провалювати фінальний бар'єр"

    # --- 6.26b. Ordering: Invoke-BRAVODataRestoreQuiescence МУСИТЬ
    # викликатись ВСЕРЕДИНІ циклу foreach по компонентах, безпосередньо
    # перед move-aside КОЖНОГО компонента — не лише один раз перед усією
    # транзакцією. -----------------------------------------------------
    $componentForeachIndex = $dataRestoreRuntimeTextForTests.IndexOf('foreach ($planComponent in $restorePlan.Components) {')
    $perComponentQuiescenceCallIndex = $dataRestoreRuntimeTextForTests.IndexOf('$componentQuiescenceFailures = Invoke-BRAVODataRestoreQuiescence', $componentForeachIndex)
    $moveAsideCallIndexInLoop = $dataRestoreRuntimeTextForTests.IndexOf('$moveAsideResult = Invoke-BRAVODataRestoreMoveAside', $componentForeachIndex)
    Test-BRAVOCondition `
        -Condition (
            $componentForeachIndex -gt 0 -and
            $perComponentQuiescenceCallIndex -gt $componentForeachIndex -and
            $moveAsideCallIndexInLoop -gt $perComponentQuiescenceCallIndex
        ) `
        -Name "DataRestore/QuiescenceReestablishedInsideComponentLoopBeforeMoveAside" `
        -Failure "Invoke-BRAVODataRestoreQuiescence має викликатись ВСЕРЕДИНІ циклу foreach по компонентах, безпосередньо перед Invoke-BRAVODataRestoreMoveAside КОЖНОГО компонента — не лише один раз перед усією транзакцією, інакше довга MODEL-екстракція лишає вікно для перезапуску служби/процесу перед BLOG/BRAVOEXCH"

    # --- 6.27. Operation lock: провал запису метаданих (SetLength/Write/
    # Flush) має звільнити відкритий $stream ДО того, як зовнішній catch
    # поверне Success=false — інакше machine-wide lock лишився б захопленим
    # до непередбачуваного GC. -------------------------------------------
    $lockDisposeSetupIndex = $dataRestoreRuntimeTextForTests.IndexOf('Від цього моменту $stream належить ЦІЙ функції')
    $lockDisposeWriteIndex = $dataRestoreRuntimeTextForTests.IndexOf('$stream.SetLength(0)', $lockDisposeSetupIndex)
    $lockDisposeCallIndex = $dataRestoreRuntimeTextForTests.IndexOf('$stream.Dispose()', $lockDisposeWriteIndex)
    $lockDisposeSuccessReturnIndex = $dataRestoreRuntimeTextForTests.IndexOf('Success = $true', $lockDisposeCallIndex)
    Test-BRAVOCondition `
        -Condition (
            $lockDisposeSetupIndex -gt 0 -and
            $lockDisposeWriteIndex -gt $lockDisposeSetupIndex -and
            $lockDisposeCallIndex -gt $lockDisposeWriteIndex -and
            $lockDisposeSuccessReturnIndex -gt $lockDisposeCallIndex
        ) `
        -Name "DataRestore/OperationLockDisposesStreamOnMetadataWriteFailure" `
        -Failure "Enter-BRAVODataRestoreOperationLock має обгортати SetLength/Write/Flush у try/catch, що викликає `$stream.Dispose() ПЕРЕД success-return-ом (і перед виходом у зовнішній catch) — інакше провал запису метаданих лишає machine-wide lock захопленим до непередбачуваного GC"

    # --- 6.28. Local -ListGenerations не повинен показувати JSON-only
    # generationId як звичайного selectable candidate, коли filename-
    # identity не збігається — той самий контракт, що вже застосовує SFTP-
    # перегляд, через канонічний Get-BRAVOBackupManifestFilenameGenerationId
    # (BRAVO.ArchiveHelpers, без дублювання regex у DataRestore). --------
    Import-Module -Name (Join-Path $root "modules\BRAVO.ArchiveHelpers\BRAVO.ArchiveHelpers.psd1") -Force -ErrorAction Stop
    $localIdentityTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_LOCAL_IDENTITY_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        [void][IO.Directory]::CreateDirectory($localIdentityTestRoot)
        $matchName = 'BRAVO_BACKUP_20260810_100000.json'
        [IO.File]::WriteAllText(
            (Join-Path $localIdentityTestRoot $matchName),
            (@{ generationId = '20260810_100000'; status = 'COMPLETE' } | ConvertTo-Json -Compress))
        $mismatchName = 'BRAVO_BACKUP_20260811_100000.json'
        [IO.File]::WriteAllText(
            (Join-Path $localIdentityTestRoot $mismatchName),
            (@{ generationId = '20260812_999999'; status = 'COMPLETE' } | ConvertTo-Json -Compress))

        $localIdentityCandidates = @(& $dataRestoreModule {
            param($backupRoot)
            Get-BRAVODataRestoreGenerationCandidates -BackupRoot $backupRoot -Limit 25
        } $localIdentityTestRoot)

        $matchCandidate = @($localIdentityCandidates | Where-Object { [string]$_.GenerationId -eq '20260810_100000' })
        $mismatchCandidate = @($localIdentityCandidates | Where-Object { ([string]$_.GenerationId) -match 'НЕЗБІЖНІСТЬ' })

        Test-BRAVOCondition `
            -Condition (
                $matchCandidate.Count -eq 1 -and
                $mismatchCandidate.Count -eq 1 -and
                ([string]$mismatchCandidate[0].GenerationId).Contains('20260812_999999')
            ) `
            -Name "DataRestore/LocalListingFlagsFilenameJsonIdentityMismatch" `
            -Failure "Get-BRAVODataRestoreGenerationCandidates має явно позначати кандидата, чий filename generationId (канонічний Get-BRAVOBackupManifestFilenameGenerationId) не збігається з JSON generationId, а не показувати JSON-значення як звичайний selectable candidate; коректний збіг має відображатись нормально"
    } finally {
        Remove-Module -Name 'BRAVO.ArchiveHelpers' -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $localIdentityTestRoot) {
            Remove-Item -LiteralPath $localIdentityTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # ================================================================
    # Seventh restore safety review (PR #40 -> developer, post-merge round):
    # 7 нових findings (2 P1, 5 P2) понад попередні 37. Усі тести нижче —
    # детерміновані, ізольовані; служби/процеси симулюються стаб-функціями
    # всередині того самого $dataRestoreModule — жодна реальна служба/
    # процес/UAC/SFTP не використовується.
    # ================================================================

    # --- 7.1. P1: Managed-служба, яку неможливо опитати (null АБО throw),
    # МУСИТЬ трактуватись як провал тиші (fail-closed), а не мовчазний
    # "continue". ------------------------------------------------------
    $svcQueryInvoke = {
        param($Module, $Snapshot, $StopTimeout, $PollInterval)
        & $Module {
            param($snap, $stopT, $poll)
            Stop-BRAVODataRestoreServices -Snapshot $snap -StopTimeoutSeconds $stopT -PollIntervalSeconds $poll
        } $Snapshot $StopTimeout $PollInterval
    }
    $svcBarrierInvoke = {
        param($Module, $Snapshot)
        & $Module { param($snap) Test-BRAVODataRestoreServicesAllStopped -Snapshot $snap } $Snapshot
    }
    $svcQuiesceInvoke = {
        param($Module, $Snapshot, $StopTimeout, $PollInterval)
        & $Module {
            param($snap, $stopT, $poll)
            Invoke-BRAVODataRestoreQuiescence -Snapshot $snap -StopTimeoutSeconds $stopT -PollIntervalSeconds $poll
        } $Snapshot $StopTimeout $PollInterval
    }

    # A: Managed, служба взагалі невідома стабу (Get-Service -> null,
    # НІКОЛИ не викликався Set-BRAVOSelfTestServiceState) -> fail-closed.
    $snapshotUnknown = @([pscustomobject]@{ Key = 'A'; Name = 'SVC_UNKNOWN_Q7'; Managed = $true; WasRunning = $false; ShouldRestartAfterRestore = $false; KillProcesses = @() })
    $failuresUnknown = & $svcQueryInvoke $dataRestoreModule $snapshotUnknown 1 1
    $barrierUnknown = & $svcBarrierInvoke $dataRestoreModule $snapshotUnknown

    # B: Managed, запит кидає виняток (симуляція транзієнтної помилки SCM)
    # -> fail-closed так само, як і null.
    [void](& $dataRestoreModule { param($n, $t) Set-BRAVOSelfTestServiceQueryThrows -Name $n -Throws $t } 'SVC_THROWS_Q7' $true)
    $snapshotThrows = @([pscustomobject]@{ Key = 'B'; Name = 'SVC_THROWS_Q7'; Managed = $true; WasRunning = $false; ShouldRestartAfterRestore = $false; KillProcesses = @() })
    $failuresThrows = & $svcQueryInvoke $dataRestoreModule $snapshotThrows 1 1
    $barrierThrows = & $svcBarrierInvoke $dataRestoreModule $snapshotThrows

    # C: контроль — Managed, служба нормально Running -> досі зупиняється
    # (регресія: fail-closed для null/throw не повинен був зламати
    # звичайний happy-path зупинки).
    [void](& $dataRestoreModule { param($n, $s) Set-BRAVOSelfTestServiceState -Name $n -Status $s } 'SVC_NORMAL_Q7' 'Running')
    $snapshotNormal = @([pscustomobject]@{ Key = 'C'; Name = 'SVC_NORMAL_Q7'; Managed = $true; WasRunning = $true; ShouldRestartAfterRestore = $true; KillProcesses = @() })
    $failuresNormal = & $svcQueryInvoke $dataRestoreModule $snapshotNormal 5 1
    $barrierNormal = & $svcBarrierInvoke $dataRestoreModule $snapshotNormal

    # D: Unmanaged -> як і раніше, повністю ігнорується (жодного запиту).
    $snapshotUnmanaged = @([pscustomobject]@{ Key = 'D'; Name = 'SVC_UNMANAGED_Q7'; Managed = $false; WasRunning = $false; ShouldRestartAfterRestore = $false; KillProcesses = @() })
    $failuresUnmanaged = & $svcQueryInvoke $dataRestoreModule $snapshotUnmanaged 1 1
    $barrierUnmanaged = & $svcBarrierInvoke $dataRestoreModule $snapshotUnmanaged

    # E: той самий контракт через композитний Invoke-BRAVODataRestoreQuiescence
    # (per-component виклик у циклі) — throw теж має провалити композит.
    $quiesceThrowsFailures = & $svcQuiesceInvoke $dataRestoreModule $snapshotThrows 1 1

    Test-BRAVOCondition `
        -Condition (
            @($failuresUnknown).Count -gt 0 -and @($barrierUnknown).Count -gt 0 -and
            @($failuresThrows).Count -gt 0 -and @($barrierThrows).Count -gt 0 -and
            @($failuresNormal).Count -eq 0 -and @($barrierNormal).Count -eq 0 -and
            @($failuresUnmanaged).Count -eq 0 -and @($barrierUnmanaged).Count -eq 0 -and
            @($quiesceThrowsFailures).Count -gt 0
        ) `
        -Name "DataRestore/ManagedServiceQueryFailureFailsClosed" `
        -Failure "Stop-BRAVODataRestoreServices/Test-BRAVODataRestoreServicesAllStopped мають трактувати null АБО виняток від Get-Service для Managed-запису як провал тиші (unsafe/failure), а не мовчазний 'continue'; unmanaged-записи лишаються повністю ігнорованими, а нормальна Running-служба й далі зупиняється без помилок"

    # --- 7.2a. P2: Restore-BRAVODataRestoreServices відновлює службу за
    # ShouldRestartAfterRestore (намір "працювати": Running АБО StartPending
    # на знімку), а НЕ за буквальним WasRunning — інакше служба, що на
    # знімку лише розпочала запуск (StartPending), назавжди лишалась би
    # Stopped. ------------------------------------------------------------
    $restoreInvoke = {
        param($Module, $Snapshot, $StartTimeout, $PollInterval)
        & $Module {
            param($snap, $startT, $poll)
            Restore-BRAVODataRestoreServices -Snapshot $snap -StartTimeoutSeconds $startT -PollIntervalSeconds $poll
        } $Snapshot $StartTimeout $PollInterval
    }
    $svcStatusInvoke = {
        param($Module, $Name)
        & $Module { param($n) $s = Get-Service -Name $n -ErrorAction SilentlyContinue; if ($null -eq $s) { $null } else { [string]$s.Status } } $Name
    }

    # Running на знімку -> ShouldRestartAfterRestore=true -> відновлюється.
    [void](& $dataRestoreModule { param($n, $s) Set-BRAVOSelfTestServiceState -Name $n -Status $s } 'SVC_RESTART_RUNNING' 'Stopped')
    $snapshotRestartRunning = @([pscustomobject]@{ Key = 'R1'; Name = 'SVC_RESTART_RUNNING'; Managed = $true; WasRunning = $true; ShouldRestartAfterRestore = $true; KillProcesses = @() })
    [void](& $restoreInvoke $dataRestoreModule $snapshotRestartRunning 5 1)
    $stateAfterRestartRunning = & $svcStatusInvoke $dataRestoreModule 'SVC_RESTART_RUNNING'

    # StartPending на знімку -> WasRunning=false, АЛЕ ShouldRestartAfterRestore=true
    # (StartPending = намір "працювати") -> МУСИТЬ відновитись.
    [void](& $dataRestoreModule { param($n, $s) Set-BRAVOSelfTestServiceState -Name $n -Status $s } 'SVC_RESTART_STARTPENDING' 'Stopped')
    $snapshotRestartStartPending = @([pscustomobject]@{ Key = 'R2'; Name = 'SVC_RESTART_STARTPENDING'; Managed = $true; WasRunning = $false; ShouldRestartAfterRestore = $true; KillProcesses = @() })
    [void](& $restoreInvoke $dataRestoreModule $snapshotRestartStartPending 5 1)
    $stateAfterRestartStartPending = & $svcStatusInvoke $dataRestoreModule 'SVC_RESTART_STARTPENDING'

    # Stopped на знімку -> WasRunning=false, ShouldRestartAfterRestore=false
    # -> лишається Stopped (не запускається).
    [void](& $dataRestoreModule { param($n, $s) Set-BRAVOSelfTestServiceState -Name $n -Status $s } 'SVC_RESTART_STOPPED' 'Stopped')
    $snapshotRestartStopped = @([pscustomobject]@{ Key = 'R3'; Name = 'SVC_RESTART_STOPPED'; Managed = $true; WasRunning = $false; ShouldRestartAfterRestore = $false; KillProcesses = @() })
    [void](& $restoreInvoke $dataRestoreModule $snapshotRestartStopped 5 1)
    $stateAfterRestartStopped = & $svcStatusInvoke $dataRestoreModule 'SVC_RESTART_STOPPED'

    Test-BRAVOCondition `
        -Condition (
            $stateAfterRestartRunning -eq 'Running' -and
            $stateAfterRestartStartPending -eq 'Running' -and
            $stateAfterRestartStopped -eq 'Stopped'
        ) `
        -Name "DataRestore/RestoreServicesUsesRestartIntentNotLiteralWasRunning" `
        -Failure "Restore-BRAVODataRestoreServices має відновлювати службу за ShouldRestartAfterRestore (намір 'працювати': Running або StartPending на знімку), а не за буквальним WasRunning — інакше служба, що лише розпочала запуск на момент знімка, назавжди лишається Stopped після відновлення"

    # --- 7.2b. Текстова перевірка політики мапування в
    # Get-BRAVODataRestoreServiceSnapshot: Running/StartPending -> true,
    # поле зберігається як ShouldRestartAfterRestore і саме воно (а не
    # WasRunning) використовується гейтом Restore-BRAVODataRestoreServices.
    Test-BRAVOCondition `
        -Condition (
            $dataRestoreRuntimeTextForTests.Contains("`$shouldRestartAfterRestore = (`$stateStatus -eq 'Running' -or `$stateStatus -eq 'StartPending')") -and
            $dataRestoreRuntimeTextForTests.Contains('ShouldRestartAfterRestore = $shouldRestartAfterRestore') -and
            $dataRestoreRuntimeTextForTests.Contains('-not $entry.Managed -or -not $entry.ShouldRestartAfterRestore')
        ) `
        -Name "DataRestore/ShouldRestartAfterRestorePolicyDocumentedAndUsed" `
        -Failure "Get-BRAVODataRestoreServiceSnapshot має обчислювати ShouldRestartAfterRestore як Running-АБО-StartPending, і саме це поле (не WasRunning) має гейтувати Restore-BRAVODataRestoreServices"

    # --- 7.3+7.6. P2: InPlace-ціль, що з'явилася ПІСЛЯ move-aside (чужий
    # каталог), НІКОЛИ не видаляється й не перезаписується під час
    # rollback; повідомлення про відновлення НЕ стверджує існування
    # prerestore-копії, якої не було (MoveAsidePerformed=false). ----------
    $undoOwnershipRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DATA_RESTORE_UNDO_OWNERSHIP_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        [void][IO.Directory]::CreateDirectory($undoOwnershipRoot)
        $undoInvoke = {
            param($Module, $Live, $Prerestore, $Performed, $CreatedByThisRun)
            & $Module {
                param($l, $p, $mp, $c)
                Undo-BRAVODataRestoreMoveAside -LiveDirectory $l -PrerestoreDirectory $p -MoveAsidePerformed $mp -TargetCreatedByThisRun $c
            } $Live $Prerestore $Performed $CreatedByThisRun
        }

        # A: TargetCreatedByThisRun=false, чужий каталог існує на місці
        # LiveDirectory (watchdog відновив після move-aside) — MUST NOT
        # delete/overwrite; rollback провалюється явним повідомленням.
        $foreignLive = Join-Path $undoOwnershipRoot 'MODEL_A'
        $foreignPrerestore = Join-Path $undoOwnershipRoot 'MODEL_A.prerestore_20260816_010000'
        [void][IO.Directory]::CreateDirectory($foreignLive)
        [IO.File]::WriteAllText((Join-Path $foreignLive 'foreign.txt'), 'not-ours')
        [void][IO.Directory]::CreateDirectory($foreignPrerestore)
        [IO.File]::WriteAllText((Join-Path $foreignPrerestore 'original.txt'), 'old')
        $undoForeign = & $undoInvoke $dataRestoreModule $foreignLive $foreignPrerestore $true $false
        $foreignStillIntact = (Test-Path -LiteralPath (Join-Path $foreignLive 'foreign.txt')) -and
            ([IO.File]::ReadAllText((Join-Path $foreignLive 'foreign.txt'))) -eq 'not-ours'
        $prerestoreUntouchedAfterForeign = Test-Path -LiteralPath (Join-Path $foreignPrerestore 'original.txt')

        # B: TargetCreatedByThisRun=true, звичайний власний частковий
        # результат — видаляється, prerestore переноситься назад (щасливий
        # шлях без регресії).
        $ownLive = Join-Path $undoOwnershipRoot 'MODEL_B'
        $ownPrerestore = Join-Path $undoOwnershipRoot 'MODEL_B.prerestore_20260816_010000'
        [void][IO.Directory]::CreateDirectory($ownLive)
        [IO.File]::WriteAllText((Join-Path $ownLive 'partial.txt'), 'partial')
        [void][IO.Directory]::CreateDirectory($ownPrerestore)
        [IO.File]::WriteAllText((Join-Path $ownPrerestore 'original.txt'), 'old')
        $undoOwn = & $undoInvoke $dataRestoreModule $ownLive $ownPrerestore $true $true
        $ownRestored = (Test-Path -LiteralPath (Join-Path $ownLive 'original.txt')) -and
            -not (Test-Path -LiteralPath $ownPrerestore)

        # C: MoveAsidePerformed=false (live був відсутній ще ДО прогону,
        # типовий disaster-сценарій для BRAVOEXCH) + подальший провал ->
        # повідомлення НЕ стверджує "дані збережені" і НЕ містить Rename-Item.
        $absentLive = Join-Path $undoOwnershipRoot 'BRAVOEXCH_C'
        $neverExistedPrerestore = Join-Path $undoOwnershipRoot 'BRAVOEXCH_C.prerestore_20260816_010000'
        # Чужий каталог на місці live -> Test-Path -PathType Container true,
        # TargetCreatedByThisRun=false -> внутрішній throw -> catch-гілка
        # повідомлення.
        [void][IO.Directory]::CreateDirectory($absentLive)
        [IO.File]::WriteAllText((Join-Path $absentLive 'foreign.txt'), 'not-ours')
        $undoNeverExisted = & $undoInvoke $dataRestoreModule $absentLive $neverExistedPrerestore $false $false

        Test-BRAVOCondition `
            -Condition (
                -not [bool]$undoForeign.Success -and
                ([string]$undoForeign.Error) -match 'не створював' -and
                $foreignStillIntact -and
                $prerestoreUntouchedAfterForeign -and
                [bool]$undoOwn.Success -and
                $ownRestored -and
                -not [bool]$undoNeverExisted.Success -and
                -not (([string]$undoNeverExisted.Error) -match 'Дані збережені') -and
                -not (([string]$undoNeverExisted.Error) -match 'Rename-Item') -and
                (([string]$undoNeverExisted.Error) -match 'був відсутній')
            ) `
            -Name "DataRestore/UndoMoveAsideRespectsOwnershipAndPrerestoreExistence" `
            -Failure "Undo-BRAVODataRestoreMoveAside НЕ повинен видаляти/перезаписувати каталог, якого цей прогін не створював (TargetCreatedByThisRun=false), і НЕ повинен стверджувати наявність prerestore-копії чи пропонувати Rename-Item на неіснуючий шлях, коли MoveAsidePerformed=false (live був відсутній ще до прогону); звичайний власний rollback (TargetCreatedByThisRun=true) має продовжувати працювати без регресії"
    } finally {
        if (Test-Path -LiteralPath $undoOwnershipRoot) {
            Remove-Item -LiteralPath $undoOwnershipRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 7.3c. Текстова перевірка: InPlace-створення цілі в основному
    # pipeline тепер БЕЗ -Force, і $inPlaceTargetCreatedByThisRun
    # передається в Undo-BRAVODataRestoreMoveAside. ------------------------
    Test-BRAVOCondition `
        -Condition (
            -not $dataRestoreRuntimeTextForTests.Contains('New-Item -ItemType Directory -Path $planComponent.TargetDirectory -Force -ErrorAction Stop') -and
            $dataRestoreRuntimeTextForTests.Contains('$inPlaceTargetCreatedByThisRun = $true') -and
            $dataRestoreRuntimeTextForTests.Contains('-TargetCreatedByThisRun $inPlaceTargetCreatedByThisRun')
        ) `
        -Name "DataRestore/InPlaceTargetCreationOmitsForce" `
        -Failure "InPlace-створення TargetDirectory (після move-aside) не повинно використовувати -Force (інакше чужий каталог, що з'явився після move-aside, приймається мовчазно); `$inPlaceTargetCreatedByThisRun має передаватись у Undo-BRAVODataRestoreMoveAside як -TargetCreatedByThisRun"

    # --- 7.4. P2: -StagingPath МУСИТЬ бути абсолютним; відносний/malformed
    # шлях -> InvalidConfiguration (exit 30), не generic internal error 90. -
    $stagingRootedCheckIndex = $dataRestoreRuntimeTextForTests.IndexOf('Test-BRAVODataRestoreFullyQualifiedWindowsPath -Value $expandedStagingPath')
    $stagingExit30Index = $dataRestoreRuntimeTextForTests.IndexOf('exit 30', $stagingRootedCheckIndex)
    $stagingGetFullPathTryIndex = $dataRestoreRuntimeTextForTests.IndexOf('[System.IO.Path]::GetFullPath($expandedStagingPath)', $stagingRootedCheckIndex)
    Test-BRAVOCondition `
        -Condition (
            $stagingRootedCheckIndex -gt 0 -and
            $stagingExit30Index -gt $stagingRootedCheckIndex -and
            $stagingGetFullPathTryIndex -gt $stagingExit30Index -and
            $dataRestoreRuntimeTextForTests.Contains('-StagingPath має бути повністю кваліфікованим шляхом')
        ) `
        -Name "DataRestore/StagingPathMustBeAbsolute" `
        -Failure "Ненульовий -StagingPath має проходити Test-BRAVODataRestoreFullyQualifiedWindowsPath ДО GetFullPath і провалюватись через InvalidConfiguration (exit 30) при відносному/диск-відносному/корінь-відносному чи некоректному значенні — інакше такий шлях резолвиться відносно поточного (диска/елевованого процесу) контексту, а malformed шлях провалюється як generic internal error"

    # --- 7.4b. P2 follow-up: Test-BRAVODataRestoreFullyQualifiedWindowsPath
    # приймає лише СПРАВДІ фіксовані форми (буква-диска:\ або UNC
    # \\сервер\ресурс) — IsPathRooted() сам по собі вважав rooted і
    # диск-відносні ('C:RESTORE_STAGING'), і корінь-відносні
    # ('\RESTORE_STAGING') значення, хоча обидва фактично резолвуються
    # відносно поточного диска/контексту процесу (той самий клас
    # небезпеки, що round-7 уже закрив для звичайних відносних шляхів). ---
    $fqInvoke = {
        param($Module, $Value)
        & $Module { param($v) Test-BRAVODataRestoreFullyQualifiedWindowsPath -Value $v } $Value
    }
    $fqDriveBackslash = & $fqInvoke $dataRestoreModule 'C:\RESTORE_STAGING'
    $fqDriveForwardSlash = & $fqInvoke $dataRestoreModule 'C:/RESTORE_STAGING'
    $fqUnc = & $fqInvoke $dataRestoreModule '\\server\share\RESTORE_STAGING'
    $fqBareRelative = & $fqInvoke $dataRestoreModule 'RESTORE_STAGING'
    $fqDotRelative = & $fqInvoke $dataRestoreModule '.\RESTORE_STAGING'
    $fqDriveRelative = & $fqInvoke $dataRestoreModule 'C:RESTORE_STAGING'
    $fqRootRelative = & $fqInvoke $dataRestoreModule '\RESTORE_STAGING'
    $fqMalformedUncShareOnly = & $fqInvoke $dataRestoreModule '\\server'
    $fqEmpty = & $fqInvoke $dataRestoreModule ''
    Test-BRAVOCondition `
        -Condition (
            $fqDriveBackslash -eq $true -and
            $fqDriveForwardSlash -eq $true -and
            $fqUnc -eq $true -and
            $fqBareRelative -eq $false -and
            $fqDotRelative -eq $false -and
            $fqDriveRelative -eq $false -and
            $fqRootRelative -eq $false -and
            $fqMalformedUncShareOnly -eq $false -and
            $fqEmpty -eq $false
        ) `
        -Name "DataRestore/StagingPathRejectsDriveAndRootRelativeForms" `
        -Failure "Test-BRAVODataRestoreFullyQualifiedWindowsPath має приймати лише 'C:\...'/'C:/...' та валідний UNC '\\сервер\ресурс\...', і відхиляти голе ім'я, '.\...', диск-відносне 'C:...' (без роздільника після ':'), корінь-відносне '\...' (без другого провідного backslash), неповний UNC (лише сервер, без ресурсу) та порожнє значення"

    # --- 7.4c. P1 follow-up (review 4945915094, thread 3791473832):
    # Win32 File/Device Namespace префікси ('\\?\...', '\\.\...',
    # включно з device-wrapped UNC '\\?\UNC\сервер\ресурс\...') МУСЯТЬ
    # бути відхилені — GetFullPath зберігає їх дослівно, тому такий
    # псевдонім не збігається лексично зі звичайною формою того самого
    # фізичного шляху в подальших перевірках перетину. -------------------
    $fqDeviceFileNamespace = & $fqInvoke $dataRestoreModule '\\?\C:\RESTORE_STAGING'
    $fqDeviceNamespace = & $fqInvoke $dataRestoreModule '\\.\C:\RESTORE_STAGING'
    $fqDeviceWrappedUncFile = & $fqInvoke $dataRestoreModule '\\?\UNC\server\share\RESTORE_STAGING'
    $fqDeviceWrappedUncDevice = & $fqInvoke $dataRestoreModule '\\.\UNC\server\share\RESTORE_STAGING'
    Test-BRAVOCondition `
        -Condition (
            $fqDeviceFileNamespace -eq $false -and
            $fqDeviceNamespace -eq $false -and
            $fqDeviceWrappedUncFile -eq $false -and
            $fqDeviceWrappedUncDevice -eq $false
        ) `
        -Name "DataRestore/StagingPathRejectsDeviceNamespaceForms" `
        -Failure "Test-BRAVODataRestoreFullyQualifiedWindowsPath має відхиляти Win32 File Namespace ('\\?\...') і Device Namespace ('\\.\...') префікси, включно з device-wrapped UNC ('\\?\UNC\...', '\\.\UNC\...') — наївний UNC-regex трактував '?'/'.' як звичайний односимвольний 'сервер', а GetFullPath зберігає ці префікси дослівно замість нормалізації, тому такий псевдонім не збігається лексично зі звичайною формою того самого фізичного шляху"

    # --- 7.4d. P1 follow-up: критичний alias-сценарій — device-namespace
    # псевдонім захищеного live-шляху МУСИТЬ бути відхилений
    # Test-BRAVODataRestoreStagingSafe (defense-in-depth усередині самої
    # функції, не лише на вході pipeline), і жодної filesystem-мутації
    # (New-Item) при цьому статися НЕ повинно — перевіряємо целим
    # відсутність побічних ефектів. --------------------------------------
    $stagingSafeInvoke = {
        param($Module, $StagingRoot, $RuntimeRootPath, $LiveSources)
        & $Module {
            param($s, $r, $l)
            Test-BRAVODataRestoreStagingSafe -StagingRoot $s -RuntimeRootPath $r -LiveSources $l
        } $StagingRoot $RuntimeRootPath $LiveSources
    }
    $aliasProtectedLive = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DEVICE_NAMESPACE_ALIAS_LIVE_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        [void][IO.Directory]::CreateDirectory($aliasProtectedLive)
        $aliasLiveSources = @{ MODEL = $aliasProtectedLive }
        $aliasRuntimeRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_DEVICE_NAMESPACE_ALIAS_RUNTIME_{0}" -f [guid]::NewGuid().ToString('N'))

        # Device File Namespace псевдонім ('\\?\' + той самий фізичний шлях).
        # "Відсутність мутації" перевіряємо через $aliasRuntimeRoot — свіжий
        # guid-шлях, що НІКОЛИ не створювався: якби Test-BRAVODataRestoreStagingSafe
        # (read-only preflight, жодного New-Item у власному тілі) чи будь-
        # який виклик у цьому тесті торкнувся файлової системи за межами
        # завідомо існуючого $aliasProtectedLive, цей шлях перестав би бути
        # відсутнім. (Test-Path на самому $aliasFileNamespaceStaging НЕ
        # підходить для цієї перевірки: він фізично ІСНУЄ від початку —
        # це той самий каталог, що й $aliasProtectedLive, під псевдонімом.)
        $aliasFileNamespaceStaging = "\\?\$aliasProtectedLive"
        $aliasFileNamespaceResult = & $stagingSafeInvoke $dataRestoreModule $aliasFileNamespaceStaging $aliasRuntimeRoot $aliasLiveSources
        $aliasNoMutationAfterFileNamespace = -not (Test-Path -LiteralPath $aliasRuntimeRoot -ErrorAction SilentlyContinue)

        # Device Namespace псевдонім ('\\.\' + той самий фізичний шлях).
        $aliasDeviceNamespaceStaging = "\\.\$aliasProtectedLive"
        $aliasDeviceNamespaceResult = & $stagingSafeInvoke $dataRestoreModule $aliasDeviceNamespaceStaging $aliasRuntimeRoot $aliasLiveSources
        $aliasNoMutationAfterDeviceNamespace = -not (Test-Path -LiteralPath $aliasRuntimeRoot -ErrorAction SilentlyContinue)

        # Контроль: звичайна форма того самого шляху й далі коректно
        # відхиляється як "перетинається з live-джерелом" (регресія
        # попереднього раунду не зламана цим фіксом).
        $aliasNormalFormResult = & $stagingSafeInvoke $dataRestoreModule $aliasProtectedLive $aliasRuntimeRoot $aliasLiveSources

        Test-BRAVOCondition `
            -Condition (
                -not [bool]$aliasFileNamespaceResult.Success -and
                $aliasNoMutationAfterFileNamespace -and
                -not [bool]$aliasDeviceNamespaceResult.Success -and
                $aliasNoMutationAfterDeviceNamespace -and
                -not [bool]$aliasNormalFormResult.Success
            ) `
            -Name "DataRestore/StagingSafeRejectsDeviceNamespaceAliasOfLiveSource" `
            -Failure "Test-BRAVODataRestoreStagingSafe МУСИТЬ відхиляти StagingRoot, переданий у формі Win32 File/Device Namespace ('\\?\...'/'\\.\...'), навіть коли він фізично збігається із захищеним live-джерелом — інакше лексичне порівняння (GetFullPath) не бачить перетину і псевдонім проходить preflight; жодної filesystem-мутації (New-Item) відбуватись не повинно"
    } finally {
        if (Test-Path -LiteralPath $aliasProtectedLive) {
            Remove-Item -LiteralPath $aliasProtectedLive -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 7.5. P2: локальні артефакти мають переживати relocation
    # backup-root — leaf-ім'я з manifest-шляху (недовірений вхід)
    # переприв'язується до ПОТОЧНОГО canonical каталогу компонента, а не
    # довіряється старому абсолютному шляху продюсера. Post-round-7
    # follow-up (review 4945879933): ці функції promoted у
    # BRAVO.ArchiveHelpers (Get-BRAVOVerifiedArtifactLeafName,
    # ConvertTo-BRAVORebasedLocalGenerationManifest) — реальний
    # Import-Module, не ізольований $dataRestoreModule (canonical
    # implementation тепер спільна з BRAVO_RESTORE_TEST.ps1). -------------
    Remove-Module -Name 'BRAVO.ArchiveHelpers' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.ArchiveHelpers\BRAVO.ArchiveHelpers.psd1") -Force -ErrorAction Stop

    $leafNormal = Get-BRAVOVerifiedArtifactLeafName -Value 'E:\OLD_BACKUP\MODEL\OLDPREFIX_20260815_120000.mdz'
    $leafTraversal = Get-BRAVOVerifiedArtifactLeafName -Value '..\..\Windows\System32\evil.dll'
    $leafEmpty = Get-BRAVOVerifiedArtifactLeafName -Value ''
    $leafDotDot = Get-BRAVOVerifiedArtifactLeafName -Value '..'

    $rebaseManifest = ConvertFrom-Json (@{
        generationId = '20260815_120000'
        status = 'COMPLETE'
        components = @{
            MODEL = @{
                Enabled = $true
                ArchivePath = 'E:\OLD_BACKUP\MODEL\OLDPREFIX_20260815_120000.mdz'
                HashPath = 'E:\OLD_BACKUP\MODEL\OLDPREFIX_20260815_120000.mdz.sha512'
            }
        }
    } | ConvertTo-Json -Depth 6)
    # $env:SystemDrive (не жорстко закодований F:) — Join-Path у
    # ConvertTo-BRAVORebasedLocalGenerationManifest резолвиться через
    # provider і вимагає, щоб буква диска була наявним PSDrive; довільна
    # незамаплена буква (F:) є на робочій станції розробника, але
    # відсутня на CI runner-і — SystemDrive гарантовано існує всюди.
    # "Інший корінь" тут — інший ПІДКАТАЛОГ (RECOVERY_BACKUP замість
    # OLD_BACKUP), той самий сценарій relocation, що й у фіндингу.
    $rebaseDestinationRoot = Join-Path $env:SystemDrive 'RECOVERY_BACKUP\MODEL'
    $rebaseDefinitions = @([pscustomobject]@{ Type = 'MODEL'; Destination = $rebaseDestinationRoot })
    $rebasedManifest = ConvertTo-BRAVORebasedLocalGenerationManifest -Manifest $rebaseManifest -ComponentTypes @('MODEL') -ArchiveDefinitions $rebaseDefinitions
    $rebasedArchivePath = [string]$rebasedManifest.components.MODEL.ArchivePath
    $rebasedHashPath = [string]$rebasedManifest.components.MODEL.HashPath
    $expectedRebasedArchivePath = Join-Path $rebaseDestinationRoot 'OLDPREFIX_20260815_120000.mdz'
    $expectedRebasedHashPath = Join-Path $rebaseDestinationRoot 'OLDPREFIX_20260815_120000.mdz.sha512'

    Test-BRAVOCondition `
        -Condition (
            $leafNormal -eq 'OLDPREFIX_20260815_120000.mdz' -and
            $leafTraversal -eq 'evil.dll' -and
            $null -eq $leafEmpty -and
            $null -eq $leafDotDot -and
            $rebasedArchivePath -eq $expectedRebasedArchivePath -and
            $rebasedHashPath -eq $expectedRebasedHashPath
        ) `
        -Name "DataRestore/LocalManifestRebasedOntoCurrentComponentDestination" `
        -Failure "Get-BRAVOVerifiedArtifactLeafName (BRAVO.ArchiveHelpers) має витягувати БЕЗПЕЧНЕ leaf-ім'я (traversal-сегменти відкидаються GetFileName, порожнє/'.'/'..' відхиляється), а ConvertTo-BRAVORebasedLocalGenerationManifest — переписувати ArchivePath/HashPath на ПОТОЧНИЙ canonical каталог компонента (archiveDefinitions[Type].Destination) + це ім'я, а не довіряти старому абсолютному шляху продюсера — інакше скопійований під іншим коренем backup-репозиторій відхиляється, хоча архів/sidecar/manifest валідні"

    # Ordering: рескладка Local-манифесту в BRAVO_DATA_RESTORE МУСИТЬ
    # відбуватись ДО строгого gate (крок 5), той самий момент, що вже
    # застосовує SFTP-рескладку.
    $localRebaseCallIndex = $dataRestoreRuntimeTextForTests.IndexOf('ConvertTo-BRAVORebasedLocalGenerationManifest ')
    $strictGateCommentIndex = $dataRestoreRuntimeTextForTests.IndexOf('Строгий gate по кожному компоненту')
    Test-BRAVOCondition `
        -Condition (
            $localRebaseCallIndex -gt 0 -and
            $strictGateCommentIndex -gt $localRebaseCallIndex
        ) `
        -Name "DataRestore/LocalManifestRebaseRunsBeforeStrictGate" `
        -Failure "ConvertTo-BRAVORebasedLocalGenerationManifest має викликатись ДО строгого gate (крок 5) в BRAVO_DATA_RESTORE — той самий момент pipeline, де SFTP вже переписує шляхи на staging"

    # --- 7.5b. Post-round-7 follow-up (P2, review 4945879933, thread
    # 3791434142): BRAVO_RESTORE_TEST.ps1 (pre-restore drill) МУСИТЬ
    # застосовувати ТУ САМУ canonical rebasing-політику ДО виклику
    # Get-BRAVOVerifiedGenerationArchive, а не довіряти сирому manifest-у —
    # інакше relocated local repository проходить BRAVO_DATA_RESTORE, але
    # провалює drill. Текстова перевірка + перевірка порядку (rebasing ДО
    # виклику Get-BRAVOVerifiedGenerationArchive в циклі компонентів). ----
    $restoreTestScriptTextForRebaseParity = [IO.File]::ReadAllText((Join-Path $root "BRAVO_RESTORE_TEST.ps1"), [Text.Encoding]::UTF8)
    $restoreTestRebaseCallIndex = $restoreTestScriptTextForRebaseParity.IndexOf('ConvertTo-BRAVORebasedLocalGenerationManifest')
    # Файл згадує Get-BRAVOVerifiedGenerationArchive і в doc-коментарі на
    # початку (спільний selector/gate) — шукаємо ФАКТИЧНИЙ виклик у циклі
    # компонентів, тобто ПІСЛЯ виклику rebasing, а не перше входження.
    $restoreTestVerifyLoopIndex = $restoreTestScriptTextForRebaseParity.IndexOf('Get-BRAVOVerifiedGenerationArchive', [Math]::Max($restoreTestRebaseCallIndex, 0))
    Test-BRAVOCondition `
        -Condition (
            $restoreTestRebaseCallIndex -gt 0 -and
            $restoreTestVerifyLoopIndex -gt $restoreTestRebaseCallIndex -and
            -not $restoreTestScriptTextForRebaseParity.Contains('function ConvertTo-BRAVORebasedLocalGenerationManifest') -and
            -not $restoreTestScriptTextForRebaseParity.Contains('function Get-BRAVOVerifiedArtifactLeafName')
        ) `
        -Name "RestoreTest/UsesCanonicalLocalManifestRebasingBeforeVerification" `
        -Failure "BRAVO_RESTORE_TEST.ps1 має викликати спільний ConvertTo-BRAVORebasedLocalGenerationManifest (BRAVO.ArchiveHelpers) ДО Get-BRAVOVerifiedGenerationArchive в циклі компонентів, і НЕ визначати власну копію rebasing-логіки — інакше drill і реальне відновлення (BRAVO_DATA_RESTORE) можуть розійтися в поведінці для relocated local repository"

    # Behavioral parity: обидва споживачі отримують ІДЕНТИЧНИЙ результат
    # rebasing для того самого relocated-сценарію (E: OLD_BACKUP -> поточний
    # SystemDrive RECOVERY_BACKUP), включно з BLOG/BRAVOEXCH, і rebased
    # шлях і надалі проходить звичайну Get-BRAVOVerifiedGenerationArchive
    # перевірку (containment/generation/hash), а не якийсь спрощений шлях.
    $parityFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_RESTORE_TEST_REBASE_PARITY_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        [void][IO.Directory]::CreateDirectory($parityFixtureRoot)
        $parityComponentDirs = @{}
        foreach ($parityType in @('MODEL', 'BLOG', 'BRAVOEXCH')) {
            $parityComponentDirs[$parityType] = Join-Path $parityFixtureRoot $parityType
            [void][IO.Directory]::CreateDirectory($parityComponentDirs[$parityType])
        }
        $parityNameTemplates = @{ MODEL = '{0}_{1}.mdz'; BLOG = '{0}_blog_{1}.mdz'; BRAVOEXCH = '{0}_exch_{1}.mdz' }
        $parityGenerationId = '20260816_090000'
        $parityManifestComponents = @{}
        $parityArchiveDefinitions = @()
        foreach ($parityType in @('MODEL', 'BLOG', 'BRAVOEXCH')) {
            $parityArchiveName = $parityNameTemplates[$parityType] -f 'INST', $parityGenerationId
            $parityArchivePath = Join-Path $parityComponentDirs[$parityType] $parityArchiveName
            [IO.File]::WriteAllBytes($parityArchivePath, (New-Object byte[] 32))
            $parityHash = (Get-BRAVOFileHash -Path $parityArchivePath -Algorithm SHA512).Hash.ToUpperInvariant()
            $parityHashPath = "$parityArchivePath.sha512"
            [IO.File]::WriteAllText($parityHashPath, "$parityHash *$parityArchiveName")
            # Manifest-шлях НАВМИСНО вказує на неіснуючий старий продюсер-
            # корінь — саме сценарій, що провалював drill до цього фіксу.
            $parityManifestComponents[$parityType] = @{
                Enabled = $true
                CreateSuccess = $true
                IntegritySuccess = $true
                HashSuccess = $true
                ArchivePath = "Z:\OBSOLETE_PRODUCER_ROOT\$parityType\$parityArchiveName"
                HashPath = "Z:\OBSOLETE_PRODUCER_ROOT\$parityType\$parityArchiveName.sha512"
                SHA512 = $parityHash
            }
            $parityArchiveDefinitions += [pscustomobject]@{ Type = $parityType; Destination = $parityComponentDirs[$parityType]; NameTemplate = $parityNameTemplates[$parityType] }
        }
        $parityManifest = ConvertFrom-Json (@{
            generationId = $parityGenerationId
            status = 'COMPLETE'
            components = $parityManifestComponents
        } | ConvertTo-Json -Depth 8)

        $parityRebased = ConvertTo-BRAVORebasedLocalGenerationManifest -Manifest $parityManifest -ComponentTypes @('MODEL', 'BLOG', 'BRAVOEXCH') -ArchiveDefinitions $parityArchiveDefinitions
        $parityVerifiedResults = @{}
        $parityVerifyFailed = $false
        foreach ($parityType in @('MODEL', 'BLOG', 'BRAVOEXCH')) {
            try {
                $parityVerifiedResults[$parityType] = Get-BRAVOVerifiedGenerationArchive `
                    -Manifest $parityRebased `
                    -Component $parityType `
                    -NameTemplate $parityNameTemplates[$parityType] `
                    -ComponentDirectory $parityComponentDirs[$parityType]
            } catch {
                $parityVerifyFailed = $true
            }
        }

        # Path-escape manifest value (malicious/traversal ArchivePath) —
        # leaf-валідатор (Get-BRAVOVerifiedArtifactLeafName) бере ЛИШЕ
        # ім'я файлу після останнього роздільника ([System.IO.Path]::GetFileName,
        # чиста рядкова операція), тому traversal-СЕГМЕНТИ ('..\..\..\Windows\System32\')
        # відкидаються цілком — rebased ArchivePath стає leaf-only шляхом
        # УСЕРЕДИНІ canonical каталогу компонента (не "неперезаписаним", як
        # можна було б наївно очікувати: сам "evil.mdz" — валідне ім'я
        # файлу). Це й Є захист: жоден traversal-сегмент фізично не
        # потрапляє в результуючий шлях. Файл із таким ім'ям фізично НЕ
        # існує в canonical каталозі компонента, тому подальший
        # Get-BRAVOVerifiedGenerationArchive все одно провалюється
        # (Test-Path на відсутньому артефакті) — REJECT, не silent
        # fallback на producer-шлях і не траверсал за межі каталогу.
        $parityEscapeManifest = ConvertFrom-Json (@{
            generationId = $parityGenerationId
            status = 'COMPLETE'
            components = @{
                MODEL = @{
                    Enabled = $true; CreateSuccess = $true; IntegritySuccess = $true; HashSuccess = $true
                    ArchivePath = '..\..\..\Windows\System32\evil.mdz'
                    HashPath = '..\..\..\Windows\System32\evil.mdz.sha512'
                    SHA512 = 'DEADBEEF'
                }
            }
        } | ConvertTo-Json -Depth 8)
        $parityEscapeRebased = ConvertTo-BRAVORebasedLocalGenerationManifest -Manifest $parityEscapeManifest -ComponentTypes @('MODEL') -ArchiveDefinitions @([pscustomobject]@{ Type = 'MODEL'; Destination = $parityComponentDirs['MODEL'] })
        $parityEscapeRebasedPath = [string]$parityEscapeRebased.components.MODEL.ArchivePath
        $parityEscapeContainedSafely = ($parityEscapeRebasedPath -eq (Join-Path $parityComponentDirs['MODEL'] 'evil.mdz')) -and
            (-not $parityEscapeRebasedPath.Contains('..')) -and
            (-not $parityEscapeRebasedPath.Contains('System32'))
        $parityEscapeRejected = $false
        try {
            [void](Get-BRAVOVerifiedGenerationArchive -Manifest $parityEscapeRebased -Component 'MODEL' -NameTemplate $parityNameTemplates['MODEL'] -ComponentDirectory $parityComponentDirs['MODEL'])
        } catch {
            $parityEscapeRejected = $true
        }

        # Missing archive after legitimate rebasing (component directory
        # exists, canonical, але артефакт фізично відсутній) -> FAIL, не
        # silent fallback на (недосяжний) producer-шлях.
        $parityMissingComponentDir = Join-Path $parityFixtureRoot 'MODEL_EMPTY'
        [void][IO.Directory]::CreateDirectory($parityMissingComponentDir)
        $parityMissingManifest = ConvertFrom-Json (@{
            generationId = $parityGenerationId
            status = 'COMPLETE'
            components = @{
                MODEL = @{
                    Enabled = $true; CreateSuccess = $true; IntegritySuccess = $true; HashSuccess = $true
                    ArchivePath = 'Z:\OBSOLETE_PRODUCER_ROOT\MODEL\missing.mdz'
                    HashPath = 'Z:\OBSOLETE_PRODUCER_ROOT\MODEL\missing.mdz.sha512'
                    SHA512 = 'DEADBEEF'
                }
            }
        } | ConvertTo-Json -Depth 8)
        $parityMissingRebased = ConvertTo-BRAVORebasedLocalGenerationManifest -Manifest $parityMissingManifest -ComponentTypes @('MODEL') -ArchiveDefinitions @([pscustomobject]@{ Type = 'MODEL'; Destination = $parityMissingComponentDir })
        $parityMissingRejected = $false
        try {
            [void](Get-BRAVOVerifiedGenerationArchive -Manifest $parityMissingRebased -Component 'MODEL' -NameTemplate $parityNameTemplates['MODEL'] -ComponentDirectory $parityMissingComponentDir)
        } catch {
            $parityMissingRejected = $true
        }

        # Жоден зі старих producer-шляхів (Z:\OBSOLETE_PRODUCER_ROOT) не
        # використовується після rebasing — перевіряємо, що успішно
        # верифікований архів фізично лежить у НОВОМУ canonical каталозі.
        $parityNoProducerPathAccessed = $true
        foreach ($parityType in @('MODEL', 'BLOG', 'BRAVOEXCH')) {
            if ($null -ne $parityVerifiedResults[$parityType]) {
                if (([string]$parityVerifiedResults[$parityType].FullName).StartsWith('Z:\OBSOLETE_PRODUCER_ROOT', [StringComparison]::OrdinalIgnoreCase)) {
                    $parityNoProducerPathAccessed = $false
                }
            }
        }

        Test-BRAVOCondition `
            -Condition (
                -not $parityVerifyFailed -and
                $parityVerifiedResults.Count -eq 3 -and
                $parityNoProducerPathAccessed -and
                $parityEscapeContainedSafely -and
                $parityEscapeRejected -and
                $parityMissingRejected
            ) `
            -Name "RestoreTest/LocalManifestRebasingParityAcrossComponentsAndFailureModes" `
            -Failure "ConvertTo-BRAVORebasedLocalGenerationManifest + Get-BRAVOVerifiedGenerationArchive мають: (a) успішно верифікувати MODEL/BLOG/BRAVOEXCH після rebasing на новий canonical каталог, без жодного звернення до старого producer-кореня; (b) traversal-сегменти path-escape ArchivePath МАЮТЬ бути відкинуті (leaf-only rebased шлях суворо всередині canonical каталогу компонента), і подальша верифікація МУСИТЬ провалитись (файла з таким ім'ям там немає), а не silently fallback на producer-шлях; (c) відхиляти легітимно rebased, але фізично відсутній архів явним FAIL"
    } finally {
        if (Test-Path -LiteralPath $parityFixtureRoot) {
            Remove-Item -LiteralPath $parityFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 7.7. P1 (документація): OPERATIONS.md більше не радить брати
    # "найстаріший" .prerestore_* — це відкочує компонент на generation
    # далі, ніж треба, коли ПІЗНІШИЙ прогін перервався. -------------------
    $operationsTextForRound7 = [IO.File]::ReadAllText((Join-Path $root "OPERATIONS.md"), [Text.Encoding]::UTF8)
    Test-BRAVOCondition `
        -Condition (
            -not $operationsTextForRound7.Contains('беріть **найстаріший**') -and
            ($operationsTextForRound7 -match 'НІКОЛИ не беріть\s+найстаріший') -and
            $operationsTextForRound7.Contains('Поточні дані знесено вбік')
        ) `
        -Name "DataRestore/OperationsRunbookRecoversInterruptedRunCopyNotOldest" `
        -Failure "OPERATIONS.md не повинен радити брати найстаріший .prerestore_* при відновленні після переривання — потрібна прив'язка до ТОЧНОГО прогону через рядок 'Поточні дані знесено вбік' у журналі саме перерваного прогону (Крок 0), інакше компонент відкочується на generation далі, ніж треба"

    # --- 7.8. P2 follow-up: Get-BRAVODataRestoreServiceSnapshot зберігає
    # InitialStatus у кожному записі знімка (окремо від WasRunning/
    # ShouldRestartAfterRestore) — саме воно потрібне для точного
    # операторського аудиту (не лише true/false Running). ------------------
    Test-BRAVOCondition `
        -Condition (
            $dataRestoreRuntimeTextForTests.Contains('Status = if ($null -ne $service) { [string]$service.Status } else { $null }') -and
            $dataRestoreRuntimeTextForTests.Contains('InitialStatus = $stateStatus')
        ) `
        -Name "DataRestore/ServiceSnapshotPreservesInitialStatus" `
        -Failure "Get-BRAVODataRestoreServiceSnapshot має зберігати InitialStatus (точний рядок стану служби на момент знімка, напр. 'StartPending') у кожному записі — потрібно для операторського аудиту, а не лише булевого WasRunning"

    # --- 7.9. P2 follow-up: план/лог перед move-aside НЕ повинен зводити
    # "служби для зупинки" до фільтра WasRunning — квієсценція діє на ВСІ
    # Managed-записи (initially-Stopped служба, що встигла запуститись до
    # move-aside, теж має бути зупинена). Restart-intent показується
    # ОКРЕМО. Аудиторський рядок пишеться в ЛОГ (Write-DataRestoreLog) ДО
    # move-aside, щоб пережити переривання прогону до фінального
    # restart-кроку. -------------------------------------------------------
    Test-BRAVOCondition `
        -Condition (
            -not $dataRestoreRuntimeTextForTests.Contains('$servicesToStop = @($script:dataRestoreServiceSnapshot | Where-Object { $_.Managed -and $_.WasRunning })') -and
            $dataRestoreRuntimeTextForTests.Contains('$managedServicesForQuiescence = @($script:dataRestoreServiceSnapshot | Where-Object { $_.Managed })') -and
            $dataRestoreRuntimeTextForTests.Contains('$servicesWithRestartIntent = @($script:dataRestoreServiceSnapshot | Where-Object { $_.Managed -and $_.ShouldRestartAfterRestore })') -and
            $dataRestoreRuntimeTextForTests.Contains('Знімок служби {0}: initial={1}, restart-after-recovery={2}') -and
            $dataRestoreRuntimeTextForTests.IndexOf('Write-DataRestoreLog -Message ("Знімок служби') -lt $dataRestoreRuntimeTextForTests.IndexOf('Invoke-BRAVODataRestoreMoveAside `')
        ) `
        -Name "DataRestore/ServiceSnapshotAuditTrailPrecedesMoveAside" `
        -Failure "Операторський план/лог не повинен зводити квієсценцію до 'лише WasRunning'-фільтра (вона діє на ВСІ Managed-записи); restart-intent має показуватись окремо; кожен Managed-запис має логуватись ('Знімок служби {Name}: initial=..., restart-after-recovery=...') через Write-DataRestoreLog СТРОГО ДО першого move-aside — інакше запис може ніколи не потрапити в лог, якщо прогін перерветься раніше"

    # --- 7.10. P2 follow-up: OPERATIONS.md більше не радить '"лише
    # Running"'/"BRAVO зупиняє тільки Running-служби" — квієсценція діє на
    # всі Managed-служби, а restart-intent (Running АБО StartPending)
    # береться саме з залогованого запису знімка, не з поточного стану
    # служб після аварії/перезавантаження. ---------------------------------
    Test-BRAVOCondition `
        -Condition (
            -not $operationsTextForRound7.Contains('BRAVO зупиняє тільки Running-служби') -and
            -not $operationsTextForRound7.Contains('ТІЛЬКИ ті, що були Running') -and
            $operationsTextForRound7.Contains('StartPending') -and
            $operationsTextForRound7.Contains('restart-after-recovery') -and
            $operationsTextForRound7.Contains('Знімок служби')
        ) `
        -Name "DataRestore/OperationsRunbookRestartGuidanceMatchesStartPendingPolicy" `
        -Failure "OPERATIONS.md не повинен стверджувати, що BRAVO зупиняє/відновлює лише Running-служби (квієсценція діє на всі Managed, а restart-intent = Running АБО StartPending); операторська інструкція має спиратись на залогований запис 'Знімок служби ...: restart-after-recovery=...' точно перерваного прогону, а не на поточний стан служб після аварії"

    # --- 8. rc.4: severity-routing сповіщень DataRestore (GENERAL/ALERTS).
    # Send-BRAVODataRestoreNotification має обирати канал через канонічний
    # ланцюжок BRAVO.Notifications: Resolve-BRAVONotificationRoute (реальна
    # функція, витягнута за AST з модуля) -> Resolve-BRAVONotificationEndpoint
    # (заглушений: єдина ланка з доступом до Credential Manager) ->
    # ConvertTo-BRAVONotificationPayloadText -> Send-BRAVONotificationChunks
    # з таймаутом із конфігурації. Каналів рівно ДВА: SUCCESS -> general,
    # WARNING/CRITICAL -> alerts; legacy-target — лише backward-compat
    # fallback усередині канонічного endpoint-резолвера, НЕ третій канал.
    # Регресія: старий legacy-шлях (прямий Get-BRAVOCredentialSecret +
    # Send-BRAVOWebhookNotification без routing) провалює ці тести.
    $notificationsModuleTextForDataRestore = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Notifications\BRAVO.Notifications.psm1"),
        [Text.Encoding]::UTF8
    )
    $routingTokensForDataRestore = $null
    $routingErrorsForDataRestore = $null
    $routingAstForDataRestore = [Management.Automation.Language.Parser]::ParseInput(
        $notificationsModuleTextForDataRestore,
        [ref]$routingTokensForDataRestore,
        [ref]$routingErrorsForDataRestore
    )
    $routeFunctionAstForDataRestore = @(
        $routingAstForDataRestore.FindAll(
            {
                param($candidate)
                $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $candidate.Name -eq 'Resolve-BRAVONotificationRoute'
            },
            $true
        )
    ) | Select-Object -First 1
    Test-BRAVOCondition `
        -Condition ($null -ne $routeFunctionAstForDataRestore) `
        -Name "DataRestore/NotificationRoutingCanonicalFunctionAvailable" `
        -Failure "Resolve-BRAVONotificationRoute не знайдено в modules\BRAVO.Notifications\BRAVO.Notifications.psm1 — канонічний severity-routing зник або перейменований"

    # Стаб журналу визначається НЕ в SourceText (Runtime.ps1 починається з
    # top-level param(), тому будь-який текст перед ним ламає парсинг), а
    # всередині &-блоку модуля нижче — function-statement у module scope
    # перекриває витягнуту реалізацію, як у Archive/Maintenance-пробах.
    $dataRestoreNotificationModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $dataRestoreRuntimeTextForTests `
        -FunctionNames @('Send-BRAVODataRestoreNotification')

    $dataRestoreNotificationProbe = if ($null -eq $routeFunctionAstForDataRestore) {
        [pscustomobject]@{ ResolvedEndpointRoutes = @(); SentBatches = @(); WarningCount = -1; Logs = @() }
    } else {
        & $dataRestoreNotificationModule {
            param([string]$RoutingDefinition)

            # Реальний Resolve-BRAVONotificationRoute у scope модуля разом з
            # module-scope дефолтною таблицею, на яку він посилається.
            . ([scriptblock]::Create($RoutingDefinition))
            $script:BRAVODefaultNotificationRouting = @{
                SUCCESS = 'general'; WARNING = 'alerts'; ERROR = 'alerts'; CRITICAL = 'alerts'
            }

            $script:bravoSettings = @{
                NotificationProvider = 'discord'
                InstitutionName = 'TEST'
                InstitutionCode = '00000000'
            }
            $script:credentialSettings = @{ Targets = @{
                DiscordWebhookGeneral = 'BRAVO_DISCORD_GENERAL_URL'
                DiscordWebhookAlerts = 'BRAVO_DISCORD_ALERTS_URL'
            } }
            $script:backupMonitoring = @{
                NotificationRouting = @{ SUCCESS = 'general'; WARNING = 'alerts'; ERROR = 'alerts'; CRITICAL = 'alerts' }
                NotificationCredentialTargets = @{
                    DiscordWebhookGeneral = 'BRAVO_DISCORD_GENERAL_URL'
                    DiscordWebhookAlerts = 'BRAVO_DISCORD_ALERTS_URL'
                }
                NotificationRequestTimeoutSeconds = 7
            }
            $script:ScriptVersion = '5.1.0-test'
            $script:ScriptBuildId = 'self-test'
            $script:dataRestoreLogFile = 'C:\BRAVO_TEST\BRAVO_DATA_RESTORE.log'
            $script:dataRestoreWarningCount = 0
            $script:BRAVOSelfTestNotificationLogs = New-Object System.Collections.Generic.List[string]
            $script:resolvedEndpointRoutes = New-Object System.Collections.Generic.List[string]
            $script:sentChunkBatches = New-Object System.Collections.Generic.List[object]

            function Write-DataRestoreLog {
                param([AllowEmptyString()][string]$Message, [string]$Level = 'INFO', [switch]$Console)
                [void]$script:BRAVOSelfTestNotificationLogs.Add("$Level|$Message")
            }
            function Get-HostInformation {
                [pscustomobject]@{ MachineName = 'TEST-HOST'; LocalIP = '127.0.0.1'; PublicIP = 'вимкнено' }
            }
            function Resolve-BRAVONotificationEndpoint {
                param([string]$Provider, [string]$Route, [hashtable]$CredentialTargets)
                [void]$script:resolvedEndpointRoutes.Add("$Provider/$Route")
                return "https://example.invalid/$Route"
            }
            function New-BRAVOOperatorNotificationMessage {
                param(
                    [string]$Severity, [string]$Operation, [string]$ActionText, [string[]]$ReasonLines,
                    [string]$InstitutionName, [string]$InstitutionCode, $HostInformation,
                    [string[]]$ResultLines, [datetime]$Timestamp, [string]$ProductName,
                    [string]$Version, [string]$BuildId, [string]$LogPath, [string]$LogLabel
                )
                return (@($Severity, $Operation) + $ResultLines) -join [Environment]::NewLine
            }
            function ConvertTo-BRAVONotificationPayloadText {
                param([string]$Provider, [string]$Message)
                return @($Message)
            }
            function Send-BRAVONotificationChunks {
                param([string]$Provider, [string]$WebhookUrl, [string[]]$MessageChunks, [int]$TimeoutSeconds)
                [void]$script:sentChunkBatches.Add([pscustomobject]@{
                    WebhookUrl = $WebhookUrl
                    ChunkCount = @($MessageChunks).Count
                    TimeoutSeconds = $TimeoutSeconds
                })
            }
            # Legacy-шлях: якщо код усе ще звертається напряму до Credential
            # Manager або шле без чанкінгу/таймауту — впасти явно (outer
            # catch функції перетворить це на WarningCount > 0 і нуль
            # відправлень, що провалює assertions нижче).
            function Get-BRAVOCredentialSecret {
                param([string]$Target)
                throw "legacy-шлях: прямий Get-BRAVOCredentialSecret (target '$Target') замість Resolve-BRAVONotificationEndpoint"
            }
            function Send-BRAVOWebhookNotification {
                param([string]$Provider, [string]$WebhookUrl, [string]$Message, [int]$TimeoutSeconds)
                throw 'legacy-шлях: прямий Send-BRAVOWebhookNotification замість Send-BRAVONotificationChunks'
            }

            Send-BRAVODataRestoreNotification -Severity 'CRITICAL' -ResultLines @('Відновлення завершилось помилкою (код 43).') -ActionText 'перевірити журнал'
            Send-BRAVODataRestoreNotification -Severity 'SUCCESS' -ResultLines @('Відновлення завершено успішно.')

            [pscustomobject]@{
                ResolvedEndpointRoutes = $script:resolvedEndpointRoutes.ToArray()
                SentBatches = $script:sentChunkBatches.ToArray()
                WarningCount = $script:dataRestoreWarningCount
                Logs = $script:BRAVOSelfTestNotificationLogs.ToArray()
            }
        } $routeFunctionAstForDataRestore.Extent.Text
    }

    Test-BRAVOCondition `
        -Condition (
            @($dataRestoreNotificationProbe.ResolvedEndpointRoutes).Count -eq 2 -and
            $dataRestoreNotificationProbe.ResolvedEndpointRoutes[0] -eq 'discord/alerts' -and
            @($dataRestoreNotificationProbe.SentBatches).Count -eq 2 -and
            $dataRestoreNotificationProbe.SentBatches[0].WebhookUrl -eq 'https://example.invalid/alerts' -and
            $dataRestoreNotificationProbe.WarningCount -eq 0
        ) `
        -Name "DataRestore/NotificationCriticalRoutesToAlerts" `
        -Failure "CRITICAL-сповіщення DataRestore має резолвитись через Resolve-BRAVONotificationEndpoint у route 'alerts' і доставлятись через Send-BRAVONotificationChunks без WARNING (fail B19-класу: FAILED-звіт падав у GENERAL через legacy webhook)"

    Test-BRAVOCondition `
        -Condition (
            @($dataRestoreNotificationProbe.ResolvedEndpointRoutes).Count -eq 2 -and
            $dataRestoreNotificationProbe.ResolvedEndpointRoutes[1] -eq 'discord/general' -and
            $dataRestoreNotificationProbe.SentBatches[1].WebhookUrl -eq 'https://example.invalid/general'
        ) `
        -Name "DataRestore/NotificationSuccessRoutesToGeneral" `
        -Failure "SUCCESS-сповіщення DataRestore має резолвитись у route 'general' — каналів рівно два (general/alerts), третього 'legacy'-каналу не існує"

    Test-BRAVOCondition `
        -Condition (
            @($dataRestoreNotificationProbe.SentBatches).Count -eq 2 -and
            $dataRestoreNotificationProbe.SentBatches[0].TimeoutSeconds -eq 7 -and
            $dataRestoreNotificationProbe.SentBatches[1].TimeoutSeconds -eq 7
        ) `
        -Name "DataRestore/NotificationUsesConfiguredRequestTimeout" `
        -Failure "Send-BRAVODataRestoreNotification має передавати NotificationRequestTimeoutSeconds з конфігурації (backupMonitoring) у Send-BRAVONotificationChunks, а не мовчазний дефолт"

    # --- DataRestore: componentSettings.SFTP.Enabled (5.2.2) — фіксація
    # семантики disaster recovery. Глобальний вимикач керує АВТОМАТИЧНИМИ/
    # запланованими операціями та Health-моніторингом; -Source SFTP —
    # явна, ручна дія оператора (default -Source Local) і НЕ має
    # блокуватися master-вимикачем. Ця регресія фіксує інваріант, щоб
    # майбутній рефактор випадково не додав таку залежність.
    Test-BRAVOCondition `
        -Condition (-not $dataRestoreRuntimeTextForTests.Contains('storageEffective')) `
        -Name "DataRestore/SftpRestoreDoesNotDependOnGlobalStorageSwitch" `
        -Failure "modules\BRAVO.DataRestore\BRAVO.DataRestore.Runtime.ps1 не повинен посилатися на storageEffective — явний -Source SFTP лишається доступним незалежно від componentSettings.SFTP.Enabled (disaster recovery не має ставати заручником master-вимикача автоматичних операцій)"

    $bazaReconcileScriptTextForStorageSwitch = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_BAZA_RECONCILE.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (-not $bazaReconcileScriptTextForStorageSwitch.Contains('storageEffective')) `
        -Name "DataRestore/BazaReconcileDoesNotDependOnGlobalStorageSwitch" `
        -Failure "BRAVO_BAZA_RECONCILE.ps1 (операторський, ручний виклик) не повинен посилатися на storageEffective — узгодження мутацій має лишатися доступним незалежно від componentSettings.SFTP.Enabled"
