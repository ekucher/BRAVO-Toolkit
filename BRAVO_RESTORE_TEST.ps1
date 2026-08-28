[CmdletBinding()]
param(
    [string]$ConfigPath,

    [string]$GenerationId,

    [ValidateSet("MODEL", "BLOG", "BRAVOEXCH", "All")]
    [string]$Component = "All",

    [int]$MinimumFileCount = 1,
    [int]$TimeoutSeconds = 3600,
    [string]$ResultPath,
    [switch]$AsJson,
    [switch]$SkipNotification,
    [switch]$NoElevation
)

$helperLoggingPath = Join-Path $PSScriptRoot "modules\BRAVO.HelperLogging\BRAVO.HelperLogging.psd1"
Import-Module -Name $helperLoggingPath -ErrorAction Stop
$null = Start-BRAVOHelperLog `
    -ScriptPath $PSCommandPath `
    -ConfigPath $ConfigPath `
    -QuietConsole:$AsJson

# AUD-004 (аудит P0.4): restore drill. Читабельний і навіть SHA512/7za-
# перевірений архів НЕ доводить, що він відновлюється — лише що байти не
# пошкоджені. Цей скрипт бере найновіший локальний backup із коректним
# hash-sidecar для кожного увімкненого компонента (MODEL/BLOG/BRAVOEXCH)
# з одного COMPLETE GenerationId,
# розпаковує його в ІЗОЛЬОВАНИЙ тимчасовий каталог (не production-шлях),
# рахує розпаковані файли/каталоги проти мінімального порогу, прибирає за
# собою і повертає JSON-результат + опційне сповіщення. Це read-only
# діагностика: не видаляє, не переміщує й не змінює жоден існуючий backup.

$ErrorActionPreference = "Stop"
$script:restoreDrillResults = New-Object System.Collections.ArrayList

function Add-RestoreDrillResult {
    param(
        [ValidateSet("PASS", "WARN", "FAIL")]
        [string]$Status,
        [string]$Component,
        [string]$ArchiveName,
        [Nullable[double]]$DurationSeconds,
        [int]$ExtractedFileCount = 0,
        [int]$ExtractedDirectoryCount = 0,
        [string]$Detail
    )

    [void]$script:restoreDrillResults.Add([pscustomobject]@{
        Status = $Status
        Component = $Component
        ArchiveName = $ArchiveName
        DurationSeconds = $DurationSeconds
        ExtractedFileCount = $ExtractedFileCount
        ExtractedDirectoryCount = $ExtractedDirectoryCount
        Detail = $Detail
        GenerationId = $script:selectedRestoreGenerationId
        CheckedAt = (Get-Date).ToString("o")
    })
}

# Операторська консоль (docs/OPERATOR_CONSOLE_UX.md §4) — суто рендер поверх
# уже зібраного Add-RestoreDrillResult; -AsJson не викликає цю функцію
# взагалі, тому JSON-контракт (-ResultPath/stdout) лишається незмінним.
function Write-BRAVORestoreDrillStep {
    param(
        [Parameter(Mandatory = $true)][int]$Current,
        [Parameter(Mandatory = $true)][int]$Total,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'WARN', 'FAIL')][string]$Status,
        [Nullable[double]]$DurationSeconds,
        [string]$ArchiveName,
        [Nullable[bool]]$IntegrityOk,
        [Nullable[int]]$ExtractedFileCount,
        [Nullable[int]]$ExtractedDirectoryCount,
        [string]$Reason
    )

    $duration = if ($null -ne $DurationSeconds) { [timespan]::FromSeconds($DurationSeconds) } else { $null }
    Write-BRAVOStepResult -Current $Current -Total $Total -Name $Name -Status $Status -Duration $duration

    # SHA512 тут завжди "OK": Find-BRAVOLatestVerifiedArchive вже перевірив
    # sidecar-хеш ДО того, як ця функція взагалі дізналась про ArchiveName
    # — інакше компонент потрапив би у WARN "жодного backup" без імені файлу.
    if (-not [string]::IsNullOrWhiteSpace($ArchiveName)) {
        Write-BRAVOConsoleDetail -Message ("Архів:     {0}" -f $ArchiveName)
        Write-BRAVOConsoleDetail -Message 'SHA512:    OK'
    }
    if ($null -ne $IntegrityOk) {
        Write-BRAVOConsoleDetail -Message ("Integrity: {0}" -f $(if ($IntegrityOk) { 'OK' } else { 'FAIL' }))
    }
    if ($null -ne $ExtractedFileCount) {
        Write-BRAVOConsoleDetail -Message ("Розпаковано: {0} файлів / {1} каталогів" -f $ExtractedFileCount, $ExtractedDirectoryCount)
    }
    if ($Status -ne 'PASS' -and -not [string]::IsNullOrWhiteSpace($Reason)) {
        Write-BRAVOOperatorReason -Reason $Reason
    }
    Write-BRAVOResultBlankLine
}

function Set-BRAVORestoreDrillDirectoryAcl {
    # Той самий патерн, що BRAVO_TASKS_DIAGNOSE.ps1 використовує для своїх
    # ізольованих робочих каталогів: лише SYSTEM і Administrators.
    param([string]$Path)

    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $none = [Security.AccessControl.PropagationFlags]::None
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleAll($rule)
    }
    # SYSTEM + Administrators (як у BRAVO_TASKS_DIAGNOSE.ps1) — захист
    # видобутих даних LIMS від інших користувачів машини. На відміну від
    # TASKS_DIAGNOSE, цей скрипт НЕ вимагає елевації (read-only diagnostic,
    # той самий підхід, що BRAVO_DRY_RUN.ps1), тому явно додаємо SID
    # поточного облікового запису — інакше неелевований адміністратор
    # (в групі Administrators, але без UAC split-token) втрачає доступ до
    # щойно створеного каталогу.
    $currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $accessSids = @("S-1-5-18", "S-1-5-32-544") + @([string]$currentUserSid) | Select-Object -Unique
    foreach ($sidText in $accessSids) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidText)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $none,
            $allow
        )))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Format-RestoreFileCount {
    param([int]$Count)

    $lastTwoDigits = [math]::Abs($Count) % 100
    $lastDigit = [math]::Abs($Count) % 10
    $word = if ($lastTwoDigits -ge 11 -and $lastTwoDigits -le 14) {
        "файлів"
    } elseif ($lastDigit -eq 1) {
        "файл"
    } elseif ($lastDigit -ge 2 -and $lastDigit -le 4) {
        "файли"
    } else {
        "файлів"
    }
    return "$Count $word"
}

# Get-BRAVORestoreGenerationManifest (вибір COMPLETE generation) і
# Get-BRAVOVerifiedGenerationArchive (строгий per-component gate: прапорці
# manifest + sidecar + фактичний SHA512) живуть у modules\BRAVO.ArchiveHelpers
# — спільний selector/gate для BRAVO_RESTORE_TEST і BRAVO_DATA_RESTORE, щоб
# drill і реальне відновлення вибирали generation за одними правилами.

try {
    $scriptDirectory = if ($PSCommandPath) {
        Split-Path $PSCommandPath -Parent
    } else {
        [Environment]::CurrentDirectory
    }
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $scriptDirectory "BRAVO.config"
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "файл конфігурації не знайдено: $ConfigPath"
    }
    $resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $configRoot = Split-Path $resolvedConfigPath -Parent
    $runtimeRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path

    foreach ($moduleName in @('BRAVO.Compatibility', 'BRAVO.Credentials', 'BRAVO.ExitCodes', 'BRAVO.Console', 'BRAVO.Notifications')) {
        $modulePath = Join-Path $runtimeRoot "modules\$moduleName\$moduleName.psd1"
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            throw "Не знайдено спільний PowerShell-модуль: $modulePath"
        }
        Import-Module -Name $modulePath -ErrorAction Stop
    }
    $archiveHelpersPath = Join-Path $runtimeRoot 'modules\BRAVO.ArchiveHelpers\BRAVO.ArchiveHelpers.psd1'
    if (-not (Test-Path -LiteralPath $archiveHelpersPath -PathType Leaf)) {
        throw "Не знайдено PowerShell-модуль archive helpers: $archiveHelpersPath"
    }
    Import-Module -Name $archiveHelpersPath -ErrorAction Stop

    $configurationLoaderPath = Join-Path $runtimeRoot 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Не знайдено BRAVO_CONFIG_LOADER.ps1: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    Import-BravoConfiguration -ConfigRoot $configRoot -ConfigPath $resolvedConfigPath -RuntimeRoot $runtimeRoot

    if ([string]::IsNullOrWhiteSpace([string]$arcPath) -or
        -not (Test-Path -LiteralPath $arcPath -PathType Leaf)) {
        throw "7za.exe не знайдено: $arcPath"
    }

    $archiveCredentialTarget = [string]$credentialSettings.Targets.ArchivePassword
    if ([string]::IsNullOrWhiteSpace($archiveCredentialTarget)) {
        $archiveCredentialTarget = "BRAVO_7Z_PASSWORD"
    }
    Initialize-BRAVOCredentialManager
    $archivePassword = Get-BRAVOCredentialSecret -Target $archiveCredentialTarget
    if ([string]::IsNullOrWhiteSpace($archivePassword)) {
        throw "пароль архіву не знайдено в Credential Manager (target '$archiveCredentialTarget') для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    }

    $componentsToCheck = @($global:archiveDefinitions | Where-Object {
        [bool]$_.Enabled -and
        ($Component -eq "All" -or [string]$_.Type -eq $Component)
    })
    $selectedGeneration = $null
    try {
        $selectedGeneration = Get-BRAVORestoreGenerationManifest `
            -BackupRoot $backupRootPath `
            -RequestedGenerationId $GenerationId
        # Аномалії fail-closed-пропуску під час автоматичного вибору
        # (нечитабельний manifest / identity mismatch) — видимий WARN:
        # тихий пропуск означав би непомічену перевірку старішої generation.
        foreach ($skippedManifest in @($selectedGeneration.SkippedManifests)) {
            Add-RestoreDrillResult WARN 'Generation' $null $null 0 0 (
                "manifest пропущено під час вибору generation: $($skippedManifest.ManifestPath) — $($skippedManifest.Reason)")
        }
        $script:selectedRestoreGenerationId = [string]$selectedGeneration.Manifest.generationId
        if ([string]::IsNullOrWhiteSpace($script:selectedRestoreGenerationId)) {
            throw "selected COMPLETE generation manifest не містить GenerationId: $($selectedGeneration.ManifestPath)"
        }
    } catch {
        $script:selectedRestoreGenerationId = $GenerationId
        Add-RestoreDrillResult FAIL 'Generation' $null $null 0 0 $_.Exception.Message
        $componentsToCheck = @()
    }

    # Post-round-7 follow-up (P2, review 4945879933): та сама rebasing-
    # політика, яку BRAVO_DATA_RESTORE застосовує до Local-джерела ДО
    # строгого gate (Get-BRAVOVerifiedGenerationArchive нижче) — інакше
    # relocated local backup repository (скопійований/змонтований під
    # іншим диском/коренем) проходив би реальне відновлення, але
    # провалював би цей drill: manifest.ArchivePath/HashPath, записані
    # ПРОДЮСЕРОМ, фізично не існують за старою адресою. Canonical
    # ConvertTo-BRAVORebasedLocalGenerationManifest (BRAVO.ArchiveHelpers)
    # переписує їх на canonical каталог компонента + validated leaf-ім'я
    # ДО того, як Get-BRAVOVerifiedGenerationArchive нижче виконає
    # containment/generation/hash перевірки — той самий canonical
    # implementation, що й BRAVO_DATA_RESTORE, жодної окремої копії.
    if ($componentsToCheck.Count -gt 0 -and $null -ne $selectedGeneration) {
        $selectedGeneration.Manifest = ConvertTo-BRAVORebasedLocalGenerationManifest `
            -Manifest $selectedGeneration.Manifest `
            -ComponentTypes @($componentsToCheck | ForEach-Object { [string]$_.Type }) `
            -ArchiveDefinitions @($global:archiveDefinitions)
    }

    # Заголовок друкується один раз, одразу як відомо, скільки компонентів
    # реально перевірятиметься — той самий каркас, що Archive/Health
    # (docs/OPERATOR_CONSOLE_UX.md §1). -AsJson лишається повністю тихим,
    # як і раніше (жодного виклику BRAVO.Console нижче в цій гілці).
    if (-not $AsJson) {
        Initialize-BRAVOConsole
        # Restore Test не малює Write-Progress — без цього Write-BRAVOHeader
        # резервує 6 порожніх рядків під прогрес-бар, якого тут немає.
        Initialize-BRAVOProgress -Enabled $false
        Write-BRAVOHeader `
            -Title ("BRAVO Restore Test {0}" -f $global:ScriptVersion) `
            -Institution ([string]$bravoSettings.InstitutionName) `
            -InstitutionCode ([string]$bravoSettings.InstitutionCode) `
            -Mode 'READ-ONLY / ISOLATED RESTORE'
    }

    if ($componentsToCheck.Count -eq 0 -and $script:restoreDrillResults.Count -eq 0) {
        Add-RestoreDrillResult WARN $Component $null $null 0 0 (
            "жодного увімкненого компонента для перевірки (Component='$Component')"
        )
        if (-not $AsJson) {
            Write-BRAVOOperatorReason -Reason "Жодного увімкненого компонента для перевірки (Component='$Component')"
        }
    }

    $drillRoot = Join-Path ([Environment]::GetFolderPath("CommonApplicationData")) "BRAVO\RestoreDrill"
    if (-not (Test-Path -LiteralPath $drillRoot -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $drillRoot -Force)
    }

    $restoreDrillStepCurrent = 0
    foreach ($archiveDefinition in $componentsToCheck) {
        $restoreDrillStepCurrent++
        $componentName = [string]$archiveDefinition.Type
        $latestArchive = $null
        try {
            $latestArchive = Get-BRAVOVerifiedGenerationArchive `
                -Manifest $selectedGeneration.Manifest `
                -Component $componentName `
                -NameTemplate ([string]$archiveDefinition.NameTemplate) `
                -ComponentDirectory ([string]$archiveDefinition.Destination)
        } catch {
            Add-RestoreDrillResult FAIL $componentName $null $null 0 0 $_.Exception.Message
            if (-not $AsJson) {
                Write-BRAVORestoreDrillStep `
                    -Current $restoreDrillStepCurrent -Total $componentsToCheck.Count `
                    -Name $componentName -Status FAIL `
                    -Reason $_.Exception.Message
            }
            continue
        }

        $workingDirectory = Join-Path $drillRoot ([guid]::NewGuid().ToString("N"))
        $startedAt = Get-Date
        try {
            [void](New-Item -ItemType Directory -Path $workingDirectory -Force)
            Set-BRAVORestoreDrillDirectoryAcl -Path $workingDirectory

            $integrityOk = Test-SevenZipArchiveIntegrity `
                -SevenZipPath $arcPath `
                -ArchivePath $latestArchive.FullName `
                -Password $archivePassword `
                -TimeoutSeconds $TimeoutSeconds
            if (-not $integrityOk) {
                $integrityDurationSeconds = ((Get-Date) - $startedAt).TotalSeconds
                Add-RestoreDrillResult FAIL $componentName $latestArchive.Name (
                    $integrityDurationSeconds
                ) 0 0 "7za t (перевірка цілісності) не пройдено"
                if (-not $AsJson) {
                    Write-BRAVORestoreDrillStep `
                        -Current $restoreDrillStepCurrent -Total $componentsToCheck.Count `
                        -Name $componentName -Status FAIL -DurationSeconds $integrityDurationSeconds `
                        -ArchiveName $latestArchive.Name -IntegrityOk $false `
                        -Reason '7za t (перевірка цілісності) не пройдено'
                }
                continue
            }

            $extractionResult = Invoke-BRAVOSevenZipExtraction `
                -SevenZipPath $arcPath `
                -ArchivePath $latestArchive.FullName `
                -Password $archivePassword `
                -ExtractDirectory $workingDirectory `
                -TimeoutSeconds $TimeoutSeconds
            if (-not $extractionResult.Success) {
                $extractionDurationSeconds = ((Get-Date) - $startedAt).TotalSeconds
                Add-RestoreDrillResult FAIL $componentName $latestArchive.Name (
                    $extractionDurationSeconds
                ) 0 0 "розпакування не вдалося: $($extractionResult.Description)"
                if (-not $AsJson) {
                    Write-BRAVORestoreDrillStep `
                        -Current $restoreDrillStepCurrent -Total $componentsToCheck.Count `
                        -Name $componentName -Status FAIL -DurationSeconds $extractionDurationSeconds `
                        -ArchiveName $latestArchive.Name -IntegrityOk $true `
                        -Reason "Розпакування не вдалося: $($extractionResult.Description)"
                }
                continue
            }

            $extractedFiles = @(Get-ChildItem -LiteralPath $workingDirectory -Recurse -File -ErrorAction SilentlyContinue)
            $extractedDirectories = @(Get-ChildItem -LiteralPath $workingDirectory -Recurse -Directory -ErrorAction SilentlyContinue)
            $durationSeconds = ((Get-Date) - $startedAt).TotalSeconds

            if ($extractedFiles.Count -lt $MinimumFileCount) {
                $extractedFilesText = Format-RestoreFileCount -Count $extractedFiles.Count
                Add-RestoreDrillResult FAIL $componentName $latestArchive.Name $durationSeconds `
                    $extractedFiles.Count $extractedDirectories.Count (
                    "розпаковано лише $extractedFilesText, очікувалося щонайменше $MinimumFileCount — можлива архівація не того джерела"
                )
                if (-not $AsJson) {
                    Write-BRAVORestoreDrillStep `
                        -Current $restoreDrillStepCurrent -Total $componentsToCheck.Count `
                        -Name $componentName -Status FAIL -DurationSeconds $durationSeconds `
                        -ArchiveName $latestArchive.Name -IntegrityOk $true `
                        -ExtractedFileCount $extractedFiles.Count -ExtractedDirectoryCount $extractedDirectories.Count `
                        -Reason "Розпаковано лише $extractedFilesText, очікувалося щонайменше $MinimumFileCount"
                }
            } else {
                Add-RestoreDrillResult PASS $componentName $latestArchive.Name $durationSeconds `
                    $extractedFiles.Count $extractedDirectories.Count (
                    "успішно розпаковано й перевірено"
                )
                if (-not $AsJson) {
                    Write-BRAVORestoreDrillStep `
                        -Current $restoreDrillStepCurrent -Total $componentsToCheck.Count `
                        -Name $componentName -Status PASS -DurationSeconds $durationSeconds `
                        -ArchiveName $latestArchive.Name -IntegrityOk $true `
                        -ExtractedFileCount $extractedFiles.Count -ExtractedDirectoryCount $extractedDirectories.Count
                }
            }
        } catch {
            $catchDurationSeconds = ((Get-Date) - $startedAt).TotalSeconds
            Add-RestoreDrillResult FAIL $componentName $latestArchive.Name (
                $catchDurationSeconds
            ) 0 0 $_.Exception.Message
            if (-not $AsJson) {
                Write-BRAVORestoreDrillStep `
                    -Current $restoreDrillStepCurrent -Total $componentsToCheck.Count `
                    -Name $componentName -Status FAIL -DurationSeconds $catchDurationSeconds `
                    -ArchiveName $latestArchive.Name `
                    -Reason $_.Exception.Message
            }
        } finally {
            if (Test-Path -LiteralPath $workingDirectory) {
                Remove-Item -LiteralPath $workingDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $SkipNotification) {
        $notificationMode = ([string]$bravoSettings.NotificationMode).Trim().ToLowerInvariant()
        $failCount = @($script:restoreDrillResults | Where-Object { $_.Status -eq "FAIL" }).Count
        $warnCount = @($script:restoreDrillResults | Where-Object { $_.Status -eq "WARN" }).Count
        if ($notificationMode -ne "none" -and ($failCount -gt 0 -or $warnCount -gt 0)) {
            try {
                $notificationProvider = ([string]$bravoSettings.NotificationProvider).Trim().ToLowerInvariant()
                if ($notificationProvider -ne "discord" -and $notificationProvider -ne "slack") {
                    $notificationProvider = "discord"
                }
                # 5.2.1: drill іде через канонічний конвеєр BRAVO.Notifications
                # (маршрут за severity + route-специфічний credential +
                # payload-guard/chunking) — жодного власного вибору webhook
                # чи прямого legacy provider-wide lookup.
                $severity = if ($failCount -gt 0) { "CRITICAL" } else { "WARNING" }
                $notificationRoute = Resolve-BRAVONotificationRoute `
                    -Severity $severity `
                    -NotificationMode $notificationMode `
                    -RoutingTable $backupMonitoring.NotificationRouting
                if ($notificationRoute -ne "none") {
                    $webhookUrl = Resolve-BRAVONotificationEndpoint `
                        -Provider $notificationProvider `
                        -Route $notificationRoute `
                        -CredentialTargets $credentialSettings.Targets
                    $summaryLines = @($script:restoreDrillResults | ForEach-Object {
                        "[$($_.Status)] $($_.Component): $($_.Detail)"
                    })
                    $message = New-BRAVOOperatorNotificationMessage `
                        -Severity $severity `
                        -Operation "BRAVO RESTORE DRILL — ПОТРІБНА ДІЯ" `
                        -ActionText "перевірити restore drill і журнал відновлення." `
                        -InstitutionName ([string]$bravoSettings.InstitutionName) `
                        -InstitutionCode ([string]$bravoSettings.InstitutionCode) `
                        -HostInformation (Get-HostInformation) `
                        -ResultLines (@("FAIL: $failCount, WARN: $warnCount") + $summaryLines) `
                        -Timestamp (Get-Date) `
                        -ProductName "BRAVO Restore Drill" `
                        -Version ([string]$global:ScriptVersion) `
                        -BuildId ([string]$global:ScriptBuildId)
                    $messageChunks = ConvertTo-BRAVONotificationPayloadText `
                        -Provider $notificationProvider `
                        -Message $message
                    Send-BRAVONotificationChunks `
                        -Provider $notificationProvider `
                        -WebhookUrl $webhookUrl `
                        -MessageChunks $messageChunks `
                        -TimeoutSeconds ([int]$bravoSettings.NotificationRequestTimeoutSeconds)
                }
            } catch {
                Add-RestoreDrillResult WARN "Сповіщення" $null $null 0 0 $_.Exception.Message
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        $jsonResult = $script:restoreDrillResults | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($ResultPath, $jsonResult, (New-Object System.Text.UTF8Encoding($false)))
    }

    # Код завершення обчислюється ДО друку підсумку (той самий принцип, що
    # в Archive/Health) — сама умова не змінена, лише перенесена вище.
    $failureCount = @($script:restoreDrillResults | Where-Object { $_.Status -eq "FAIL" }).Count
    $warningCount = @($script:restoreDrillResults | Where-Object { $_.Status -eq "WARN" }).Count
    $passCount = @($script:restoreDrillResults | Where-Object { $_.Status -eq "PASS" }).Count
    $exitCode = Resolve-BRAVOExitCode `
        -IntegrityTestFailed:($failureCount -gt 0) `
        -HasWarnings:($warningCount -gt 0 -and $failureCount -eq 0)

    if ($AsJson) {
        $script:restoreDrillResults | ConvertTo-Json -Depth 5 | Write-Output
    } else {
        $restoreDrillStatus = if ($failureCount -gt 0) { 'ПОМИЛКА' } elseif ($warningCount -gt 0) { 'ЧАСТКОВО' } else { 'УСПІШНО' }
        $restoreDrillStatusColor = switch ($restoreDrillStatus) {
            'УСПІШНО'  { [ConsoleColor]::Green }
            'ЧАСТКОВО' { [ConsoleColor]::Yellow }
            default    { [ConsoleColor]::Red }
        }
        Write-BRAVOResultHeader `
            -Status $restoreDrillStatus `
            -StatusColor $restoreDrillStatusColor `
            -ExitCode $exitCode `
            -ExitCodeName (Get-BRAVOExitCodeName -Code $exitCode)
        $totalChecked = [Math]::Max($componentsToCheck.Count, $script:restoreDrillResults.Count)
        Write-BRAVOResultField -Label 'Перевірено' -Value ("{0} з {1}" -f $script:restoreDrillResults.Count, $totalChecked)
        Write-BRAVOResultField -Label 'GenerationId' -Value $(if ([string]::IsNullOrWhiteSpace($script:selectedRestoreGenerationId)) { 'не вибрано' } else { $script:selectedRestoreGenerationId })
        Write-BRAVOResultField -Label 'PASS' -Value ([string]$passCount)
        Write-BRAVOResultField -Label 'WARN' -Value ([string]$warningCount)
        Write-BRAVOResultField -Label 'FAIL' -Value ([string]$failureCount)
        Write-BRAVOResultBlankLine
        if ($failureCount -gt 0) {
            Write-BRAVOResultNote -Text ("Restore test виявив проблеми з відновленням {0} з {1} компонентів." -f $failureCount, $totalChecked)
        } elseif ($warningCount -gt 0) {
            Write-BRAVOResultNote -Text 'Restore test не зміг перевірити частину компонентів (немає верифікованого backup).'
        } else {
            Write-BRAVOResultNote -Text 'Restore test підтвердив можливість розпакування резервних копій.'
        }
        Write-BRAVOResultNote -Text 'Production-дані не змінювались.'
        Write-BRAVOResultFooter
    }
    Complete-BRAVOHelperLog -ExitCode $exitCode
} catch {
    Write-Host "ПОМИЛКА: $($_.Exception.Message)" -ForegroundColor Red
    $fatalExitCode = if ($null -ne (Get-Command -Name Resolve-BRAVOExitCode -ErrorAction SilentlyContinue)) {
        Resolve-BRAVOExitCode -InternalError
    } else {
        90
    }
    Complete-BRAVOHelperLog -ExitCode $fatalExitCode
}
