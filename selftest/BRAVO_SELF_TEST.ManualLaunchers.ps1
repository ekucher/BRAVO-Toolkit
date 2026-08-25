# Домен-фрагмент self-test: ManualLaunchers (генерація root-level .cmd
# launcher-ів BRAVO_SETUP.ps1: New-BRAVOManualLauncherContent /
# Write-BRAVOManualLaunchers / Invoke-BRAVOManualLauncherSetup, scoped
# ExecutionPolicy Bypass, ізоляція BackupRoot). Dot-sourced з кореневого
# BRAVO_SELF_TEST.ps1 -- НЕ запускається напряму. Успадковує з викликача:
# $root, Test-BRAVOCondition, New-BRAVOSelfTestRuntimeModule,
# $script:failures.
#
# ПРИХОВАНІ ЗАЛЕЖНОСТІ (виявлені при розбитті, 2026-08-19): 2 external
# source-text змінні, вперше прочитані набагато раніше в монолітному файлі.
# Локальні перечитування нижче (той самий вміст файлу, immutable протягом
# self-test-прогону).
$setupTextForDiscovery = [IO.File]::ReadAllText(
    (Join-Path $root "BRAVO_SETUP.ps1"),
    [Text.Encoding]::UTF8
)
$archiveScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1"),
    [Text.Encoding]::UTF8
)

        $manualLauncherModule = New-BRAVOSelfTestRuntimeModule `
            -SourceText $setupTextForDiscovery `
            -FunctionNames @(
                'New-BRAVOManualLauncherContent',
                'Write-BRAVOManualLaunchers',
                'Invoke-BRAVOManualLauncherSetup'
            )
        $setupAstForManualLauncher = [Management.Automation.Language.Parser]::ParseInput(
            $setupTextForDiscovery, [ref]$null, [ref]$null
        )
        $manualLauncherFunctionAst = @(
            $setupAstForManualLauncher.FindAll({
                param($candidate)
                $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $candidate.Name -eq 'New-BRAVOManualLauncherContent'
            }, $true)
        ) | Select-Object -First 1
        $manualLauncherFunctionText = if ($null -ne $manualLauncherFunctionAst) {
            $manualLauncherFunctionAst.Extent.Text
        } else { '' }
        Test-BRAVOCondition `
            -Condition (
                @([regex]::Matches($setupTextForDiscovery, '(?i)ExecutionPolicy\s+Bypass')).Count -eq 1 -and
                $manualLauncherFunctionText -match '(?i)ExecutionPolicy\s+Bypass'
            ) `
            -Name 'ManualLaunchers/BypassIsScopedToLauncherGenerator' `
            -Failure 'BRAVO_SETUP.ps1 може містити рівно один ExecutionPolicy Bypass і лише всередині New-BRAVOManualLauncherContent; ширший allowlist був би security-регресією'
        # [IO.Path]::GetTempPath() наслідує %TEMP%, який на локалізованих
        # Windows-установках (реальний DEV-майданчик, 2026-08-24: обліковий
        # запис "Администратор") містить не-ASCII символи в шляху профілю
        # користувача — саме ASCII-чистоту тут перевіряє New-
        # BRAVOManualLauncherContent (навмисно, fail-closed: .cmd-launcher-и
        # з не-ASCII шляхом мають відомі проблеми кодування cmd.exe). Без
        # цього кожен сценарій нижче, включно з тими, що НЕ мають нічого
        # спільного з ASCII-перевіркою, падав би на будь-якій кириличній
        # установці — не через дефект BRAVO, а через випадковий артефакт
        # локалізованого %TEMP%. C:\Windows\Temp не залежить від
        # локалізованого імені користувача і завжди ASCII.
        $manualLauncherTempBase = [IO.Path]::GetTempPath()
        if ($manualLauncherTempBase -cmatch '[^\x00-\x7F]') {
            $manualLauncherTempBase = Join-Path $env:SystemRoot 'Temp'
        }
        $manualLauncherRoot = Join-Path $manualLauncherTempBase (
            'BRAVO_MANUAL_LAUNCHERS_{0}' -f [guid]::NewGuid().ToString('N')
        )
        try {
            $manualRuntimeOne = Join-Path $manualLauncherRoot 'Runtime One'
            $manualRuntimeTwo = Join-Path $manualLauncherRoot 'Runtime Two'
            $manualConfigDirectory = Join-Path $manualLauncherRoot 'Config Path'
            $manualBackupRoot = Join-Path $manualLauncherRoot 'Backup Root'
            [void][IO.Directory]::CreateDirectory($manualRuntimeOne)
            [void][IO.Directory]::CreateDirectory($manualRuntimeTwo)
            [void][IO.Directory]::CreateDirectory($manualConfigDirectory)
            foreach ($runtime in @($manualRuntimeOne, $manualRuntimeTwo)) {
                [IO.File]::WriteAllText((Join-Path $runtime 'BRAVO_ARCHIV.ps1'), '# stub')
                [IO.File]::WriteAllText((Join-Path $runtime 'BRAVO_MAINTENANCE.ps1'), '# stub')
            }
            $manualConfigPath = Join-Path $manualConfigDirectory 'BRAVO.config'
            [IO.File]::WriteAllText($manualConfigPath, '# config')
            $manualSetupOne = [pscustomobject]@{
                BackupRoot = $manualBackupRoot
                Root = $manualRuntimeOne
                ConfigPath = $manualConfigPath
            }
            & $manualLauncherModule {
                param($Setup)
                Invoke-BRAVOManualLauncherSetup -SetupConfiguration $Setup -Action Full
            } $manualSetupOne
            $archiveLauncherPath = Join-Path $manualBackupRoot 'BRAVO_ARCHIV.cmd'
            $maintenanceLauncherPath = Join-Path $manualBackupRoot 'BRAVO_MAINTENANCE.cmd'
            $forceRestoreLauncherPath = Join-Path $manualBackupRoot 'BRAVO_MAINTENANCE_FORCE_RESTORE.cmd'
            $archiveLauncherContent = [IO.File]::ReadAllText($archiveLauncherPath, [Text.Encoding]::ASCII)
            $maintenanceLauncherContent = [IO.File]::ReadAllText($maintenanceLauncherPath, [Text.Encoding]::ASCII)
            $forceRestoreLauncherContent = [IO.File]::ReadAllText($forceRestoreLauncherPath, [Text.Encoding]::ASCII)
            Test-BRAVOCondition `
                -Condition (
                    (Test-Path -LiteralPath $archiveLauncherPath -PathType Leaf) -and
                    (Test-Path -LiteralPath $maintenanceLauncherPath -PathType Leaf) -and
                    (Test-Path -LiteralPath $forceRestoreLauncherPath -PathType Leaf) -and
                    @(Get-ChildItem -LiteralPath $manualBackupRoot -File -Filter 'BRAVO_*.cmd').Count -eq 3 -and
                    @(Get-ChildItem -LiteralPath $manualBackupRoot -File -Filter 'BRAVO_*.bat').Count -eq 0
                ) `
                -Name 'ManualLaunchers/FullSetupCreatesLaunchers' `
                -Failure 'Full Setup має створювати рівно три .cmd launcher без .bat equivalents'
            Test-BRAVOCondition `
                -Condition $archiveLauncherContent.Contains(('"{0}"' -f (Join-Path $manualRuntimeOne 'BRAVO_ARCHIV.ps1'))) `
                -Name 'ManualLaunchers/ArchiveLauncherTargetsEffectiveRuntime' `
                -Failure 'BRAVO_ARCHIV.cmd має посилатися на абсолютний effective RuntimeRoot'
            Test-BRAVOCondition `
                -Condition $maintenanceLauncherContent.Contains(('"{0}"' -f (Join-Path $manualRuntimeOne 'BRAVO_MAINTENANCE.ps1'))) `
                -Name 'ManualLaunchers/MaintenanceLauncherTargetsEffectiveRuntime' `
                -Failure 'BRAVO_MAINTENANCE.cmd має посилатися на абсолютний effective RuntimeRoot'
            Test-BRAVOCondition `
                -Condition (
                    $archiveLauncherContent.Contains(('"{0}"' -f $manualConfigPath)) -and
                    $maintenanceLauncherContent.Contains(('"{0}"' -f $manualConfigPath)) -and
                    $forceRestoreLauncherContent.Contains(('"{0}"' -f $manualConfigPath))
                ) `
                -Name 'ManualLaunchers/UsesEffectiveConfigPath' `
                -Failure 'обидва manual launchers мають передавати effective ConfigPath'
            Test-BRAVOCondition `
                -Condition (
                    $archiveLauncherContent.Contains('"%BRAVO_PS%"') -and
                    $maintenanceLauncherContent.Contains('"%BRAVO_PS%"') -and
                    $archiveLauncherContent.Contains('set "BRAVO_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"') -and
                    $maintenanceLauncherContent.Contains('set "BRAVO_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"') -and
                    $forceRestoreLauncherContent.Contains('set "BRAVO_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"') -and
                    $archiveLauncherContent -match '-File "[^"]+" -ConfigPath "[^"]+"' -and
                    $maintenanceLauncherContent -match '-File "[^"]+" -ConfigPath "[^"]+"' -and
                    $forceRestoreLauncherContent -match '-File "[^"]+" -ConfigPath "[^"]+" -ForceRestore' -and
                    $archiveLauncherContent -notmatch '(?i)-NoPause' -and
                    $maintenanceLauncherContent -notmatch '(?i)-NoPause' -and
                    $forceRestoreLauncherContent -notmatch '(?i)-NoPause'
                ) `
                -Name 'ManualLaunchers/PathsAreQuoted' `
                -Failure 'manual launchers мають містити точний Windows PowerShell 5.1 шлях, quoted paths і не містити -NoPause'
            Test-BRAVOCondition `
                -Condition (
                    $archiveLauncherContent.Contains("`r`n") -and
                    $maintenanceLauncherContent.Contains("`r`n") -and
                    $forceRestoreLauncherContent.Contains("`r`n") -and
                    $archiveLauncherContent -notmatch "(?<!`r)`n" -and
                    $maintenanceLauncherContent -notmatch "(?<!`r)`n" -and
                    $forceRestoreLauncherContent -notmatch "(?<!`r)`n"
                ) `
                -Name 'ManualLaunchers/UsesCrLf' `
                -Failure 'manual launchers мають використовувати CRLF line endings'
            Test-BRAVOCondition `
                -Condition ($archiveLauncherContent.Contains('exit /b %ERRORLEVEL%') -and $maintenanceLauncherContent.Contains('exit /b %ERRORLEVEL%') -and $forceRestoreLauncherContent.Contains('exit /b %ERRORLEVEL%')) `
                -Name 'ManualLaunchers/PropagatesExitCode' `
                -Failure 'manual launchers мають передавати код завершення PowerShell'
            Test-BRAVOCondition `
                -Condition (
                    $archiveLauncherContent -notmatch '(?i)password|webhook|credential|token' -and
                    $maintenanceLauncherContent -notmatch '(?i)password|webhook|credential|token' -and
                    $forceRestoreLauncherContent -notmatch '(?i)password|webhook|credential|token'
                ) `
                -Name 'ManualLaunchers/ContainsNoSecrets' `
                -Failure 'manual launchers не повинні містити credential або secret значень'
            Test-BRAVOCondition `
                -Condition (-not $archiveLauncherContent.Contains('choice /C YN') -and -not $maintenanceLauncherContent.Contains('choice /C YN')) `
                -Name 'ManualLaunchers/NormalArchiveHasNoConfirmation' `
                -Failure 'normal Archive/Maintenance launchers не повинні запитувати confirmation'
            Test-BRAVOCondition `
                -Condition (-not $maintenanceLauncherContent.Contains('choice /C YN')) `
                -Name 'ManualLaunchers/NormalMaintenanceHasNoConfirmation' `
                -Failure 'normal Maintenance launcher не повинен запитувати confirmation'
            Test-BRAVOCondition `
                -Condition (Test-Path -LiteralPath $forceRestoreLauncherPath -PathType Leaf) `
                -Name 'ManualLaunchers/ForceRestoreLauncherExists' `
                -Failure 'Full Setup має створювати Force Restore launcher'
            Test-BRAVOCondition `
                -Condition $forceRestoreLauncherContent.Contains(('"{0}"' -f (Join-Path $manualRuntimeOne 'BRAVO_MAINTENANCE.ps1'))) `
                -Name 'ManualLaunchers/ForceRestoreTargetsMaintenance' `
                -Failure 'Force Restore launcher має запускати BRAVO_MAINTENANCE.ps1'
            Test-BRAVOCondition `
                -Condition $forceRestoreLauncherContent.Contains(('"{0}"' -f $manualConfigPath)) `
                -Name 'ManualLaunchers/ForceRestoreUsesEffectiveConfigPath' `
                -Failure 'Force Restore launcher має передавати effective ConfigPath'
            Test-BRAVOCondition `
                -Condition (@([regex]::Matches($forceRestoreLauncherContent, '(?<!\S)-ForceRestore(?!\S)')).Count -eq 1) `
                -Name 'ManualLaunchers/ForceRestoreArgumentPresentExactlyOnce' `
                -Failure 'Force Restore launcher має містити рівно один -ForceRestore'
            Test-BRAVOCondition `
                -Condition ($forceRestoreLauncherContent.Contains('choice /C YN /N /M "Continue? [Y/N]: "') -and $forceRestoreLauncherContent.Contains('if errorlevel 2 exit /b 0')) `
                -Name 'ManualLaunchers/ForceRestoreRequiresConfirmation' `
                -Failure 'Force Restore launcher має вимагати Y/N confirmation'
            $choiceIndex = $forceRestoreLauncherContent.IndexOf(
                'choice /C YN /N /M "Continue? [Y/N]: "'
            )
            $cancelIndex = $forceRestoreLauncherContent.IndexOf(
                'if errorlevel 2 exit /b 0'
            )
            $powerShellInvokeIndex = $forceRestoreLauncherContent.IndexOf(
                '"%BRAVO_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass'
            )
            Test-BRAVOCondition `
                -Condition (
                    $choiceIndex -ge 0 -and
                    $cancelIndex -gt $choiceIndex -and
                    $powerShellInvokeIndex -gt $cancelIndex
                ) `
                -Name 'ManualLaunchers/ForceRestoreCancelExitsBeforePowerShell' `
                -Failure 'скасування Force Restore має завершуватись до запуску PowerShell'
            Test-BRAVOCondition `
                -Condition ($forceRestoreLauncherContent -notmatch '(?i)-DisableSizeCheck|-NoPause|-RunMissedRestoreOnly|-AutoShutdown|-ArchiveAfterMaintenance|-EnableAllSlack|-DisableAllSlack') `
                -Name 'ManualLaunchers/ForceRestoreDoesNotDisableSizeCheck' `
                -Failure 'Force Restore launcher не може вимикати normal safety checks або додавати overrides'
            Test-BRAVOCondition `
                -Condition ($forceRestoreLauncherContent -notmatch '(?i)-NoPause') `
                -Name 'ManualLaunchers/ForceRestoreDoesNotContainNoPause' `
                -Failure 'Force Restore launcher не може містити -NoPause'
            Test-BRAVOCondition `
                -Condition ($forceRestoreLauncherContent -notmatch '(?i)-RunMissedRestoreOnly') `
                -Name 'ManualLaunchers/ForceRestoreDoesNotUseRunMissedRestoreOnly' `
                -Failure 'Force Restore launcher не може містити -RunMissedRestoreOnly'
            Test-BRAVOCondition `
                -Condition $forceRestoreLauncherContent.Contains('exit /b %ERRORLEVEL%') `
                -Name 'ManualLaunchers/ForceRestorePropagatesExitCode' `
                -Failure 'Force Restore launcher має передавати PowerShell exit code'
            Test-BRAVOCondition `
                -Condition ($forceRestoreLauncherContent -notmatch '(?i)password|webhook|credential|token') `
                -Name 'ManualLaunchers/ForceRestoreContainsNoSecrets' `
                -Failure 'Force Restore launcher не може містити secrets'
            $validateOnlyRoot = Join-Path $manualLauncherRoot 'Validate Only Root'
            $manualValidateOnly = [pscustomobject]@{
                BackupRoot = $validateOnlyRoot
                Root = $manualRuntimeOne
                ConfigPath = $manualConfigPath
            }
            & $manualLauncherModule {
                param($Setup)
                Invoke-BRAVOManualLauncherSetup -SetupConfiguration $Setup -Action Full -ValidateOnly
            } $manualValidateOnly
            Test-BRAVOCondition `
                -Condition (-not (Test-Path -LiteralPath $validateOnlyRoot)) `
                -Name 'ManualLaunchers/ValidateOnlyDoesNotWrite' `
                -Failure 'ValidateOnly не має створювати BackupRoot або manual launchers'
            $manualSetupTwo = [pscustomobject]@{
                BackupRoot = $manualBackupRoot
                Root = $manualRuntimeTwo
                ConfigPath = $manualConfigPath
            }
            & $manualLauncherModule {
                param($Setup)
                Invoke-BRAVOManualLauncherSetup -SetupConfiguration $Setup -Action Full
            } $manualSetupTwo
            $updatedArchiveLauncherContent = [IO.File]::ReadAllText($archiveLauncherPath, [Text.Encoding]::ASCII)
            $updatedMaintenanceLauncherContent = [IO.File]::ReadAllText($maintenanceLauncherPath, [Text.Encoding]::ASCII)
            $updatedForceRestoreLauncherContent = [IO.File]::ReadAllText($forceRestoreLauncherPath, [Text.Encoding]::ASCII)
            Test-BRAVOCondition `
                -Condition (
                    $updatedArchiveLauncherContent.Contains($manualRuntimeTwo) -and
                    $updatedMaintenanceLauncherContent.Contains($manualRuntimeTwo) -and
                    $updatedForceRestoreLauncherContent.Contains($manualRuntimeTwo) -and
                    -not $updatedArchiveLauncherContent.Contains($manualRuntimeOne) -and
                    -not $updatedMaintenanceLauncherContent.Contains($manualRuntimeOne) -and
                    -not $updatedForceRestoreLauncherContent.Contains($manualRuntimeOne)
                ) `
                -Name 'ManualLaunchers/RerunUpdatesChangedRuntimePath' `
                -Failure 'повторний Setup має оновлювати launcher після зміни RuntimeRoot'
            $manualConfigPathTwo = Join-Path $manualConfigDirectory 'BRAVO second.config'
            [IO.File]::WriteAllText($manualConfigPathTwo, '# second config')
            $manualSetupThree = [pscustomobject]@{
                BackupRoot = $manualBackupRoot
                Root = $manualRuntimeTwo
                ConfigPath = $manualConfigPathTwo
            }
            & $manualLauncherModule {
                param($Setup)
                Invoke-BRAVOManualLauncherSetup -SetupConfiguration $Setup -Action Full
            } $manualSetupThree
            $updatedArchiveLauncherContent = [IO.File]::ReadAllText($archiveLauncherPath, [Text.Encoding]::ASCII)
            $updatedMaintenanceLauncherContent = [IO.File]::ReadAllText($maintenanceLauncherPath, [Text.Encoding]::ASCII)
            $updatedForceRestoreLauncherContent = [IO.File]::ReadAllText($forceRestoreLauncherPath, [Text.Encoding]::ASCII)
            Test-BRAVOCondition `
                -Condition (
                    $updatedArchiveLauncherContent.Contains($manualConfigPathTwo) -and
                    $updatedMaintenanceLauncherContent.Contains($manualConfigPathTwo) -and
                    $updatedForceRestoreLauncherContent.Contains($manualConfigPathTwo) -and
                    -not $updatedArchiveLauncherContent.Contains($manualConfigPath) -and
                    -not $updatedMaintenanceLauncherContent.Contains($manualConfigPath) -and
                    -not $updatedForceRestoreLauncherContent.Contains($manualConfigPath)
                ) `
                -Name 'ManualLaunchers/RerunUpdatesChangedConfigPath' `
                -Failure 'зміна ConfigPath має переписувати обидва manual launchers'
            foreach ($action in @('Test', 'Credentials', 'Scheduler')) {
                $actionRoot = Join-Path $manualLauncherRoot ("{0} Action Root" -f $action)
                $actionSetup = [pscustomobject]@{
                    BackupRoot = $actionRoot
                    Root = $manualRuntimeOne
                    ConfigPath = $manualConfigPath
                }
                & $manualLauncherModule {
                    param($Setup, $Action)
                    Invoke-BRAVOManualLauncherSetup -SetupConfiguration $Setup -Action $Action
                } $actionSetup $action
                Test-BRAVOCondition `
                    -Condition (-not (Test-Path -LiteralPath $actionRoot)) `
                    -Name ("ManualLaunchers/{0}ActionDoesNotWrite" -f $action) `
                    -Failure ("Setup Action={0} не має створювати BackupRoot або manual launchers" -f $action)
            }
            $nonAsciiRuntime = Join-Path $manualLauncherRoot ('Runtime ' + [char]0x0416)
            [void][IO.Directory]::CreateDirectory($nonAsciiRuntime)
            [IO.File]::WriteAllText((Join-Path $nonAsciiRuntime 'BRAVO_ARCHIV.ps1'), '# stub')
            [IO.File]::WriteAllText((Join-Path $nonAsciiRuntime 'BRAVO_MAINTENANCE.ps1'), '# stub')
            $nonAsciiBackupRoot = Join-Path $manualLauncherRoot 'NonAscii Launcher Root'
            $nonAsciiSetup = [pscustomobject]@{
                BackupRoot = $nonAsciiBackupRoot
                Root = $nonAsciiRuntime
                ConfigPath = $manualConfigPath
            }
            $nonAsciiLauncherFailed = $false
            try {
                & $manualLauncherModule {
                    param($Setup)
                    Invoke-BRAVOManualLauncherSetup -SetupConfiguration $Setup -Action Full
                } $nonAsciiSetup
            } catch {
                $nonAsciiLauncherFailed = $_.Exception.Message -match 'не-ASCII'
            }
            Test-BRAVOCondition `
                -Condition ($nonAsciiLauncherFailed -and -not (Test-Path -LiteralPath $nonAsciiBackupRoot)) `
                -Name 'ManualLaunchers/NonAsciiEmbeddedPathFailsClosed' `
                -Failure 'non-ASCII RuntimeRoot або ConfigPath має зупиняти генерацію launcher без ASCII corruption'
            Test-BRAVOCondition `
                -Condition (
                    (Get-Item -LiteralPath $archiveLauncherPath).Name -notlike 'BRAVO_BACKUP_*.json' -and
                    (Get-Item -LiteralPath $maintenanceLauncherPath).Name -notlike 'BRAVO_BACKUP_*.json' -and
                    (Get-Item -LiteralPath $forceRestoreLauncherPath).Name -notlike 'BRAVO_BACKUP_*.json' -and
                    $archiveScriptText.Contains('Get-BRAVOBackupGenerationManifestFiles -BackupRoot $BackupRoot')
                ) `
                -Name 'ManualLaunchers/BackupRootFilesDoNotEnterGeneration' `
                -Failure 'root-level .cmd launchers не можуть бути manifest generation або backup artifacts'
        } finally {
            Remove-Item -LiteralPath $manualLauncherRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
