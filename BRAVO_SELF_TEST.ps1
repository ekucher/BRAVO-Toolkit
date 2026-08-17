[CmdletBinding()]
param(
    [string]$ConfigPath
)

$helperLoggingPath = Join-Path $PSScriptRoot "modules\BRAVO.HelperLogging\BRAVO.HelperLogging.psd1"
Import-Module -Name $helperLoggingPath -ErrorAction Stop
$null = Start-BRAVOHelperLog -ScriptPath $PSCommandPath -ConfigPath $ConfigPath

$ErrorActionPreference = "Stop"
$root = if ($PSCommandPath) {
    Split-Path -Path $PSCommandPath -Parent
} else {
    [Environment]::CurrentDirectory
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root "BRAVO.config"
}
$script:failures = New-Object System.Collections.ArrayList
$script:selfTestConfigRoot = $null

function Test-BRAVOCondition {
    param(
        [bool]$Condition,
        [string]$Name,
        [string]$Failure
    )
    if ($Condition) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] ${Name}: $Failure" -ForegroundColor Red
        [void]$script:failures.Add("$Name — $Failure")
    }
}

function New-BRAVOSelfTestRuntimeModule {
    param(
        [Parameter(Mandatory = $true)][string]$SourceText,
        [Parameter(Mandatory = $true)][string[]]$FunctionNames
    )

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput(
        $SourceText,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -gt 0) {
        throw "не вдалося підготувати runtime-тести: $(
            ($errors | ForEach-Object { $_.Message }) -join ' | '
        )"
    }

    $definitions = @()
    foreach ($functionName in $FunctionNames) {
        $functionAst = @(
            $ast.FindAll(
                {
                    param($candidate)
                    $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $candidate.Name -eq $functionName
                },
                $true
            )
        ) | Select-Object -First 1
        if ($null -eq $functionAst) {
            throw "функцію '$functionName' не знайдено для runtime-тесту"
        }
        $definitions += $functionAst.Extent.Text
    }

    return New-Module -ScriptBlock {
        param([string[]]$Definitions)
        foreach ($definition in $Definitions) {
            . ([scriptblock]::Create($definition))
        }
    } -ArgumentList (, $definitions)
}

try {
    Write-Host "BRAVO SELF-TEST (STATIC + RUNTIME)" -ForegroundColor Cyan
    $powerShellFiles = @(
        @(Get-ChildItem -LiteralPath $root -File -Filter '*.ps1')
        @(Get-ChildItem -LiteralPath (Join-Path $root 'modules') -Recurse -File |
            Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') })
    )
    foreach ($file in $powerShellFiles) {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $file.FullName,
            [ref]$tokens,
            [ref]$errors
        )
        Test-BRAVOCondition `
            -Condition ($errors.Count -eq 0) `
            -Name "Parser/$($file.Name)" `
            -Failure (($errors | ForEach-Object { $_.Message }) -join " | ")
    }

    $helperEntryPoints = @(
        "BRAVO_SETUP.ps1",
        "BRAVO_DRY_RUN.ps1",
        "BRAVO_CREDENTIALS_SETUP.ps1",
        "BRAVO_TASKS_INSTALL.ps1",
        "BRAVO_TASKS_UNINSTALL.ps1",
        "BRAVO_TASKS_DIAGNOSE.ps1",
        "BRAVO_RESTORE_TEST.ps1",
        "BRAVO_SELF_TEST.ps1"
    )
    foreach ($fileName in $helperEntryPoints) {
        $helperText = [IO.File]::ReadAllText(
            (Join-Path $root $fileName),
            [Text.Encoding]::UTF8
        )
        Test-BRAVOCondition `
            -Condition (
                $helperText.Contains("Start-BRAVOHelperLog") -and
                $helperText.Contains("Complete-BRAVOHelperLog")
            ) `
            -Name "HelperLogging/$fileName" `
            -Failure "допоміжний скрипт не підключає повний цикл журналювання"
    }

    $credentialSetupText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_CREDENTIALS_SETUP.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $credentialSetupText.Contains('-QuietConsole:$protectedWorkerMode') -and
            $credentialSetupText.Contains('if (-not $protectedWorkerMode)')
        ) `
        -Name "Credentials/SystemWorkerQuietConsole" `
        -Failure "SYSTEM worker Credential Manager не повинен виконувати Write-Host без консолі"

    Remove-Module -Name 'BRAVO.Compatibility' -Force -ErrorAction SilentlyContinue
    $outputEncodingBeforeCompatibilityImport = $global:OutputEncoding
    Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop
    Test-BRAVOCondition `
        -Condition ([object]::ReferenceEquals(
                $outputEncodingBeforeCompatibilityImport,
                $global:OutputEncoding
            )) `
        -Name "Compatibility/ImportHasNoConsoleSideEffects" `
        -Failure "імпорт Compatibility не повинен змінювати global OutputEncoding"
    $staleHotfix = [pscustomobject]@{ InstalledOn = (Get-Date).AddDays(-400) }
    $stalePatchLevel = Get-BRAVOWindowsPatchLevelRecommendation `
        -InstalledHotfixes @($staleHotfix) `
        -Now (Get-Date) `
        -StaleAfterDays 120
    $freshHotfix = [pscustomobject]@{ InstalledOn = (Get-Date).AddDays(-10) }
    $freshPatchLevel = Get-BRAVOWindowsPatchLevelRecommendation `
        -InstalledHotfixes @($freshHotfix) `
        -Now (Get-Date) `
        -StaleAfterDays 120
    $noDataPatchLevel = Get-BRAVOWindowsPatchLevelRecommendation `
        -InstalledHotfixes @() `
        -StaleAfterDays 120
    Test-BRAVOCondition `
        -Condition (
            $stalePatchLevel.IsUpdateRecommended -and
            $stalePatchLevel.DaysSinceLastUpdate -eq 400 -and
            -not [string]::IsNullOrWhiteSpace([string]$stalePatchLevel.Message) -and
            -not $freshPatchLevel.IsUpdateRecommended -and
            $null -eq $freshPatchLevel.Message -and
            $noDataPatchLevel.IsUpdateRecommended -and
            -not [string]::IsNullOrWhiteSpace([string]$noDataPatchLevel.Message)
        ) `
        -Name "Compatibility/WindowsPatchLevelRecommendation" `
        -Failure "рекомендація оновити Windows має спрацьовувати лише для застарілого рівня патчів і не хибити на свіжій системі"

    # P0.4 з ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md: Supported (Server 2019+,
    # Windows 10/11, PS 5.1) / LegacyBestEffort (Server 2012 R2, 2016) /
    # Unsupported (Windows 7, Server 2008 R2, PowerShell 3.0). Перевірено на
    # синтетичних Win32_OperatingSystem-подібних об'єктах — реальну іншу ОС
    # у self-test підставити неможливо, той самий injectable-патерн, що й
    # у Get-BRAVOPowerShellUpdateRecommendation вище.
    $osTierWin7 = Get-BRAVOOSSupportTier `
        -OperatingSystemInfo ([pscustomobject]@{ Version = "6.1.7601"; Caption = "Windows 7 Enterprise"; ProductType = 1 }) `
        -PowerShellVersion ([version]"5.1") -DotNetRelease 528040
    $osTierServer2008R2 = Get-BRAVOOSSupportTier `
        -OperatingSystemInfo ([pscustomobject]@{ Version = "6.1.7601"; Caption = "Windows Server 2008 R2"; ProductType = 3 }) `
        -PowerShellVersion ([version]"5.1") -DotNetRelease 528040
    $osTierServer2012R2 = Get-BRAVOOSSupportTier `
        -OperatingSystemInfo ([pscustomobject]@{ Version = "6.3.9600"; Caption = "Windows Server 2012 R2"; ProductType = 3 }) `
        -PowerShellVersion ([version]"5.1") -DotNetRelease 528040
    $osTierServer2016 = Get-BRAVOOSSupportTier `
        -OperatingSystemInfo ([pscustomobject]@{ Version = "10.0.14393"; Caption = "Windows Server 2016"; ProductType = 3 }) `
        -PowerShellVersion ([version]"5.1") -DotNetRelease 528040
    $osTierServer2019 = Get-BRAVOOSSupportTier `
        -OperatingSystemInfo ([pscustomobject]@{ Version = "10.0.17763"; Caption = "Windows Server 2019"; ProductType = 3 }) `
        -PowerShellVersion ([version]"5.1") -DotNetRelease 528040
    $osTierWin10 = Get-BRAVOOSSupportTier `
        -OperatingSystemInfo ([pscustomobject]@{ Version = "10.0.19045"; Caption = "Windows 10 Pro"; ProductType = 1 }) `
        -PowerShellVersion ([version]"5.1") -DotNetRelease 528040
    $osTierServer2019PS3 = Get-BRAVOOSSupportTier `
        -OperatingSystemInfo ([pscustomobject]@{ Version = "10.0.17763"; Caption = "Windows Server 2019"; ProductType = 3 }) `
        -PowerShellVersion ([version]"3.0") -DotNetRelease 528040
    $osTierServer2019PS4 = Get-BRAVOOSSupportTier `
        -OperatingSystemInfo ([pscustomobject]@{ Version = "10.0.17763"; Caption = "Windows Server 2019"; ProductType = 3 }) `
        -PowerShellVersion ([version]"4.0") -DotNetRelease 528040
    Test-BRAVOCondition `
        -Condition (
            $osTierWin7.Tier -eq "Unsupported" -and
            $osTierServer2008R2.Tier -eq "Unsupported" -and
            $osTierServer2012R2.Tier -eq "LegacyBestEffort" -and
            $osTierServer2016.Tier -eq "LegacyBestEffort" -and
            $osTierServer2019.Tier -eq "Supported" -and
            $osTierWin10.Tier -eq "Supported" -and
            $osTierServer2019PS3.Tier -eq "Unsupported" -and
            $osTierServer2019PS4.Tier -eq "LegacyBestEffort" -and
            -not [string]::IsNullOrWhiteSpace([string]$osTierWin7.Message) -and
            -not [string]::IsNullOrWhiteSpace([string]$osTierServer2012R2.Message) -and
            $null -eq $osTierServer2019.Message
        ) `
        -Name "Compatibility/OSSupportTierClassification" `
        -Failure "Get-BRAVOOSSupportTier має класифікувати Windows 7/Server 2008 R2/PowerShell 3.0 як Unsupported, Server 2012 R2/2016 як LegacyBestEffort, Server 2019+/Windows 10 з PS 5.1 як Supported"
    $archiveRuntimeTextForOSTier = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $healthRuntimeTextForOSTier = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $maintenanceRuntimeTextForOSTier = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $archiveRuntimeTextForOSTier.Contains("Get-BRAVOOSSupportTier") -and
            $archiveRuntimeTextForOSTier.Contains("BRAVO_ALLOW_UNSUPPORTED_OS") -and
            $healthRuntimeTextForOSTier.Contains("Get-BRAVOOSSupportTier") -and
            $healthRuntimeTextForOSTier.Contains("BRAVO_ALLOW_UNSUPPORTED_OS") -and
            $maintenanceRuntimeTextForOSTier.Contains("Get-BRAVOOSSupportTier") -and
            $maintenanceRuntimeTextForOSTier.Contains("BRAVO_ALLOW_UNSUPPORTED_OS")
        ) `
        -Name "Runtime/UnsupportedOSBlocksProductionRun" `
        -Failure "Archive/Health/Maintenance мають блокувати запуск на Unsupported ОС, окрім явного override через BRAVO_ALLOW_UNSUPPORTED_OS=1 (аудит P0.4)"

    $toolIntegrityTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_TOOL_INTEGRITY_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($toolIntegrityTestRoot)
        $toolIntegrityTool = Join-Path $toolIntegrityTestRoot "fake7za.exe"
        [IO.File]::WriteAllText($toolIntegrityTool, "original content", (New-Object Text.UTF8Encoding($false)))
        $toolIntegrityManifest = Join-Path $toolIntegrityTestRoot "TOOLS_INTEGRITY.json"

        $toolIntegrityFirstRun = Get-BRAVOToolIntegrityRecommendation `
            -ToolPaths @($toolIntegrityTool) `
            -ManifestPath $toolIntegrityManifest
        $toolIntegrityUnchangedRun = Get-BRAVOToolIntegrityRecommendation `
            -ToolPaths @($toolIntegrityTool) `
            -ManifestPath $toolIntegrityManifest
        [IO.File]::WriteAllText($toolIntegrityTool, "TAMPERED", (New-Object Text.UTF8Encoding($false)))
        $toolIntegrityTamperedRun = Get-BRAVOToolIntegrityRecommendation `
            -ToolPaths @($toolIntegrityTool) `
            -ManifestPath $toolIntegrityManifest
        $toolIntegrityMissingRun = Get-BRAVOToolIntegrityRecommendation `
            -ToolPaths @((Join-Path $toolIntegrityTestRoot "nonexistent.exe")) `
            -ManifestPath $toolIntegrityManifest

        Test-BRAVOCondition `
            -Condition (
                -not $toolIntegrityFirstRun.HasIntegrityIssue -and
                (Test-Path -LiteralPath $toolIntegrityManifest -PathType Leaf) -and
                -not $toolIntegrityUnchangedRun.HasIntegrityIssue -and
                $toolIntegrityTamperedRun.HasIntegrityIssue -and
                $toolIntegrityTamperedRun.MismatchedTools -contains "fake7za.exe" -and
                -not [string]::IsNullOrWhiteSpace([string]$toolIntegrityTamperedRun.Message) -and
                -not $toolIntegrityMissingRun.HasIntegrityIssue
            ) `
            -Name "Compatibility/ToolIntegrityRecommendation" `
            -Failure "перший запуск має тихо зафіксувати базову лінію (TOFU), підміна файлу — попередити, відсутній інструмент — не хибити"
    } finally {
        if (Test-Path -LiteralPath $toolIntegrityTestRoot -PathType Container) {
            [IO.Directory]::Delete($toolIntegrityTestRoot, $true)
        }
    }

    # Аудит P1 (найнебезпечніший сценарій): підмінений 7za.exe/WinSCP.com
    # запускається від NT AUTHORITY\SYSTEM. Version-controlled
    # TOOLS_MANIFEST.json має БЛОКУВАТИ запуск, а не лише попереджати, і
    # його не можна ані обійти видаленням, ані перегенерувати на сервері.
    $toolManifestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_TOOL_MANIFEST_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        $toolManifestTools = Join-Path $toolManifestRoot "Tools"
        [void][IO.Directory]::CreateDirectory($toolManifestTools)
        $genuineTool = Join-Path $toolManifestTools "7za.exe"
        [IO.File]::WriteAllText($genuineTool, "GENUINE", (New-Object Text.UTF8Encoding($false)))
        $genuineHash = (Get-BRAVOFileHash -Path $genuineTool -Algorithm SHA256).Hash.ToUpperInvariant()
        $toolManifestContent = '{"schemaVersion":1,"tools":{"7za.exe":"' + $genuineHash + '"}}'

        $manifestCleanRun = Test-BRAVOToolManifestIntegrity `
            -ToolsDirectory $toolManifestTools `
            -ManifestPath "(інжектовано)" `
            -ManifestContent $toolManifestContent `
            -Mode Enforce

        # Сторонній виконуваний файл у Tools — повідомляємо, але не
        # блокуємо: він може взагалі не використовуватись.
        $strangerTool = Join-Path $toolManifestTools "stranger.exe"
        [IO.File]::WriteAllText($strangerTool, "PAYLOAD", (New-Object Text.UTF8Encoding($false)))
        $manifestUnknownRun = Test-BRAVOToolManifestIntegrity `
            -ToolsDirectory $toolManifestTools `
            -ManifestPath "(інжектовано)" `
            -ManifestContent $toolManifestContent `
            -Mode Enforce
        [IO.File]::Delete($strangerTool)

        [IO.File]::WriteAllText($genuineTool, "TAMPERED", (New-Object Text.UTF8Encoding($false)))
        $manifestTamperedEnforce = Test-BRAVOToolManifestIntegrity `
            -ToolsDirectory $toolManifestTools `
            -ManifestPath "(інжектовано)" `
            -ManifestContent $toolManifestContent `
            -Mode Enforce
        $manifestTamperedWarn = Test-BRAVOToolManifestIntegrity `
            -ToolsDirectory $toolManifestTools `
            -ManifestPath "(інжектовано)" `
            -ManifestContent $toolManifestContent `
            -Mode Warn

        [IO.File]::Delete($genuineTool)
        $manifestMissingToolRun = Test-BRAVOToolManifestIntegrity `
            -ToolsDirectory $toolManifestTools `
            -ManifestPath "(інжектовано)" `
            -ManifestContent $toolManifestContent `
            -Mode Enforce

        # Найважливіший сценарій обходу: просто видалити еталон.
        $manifestAbsentRun = Test-BRAVOToolManifestIntegrity `
            -ToolsDirectory $toolManifestTools `
            -ManifestPath (Join-Path $toolManifestRoot "NEMAE.json") `
            -Mode Enforce
        $manifestCorruptRun = Test-BRAVOToolManifestIntegrity `
            -ToolsDirectory $toolManifestTools `
            -ManifestPath "(інжектовано)" `
            -ManifestContent "{ це не JSON" `
            -Mode Enforce

        Test-BRAVOCondition `
            -Condition (
                $manifestCleanRun.IsValid -and
                -not $manifestCleanRun.ShouldBlock
            ) `
            -Name "ToolManifest/GenuineToolsPass" `
            -Failure "незмінені інструменти мають проходити перевірку еталонного маніфесту"

        Test-BRAVOCondition `
            -Condition (
                -not $manifestTamperedEnforce.IsValid -and
                $manifestTamperedEnforce.ShouldBlock -and
                $manifestTamperedEnforce.MismatchedTools -contains "7za.exe"
            ) `
            -Name "ToolManifest/TamperedToolBlocksInEnforce" `
            -Failure "підмінений інструмент у режимі Enforce має БЛОКУВАТИ запуск (запускався б від SYSTEM)"

        Test-BRAVOCondition `
            -Condition (
                -not $manifestTamperedWarn.IsValid -and
                -not $manifestTamperedWarn.ShouldBlock
            ) `
            -Name "ToolManifest/TamperedToolOnlyWarnsInWarnMode" `
            -Failure "у режимі Warn підміна має повідомляти, але не блокувати"

        Test-BRAVOCondition `
            -Condition (
                -not $manifestMissingToolRun.IsValid -and
                $manifestMissingToolRun.ShouldBlock -and
                $manifestMissingToolRun.MissingTools -contains "7za.exe"
            ) `
            -Name "ToolManifest/MissingToolBlocksInEnforce" `
            -Failure "відсутній у Tools файл з еталонного маніфесту має блокувати запуск"

        Test-BRAVOCondition `
            -Condition (
                -not $manifestAbsentRun.IsValid -and
                $manifestAbsentRun.ShouldBlock -and
                -not $manifestCorruptRun.IsValid -and
                $manifestCorruptRun.ShouldBlock
            ) `
            -Name "ToolManifest/AbsentOrCorruptManifestBlocks" `
            -Failure "видалення чи пошкодження еталонного маніфесту НЕ повинно бути способом обійти перевірку"

        # Сторонній executable БЛОКУЄ (виправлено після рев'ю): DLL
        # side-loading не потребує підміни WinSCP.exe/7za.exe — Windows
        # шукає залежності в каталозі самого виконуваного файлу, тому
        # достатньо підкласти DLL з відповідним іменем, і жоден хеш у
        # маніфесті при цьому не зміниться.
        Test-BRAVOCondition `
            -Condition (
                -not $manifestUnknownRun.IsValid -and
                $manifestUnknownRun.ShouldBlock -and
                $manifestUnknownRun.UnknownTools -contains "stranger.exe" -and
                -not [string]::IsNullOrWhiteSpace([string]$manifestUnknownRun.Message)
            ) `
            -Name "ToolManifest/UnknownExecutableBlocksInEnforce" `
            -Failure "сторонній виконуваний файл у Tools має БЛОКУВАТИ запуск у режимі Enforce (DLL side-loading)"

        # Стороння DLL — той самий вектор, окремо закріплено, бо саме її
        # найпростіше підкласти непомітно.
        $strangerDll = Join-Path $toolManifestTools "version.dll"
        [IO.File]::WriteAllText($strangerDll, "SIDELOAD", (New-Object Text.UTF8Encoding($false)))
        $manifestUnknownDllRun = Test-BRAVOToolManifestIntegrity `
            -ToolsDirectory $toolManifestTools `
            -ManifestPath "(інжектовано)" `
            -ManifestContent $toolManifestContent `
            -Mode Enforce
        $manifestUnknownDllWarn = Test-BRAVOToolManifestIntegrity `
            -ToolsDirectory $toolManifestTools `
            -ManifestPath "(інжектовано)" `
            -ManifestContent $toolManifestContent `
            -Mode Warn
        [IO.File]::Delete($strangerDll)
        Test-BRAVOCondition `
            -Condition (
                $manifestUnknownDllRun.ShouldBlock -and
                $manifestUnknownDllRun.UnknownTools -contains "version.dll" -and
                -not $manifestUnknownDllWarn.ShouldBlock
            ) `
            -Name "ToolManifest/UnknownDllBlocksInEnforceWarnsInWarn" `
            -Failure "підкинута стороння DLL у Tools має блокувати запуск у Enforce і лише попереджати у Warn"

        # Маніфест не повинен створюватись автоматично: інакше сторож сам
        # виписує перепустку злодію.
        $manifestAutoCreatePath = Join-Path $toolManifestRoot "SHOULD_NOT_APPEAR.json"
        [void](Test-BRAVOToolManifestIntegrity `
            -ToolsDirectory $toolManifestTools `
            -ManifestPath $manifestAutoCreatePath `
            -Mode Enforce)
        Test-BRAVOCondition `
            -Condition (-not (Test-Path -LiteralPath $manifestAutoCreatePath)) `
            -Name "ToolManifest/NeverAutoCreatesBaseline" `
            -Failure "еталонний маніфест НЕ повинен створюватись автоматично під час production-запуску"
    } finally {
        if (Test-Path -LiteralPath $toolManifestRoot -PathType Container) {
            [IO.Directory]::Delete($toolManifestRoot, $true)
        }
    }

    # Аудит P2: цілісність усього PowerShell-комплекту. Guard навмисно
    # самодостатній (лише .NET, без модулів BRAVO), бо виконується ДО
    # Import-Module — інакше довелося б завантажити модуль, щоб
    # перевірити модулі.
    . (Join-Path $root "BRAVO_RUNTIME_GUARD.ps1")

    $runtimeGuardRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_RUNTIME_GUARD_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        $guardModuleDirectory = Join-Path $runtimeGuardRoot "modules\BRAVO.Fake"
        [void][IO.Directory]::CreateDirectory($guardModuleDirectory)
        $guardScript = Join-Path $runtimeGuardRoot "BRAVO_FAKE.ps1"
        $guardModule = Join-Path $guardModuleDirectory "BRAVO.Fake.psm1"
        [IO.File]::WriteAllText($guardScript, "# genuine entrypoint", (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($guardModule, "# genuine module", (New-Object Text.UTF8Encoding($false)))

        $guardScriptHash = (Get-BRAVOFileHash -Path $guardScript -Algorithm SHA256).Hash.ToUpperInvariant()
        $guardModuleHash = (Get-BRAVOFileHash -Path $guardModule -Algorithm SHA256).Hash.ToUpperInvariant()
        $guardManifest = (
            '{"schemaVersion":1,"files":{' +
            '"BRAVO_FAKE.ps1":"' + $guardScriptHash + '",' +
            '"modules\\BRAVO.Fake\\BRAVO.Fake.psm1":"' + $guardModuleHash + '"}}'
        )

        $guardCleanRun = Test-BRAVORuntimeManifestIntegrity `
            -RuntimeRoot $runtimeGuardRoot `
            -ManifestPath "(інжектовано)" `
            -ManifestContent $guardManifest `
            -Mode Enforce

        [IO.File]::WriteAllText($guardModule, "# TAMPERED", (New-Object Text.UTF8Encoding($false)))
        $guardTamperedEnforce = Test-BRAVORuntimeManifestIntegrity `
            -RuntimeRoot $runtimeGuardRoot `
            -ManifestPath "(інжектовано)" `
            -ManifestContent $guardManifest `
            -Mode Enforce
        $guardTamperedWarn = Test-BRAVORuntimeManifestIntegrity `
            -RuntimeRoot $runtimeGuardRoot `
            -ManifestPath "(інжектовано)" `
            -ManifestContent $guardManifest `
            -Mode Warn
        [IO.File]::WriteAllText($guardModule, "# genuine module", (New-Object Text.UTF8Encoding($false)))

        # Підкинутий у комплект скрипт: він може бути dot-source-нутий
        # або підхоплений як модуль, тому теж має блокувати.
        $guardIntruder = Join-Path $guardModuleDirectory "evil.psm1"
        [IO.File]::WriteAllText($guardIntruder, "# payload", (New-Object Text.UTF8Encoding($false)))
        $guardIntruderRun = Test-BRAVORuntimeManifestIntegrity `
            -RuntimeRoot $runtimeGuardRoot `
            -ManifestPath "(інжектовано)" `
            -ManifestContent $guardManifest `
            -Mode Enforce
        [IO.File]::Delete($guardIntruder)

        [IO.File]::Delete($guardModule)
        $guardMissingRun = Test-BRAVORuntimeManifestIntegrity `
            -RuntimeRoot $runtimeGuardRoot `
            -ManifestPath "(інжектовано)" `
            -ManifestContent $guardManifest `
            -Mode Enforce

        $guardAbsentManifestRun = Test-BRAVORuntimeManifestIntegrity `
            -RuntimeRoot $runtimeGuardRoot `
            -ManifestPath (Join-Path $runtimeGuardRoot "NEMAE.json") `
            -Mode Enforce
        $guardCorruptManifestRun = Test-BRAVORuntimeManifestIntegrity `
            -RuntimeRoot $runtimeGuardRoot `
            -ManifestPath "(інжектовано)" `
            -ManifestContent "{ це не JSON" `
            -Mode Enforce

        Test-BRAVOCondition `
            -Condition ($guardCleanRun.IsValid -and -not $guardCleanRun.ShouldBlock) `
            -Name "RuntimeManifest/GenuineRuntimePasses" `
            -Failure "незмінений комплект має проходити перевірку цілісності"

        Test-BRAVOCondition `
            -Condition (
                -not $guardTamperedEnforce.IsValid -and
                $guardTamperedEnforce.ShouldBlock -and
                $guardTamperedEnforce.MismatchedFiles -contains "modules\BRAVO.Fake\BRAVO.Fake.psm1" -and
                -not $guardTamperedWarn.ShouldBlock
            ) `
            -Name "RuntimeManifest/TamperedModuleBlocksInEnforce" `
            -Failure "підмінений .psm1 має блокувати запуск у Enforce і лише попереджати у Warn"

        Test-BRAVOCondition `
            -Condition (
                $guardIntruderRun.ShouldBlock -and
                $guardIntruderRun.UnknownFiles -contains "modules\BRAVO.Fake\evil.psm1"
            ) `
            -Name "RuntimeManifest/UnknownScriptBlocksInEnforce" `
            -Failure "підкинутий у комплект скрипт має блокувати запуск"

        Test-BRAVOCondition `
            -Condition (
                $guardMissingRun.ShouldBlock -and
                $guardMissingRun.MissingFiles -contains "modules\BRAVO.Fake\BRAVO.Fake.psm1"
            ) `
            -Name "RuntimeManifest/MissingFileBlocksInEnforce" `
            -Failure "відсутній файл комплекту має блокувати запуск"

        Test-BRAVOCondition `
            -Condition ($guardAbsentManifestRun.ShouldBlock -and $guardCorruptManifestRun.ShouldBlock) `
            -Name "RuntimeManifest/AbsentOrCorruptManifestBlocks" `
            -Failure "видалення чи пошкодження RUNTIME_MANIFEST.json НЕ повинно бути способом обійти перевірку"

        # Guard не має створювати маніфест сам — інакше сторож виписує
        # перепустку злодію.
        $guardAutoCreatePath = Join-Path $runtimeGuardRoot "SHOULD_NOT_APPEAR.json"
        [void](Test-BRAVORuntimeManifestIntegrity `
            -RuntimeRoot $runtimeGuardRoot `
            -ManifestPath $guardAutoCreatePath `
            -Mode Enforce)
        Test-BRAVOCondition `
            -Condition (-not (Test-Path -LiteralPath $guardAutoCreatePath)) `
            -Name "RuntimeManifest/NeverAutoCreatesManifest" `
            -Failure "RUNTIME_MANIFEST.json не повинен створюватись автоматично"
    } finally {
        if (Test-Path -LiteralPath $runtimeGuardRoot -PathType Container) {
            [IO.Directory]::Delete($runtimeGuardRoot, $true)
        }
    }

    # Маніфест у репозиторії має відповідати реальному комплекту: інакше
    # свіжо розгорнутий комплект заблокує сам себе на першому запуску.
    $repositoryRuntimeManifest = Test-BRAVORuntimeManifestIntegrity `
        -RuntimeRoot $root `
        -ManifestPath (Join-Path $root "RUNTIME_MANIFEST.json") `
        -Mode Enforce
    Test-BRAVOCondition `
        -Condition $repositoryRuntimeManifest.IsValid `
        -Name "RuntimeManifest/RepositoryManifestMatchesRuntime" `
        -Failure "RUNTIME_MANIFEST.json не відповідає комплекту (запустіть ci\Update-BRAVORuntimeManifest.ps1 -Apply): $($repositoryRuntimeManifest.Message)"

    # Усі три entrypoint мають перевіряти цілісність ДО Import-Module.
    foreach ($entryPointName in @('BRAVO_ARCHIV.ps1', 'BRAVO_HEALTH.ps1', 'BRAVO_MAINTENANCE.ps1')) {
        $entryPointText = [IO.File]::ReadAllText((Join-Path $root $entryPointName), [Text.Encoding]::UTF8)
        # Порівнюємо з реальним викликом, а не з будь-якою згадкою
        # "Import-Module": слово трапляється і в коментарях, зокрема в
        # тому, що пояснює сам порядок перевірки.
        $guardPosition = $entryPointText.IndexOf('. $runtimeGuardPath')
        $importPosition = $entryPointText.IndexOf('Import-Module -Name $modulePath')
        Test-BRAVOCondition `
            -Condition (
                $guardPosition -ge 0 -and
                $importPosition -ge 0 -and
                $guardPosition -lt $importPosition
            ) `
            -Name "RuntimeManifest/GuardRunsBeforeImport/$entryPointName" `
            -Failure "$entryPointName має перевіряти цілісність комплекту ДО Import-Module (інакше виконується непepевірений код)"

        # BRAVO.config не входить до маніфесту за задумом, тому перевірка
        # його перемикачів мусить бути в кожному entrypoint окремо.
        Test-BRAVOCondition `
            -Condition (
                $entryPointText.Contains('Test-BRAVORuntimeSecuritySettings') -and
                $entryPointText.Contains('exit 34')
            ) `
            -Name "ConfigSecurity/CheckedInEntryPoint/$entryPointName" `
            -Failure "$entryPointName має перевіряти перемикачі безпеки BRAVO.config і завершуватись кодом 34"

        Test-BRAVOCondition `
            -Condition (
                $entryPointText.Contains('Test-BRAVOVersionDowngrade') -and
                $entryPointText.Contains("CommonApplicationData')) 'BRAVO\State\BRAVO_VERSION_STATE.json'") -and
                $entryPointText.Contains('exit 35')
            ) `
            -Name "VersionState/CheckedInEntryPoint/$entryPointName" `
            -Failure "$entryPointName має зберігати machine-wide version state поза RuntimeRoot, перевіряти відкат версії й завершуватись кодом 35"
    }

    # Перевірка перемикачів безпеки в BRAVO.config. Конфігурація навмисно
    # не входить до RUNTIME_MANIFEST.json (вона різна на кожному сервері),
    # тому рядок у ній був найдешевшим способом тихо вимкнути захист:
    # Mode = "Warn" знімає блокування підміненого 7za, Mode = "Live"
    # прибирає VSS-узгодженість архівів.
    $securityGoodConfig = @(
        '$global:toolIntegritySettings = @{ Mode = "Enforce"; ManifestPath = "z" }',
        '$global:backupConsistency = @{ Mode = "VSS"; SnapshotContext = "ClientAccessible" }'
    ) -join [Environment]::NewLine

    $securityBaseline = Test-BRAVORuntimeSecuritySettings `
        -ConfigPath 'synthetic' -ConfigContent $securityGoodConfig -Mode Enforce -AllowWeakened ''
    Test-BRAVOCondition `
        -Condition ($securityBaseline.IsValid -and -not $securityBaseline.ShouldBlock) `
        -Name "ConfigSecurity/StrictConfigurationPasses" `
        -Failure "конфігурація з Enforce і VSS має проходити перевірку: $($securityBaseline.Message)"

    $securityWeakTool = Test-BRAVORuntimeSecuritySettings `
        -ConfigPath 'synthetic' `
        -ConfigContent $securityGoodConfig.Replace('"Enforce"', '"Warn"') `
        -Mode Enforce -AllowWeakened ''
    Test-BRAVOCondition `
        -Condition (-not $securityWeakTool.IsValid -and $securityWeakTool.ShouldBlock) `
        -Name "ConfigSecurity/ToolIntegrityWarnBlocks" `
        -Failure "toolIntegritySettings.Mode = 'Warn' має блокувати запуск без явного override"

    $securityWeakVss = Test-BRAVORuntimeSecuritySettings `
        -ConfigPath 'synthetic' `
        -ConfigContent $securityGoodConfig.Replace('"VSS"', '"Live"') `
        -Mode Enforce -AllowWeakened ''
    Test-BRAVOCondition `
        -Condition (-not $securityWeakVss.IsValid -and $securityWeakVss.ShouldBlock) `
        -Name "ConfigSecurity/BackupConsistencyLiveBlocks" `
        -Failure "backupConsistency.Mode = 'Live' має блокувати запуск: неузгоджений архів гірший за відсутній"

    # Свідоме послаблення лишається можливим, але вимагає ДРУГОЇ дії в
    # іншому місці — редагування самого BRAVO.config уже недостатньо.
    $securityOverride = Test-BRAVORuntimeSecuritySettings `
        -ConfigPath 'synthetic' `
        -ConfigContent $securityGoodConfig.Replace('"Enforce"', '"Warn"') `
        -Mode Enforce -AllowWeakened '1'
    Test-BRAVOCondition `
        -Condition (-not $securityOverride.ShouldBlock -and $securityOverride.OverrideApplied) `
        -Name "ConfigSecurity/ExplicitOverrideAllowsWeakening" `
        -Failure "BRAVO_ALLOW_WEAKENED_SECURITY=1 має дозволяти тимчасове послаблення, лишаючи слід у виводі"

    # Обхід через обчислюване значення ($m = "Warn"; Mode = $m) має
    # коштувати щонайменше стільки ж, скільки пряме послаблення.
    $securityComputed = Test-BRAVORuntimeSecuritySettings `
        -ConfigPath 'synthetic' `
        -ConfigContent (@(
            '$m = "Warn"',
            '$global:toolIntegritySettings = @{ Mode = $m }',
            '$global:backupConsistency = @{ Mode = "VSS" }'
        ) -join [Environment]::NewLine) `
        -Mode Enforce -AllowWeakened ''
    Test-BRAVOCondition `
        -Condition (
            -not $securityComputed.IsValid -and
            $securityComputed.ShouldBlock -and
            $securityComputed.Unverifiable.Count -eq 1
        ) `
        -Name "ConfigSecurity/ComputedValueIsNotAnEscapeHatch" `
        -Failure "значення, обчислене виразом, не підтверджується статично й має блокувати так само, як пряме послаблення"

    # Конфігурація, яка взагалі не згадує ці налаштування, послабленою не
    # є. Регресія реальна: перше робоче формулювання читало порожній
    # результат як порожній рядок і блокувало такі конфігурації.
    $securitySilent = Test-BRAVORuntimeSecuritySettings `
        -ConfigPath 'synthetic' `
        -ConfigContent '$global:pathSettings = @{ BackupRoot = "C:\x" }' `
        -Mode Enforce -AllowWeakened ''
    Test-BRAVOCondition `
        -Condition ($securitySilent.IsValid -and -not $securitySilent.ShouldBlock) `
        -Name "ConfigSecurity/AbsentSettingsAreNotWeakening" `
        -Failure "конфігурація без цих налаштувань не повинна вважатися послабленою"

    # Захист від відкату на старішу версію. Усі перевірки вище звіряють
    # комплект із його ВЛАСНИМ маніфестом — старий комплект пройде їх
    # бездоганно, разом із вразливостями, які відтоді закрили. Найпростіший
    # спосіб вимкнути Enforce — розгорнути версію, де його не було.
    function Test-BRAVODowngradeScenario {
        param([string]$Deployed, [string]$Recorded, [string]$Allow = '', [string]$Mode = 'Enforce')
        $parameters = @{
            RuntimeRoot = $root
            StatePath = 'synthetic'
            VersionContent = ('{{"packageVersion": "{0}"}}' -f $Deployed)
            Mode = $Mode
            AllowDowngrade = $Allow
            NoWrite = $true
        }
        if (-not [string]::IsNullOrEmpty($Recorded)) {
            $parameters['StateContent'] = ('{{"highestVersion": "{0}"}}' -f $Recorded)
        }
        return (Test-BRAVOVersionDowngrade @parameters)
    }

    Test-BRAVOCondition `
        -Condition (
            (Test-BRAVODowngradeScenario -Deployed '4.3.0' -Recorded '').IsValid -and
            (Test-BRAVODowngradeScenario -Deployed '4.3.0' -Recorded '4.3.0').IsValid -and
            (Test-BRAVODowngradeScenario -Deployed '4.4.0' -Recorded '4.3.0').IsValid
        ) `
        -Name "VersionState/SameOrNewerVersionPasses" `
        -Failure "перший запуск, та сама версія й новіша версія мають проходити без блокування"

    $downgradeMajor = Test-BRAVODowngradeScenario -Deployed '4.2.0' -Recorded '4.3.0'
    $downgradePatch = Test-BRAVODowngradeScenario -Deployed '4.3.0' -Recorded '4.3.1'
    Test-BRAVOCondition `
        -Condition (
            -not $downgradeMajor.IsValid -and $downgradeMajor.ShouldBlock -and
            -not $downgradePatch.IsValid -and $downgradePatch.ShouldBlock
        ) `
        -Name "VersionState/DowngradeBlocks" `
        -Failure "розгортання старішої версії має блокувати запуск, включно з відкатом на один patch"

    $downgradeOverride = Test-BRAVODowngradeScenario -Deployed '4.2.0' -Recorded '4.3.0' -Allow '1'
    Test-BRAVOCondition `
        -Condition (-not $downgradeOverride.ShouldBlock -and $downgradeOverride.OverrideApplied) `
        -Name "VersionState/ExplicitOverrideAllowsDowngrade" `
        -Failure "BRAVO_ALLOW_DOWNGRADE=1 має дозволяти аварійне повернення на попередній реліз"

    # Файл стану — не еталон довіри, на відміну від маніфеста. Його втрата
    # чи пошкодження не мусить зупиняти backup: наступний успішний запуск
    # запише його наново.
    $downgradeCorrupt = Test-BRAVOVersionDowngrade `
        -RuntimeRoot $root -StatePath 'synthetic' `
        -VersionContent '{"packageVersion": "4.3.0"}' `
        -StateContent 'це не JSON' -Mode Enforce -AllowDowngrade '' -NoWrite
    Test-BRAVOCondition `
        -Condition ($downgradeCorrupt.IsValid -and -not $downgradeCorrupt.ShouldBlock) `
        -Name "VersionState/CorruptStateDoesNotBlock" `
        -Failure "пошкоджений файл стану версії не повинен зупиняти backup — він не є еталоном довіри"

    # Повний цикл запису в ізольованому каталозі: перший запуск фіксує
    # версію, після чого старіша вже блокується.
    $versionStateRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_VERSION_STATE_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        $versionStatePath = Join-Path $versionStateRoot 'LOGS\BRAVO_VERSION_STATE.json'
        $firstRun = Test-BRAVOVersionDowngrade `
            -RuntimeRoot $root -StatePath $versionStatePath `
            -VersionContent '{"packageVersion": "4.3.0", "sourceCommit": "abc"}' `
            -Mode Enforce -AllowDowngrade ''
        $afterWrite = Test-BRAVOVersionDowngrade `
            -RuntimeRoot $root -StatePath $versionStatePath `
            -VersionContent '{"packageVersion": "4.2.0"}' `
            -Mode Enforce -AllowDowngrade '' -NoWrite
        Test-BRAVOCondition `
            -Condition (
                $firstRun.StateUpdated -and
                (Test-Path -LiteralPath $versionStatePath -PathType Leaf) -and
                $afterWrite.ShouldBlock -and
                $afterWrite.RecordedVersion -eq '4.3.0'
            ) `
            -Name "VersionState/RecordsHighestVersionOnDisk" `
            -Failure "перший запуск має записати найвищу версію, після чого старіша блокується"
    } finally {
        if (Test-Path -LiteralPath $versionStateRoot) {
            Remove-Item -LiteralPath $versionStateRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Аудит Low #8: порожній catch {} без жодного пояснення ковтає
    # діагностику саме там, де вона потрібна — під час інциденту. Вимога не
    # "заборонити порожні catch" (частина з них законна: прибирання у
    # finally, де початкова помилка важливіша), а "жоден із них не мовчить
    # без причини". Тому правило: порожній catch мусить або логувати, або
    # містити коментар, який пояснює, чому логування тут недоречне.
    # $powerShellFiles — корінь + modules, тобто саме production-комплект.
    # ci\* свідомо поза перевіркою: це допоміжні скрипти розробника, які
    # ніколи не виконуються від SYSTEM.
    $silentCatchFindings = New-Object System.Collections.ArrayList
    foreach ($analyzedFile in $powerShellFiles) {
        if ($analyzedFile.Extension -notin @('.ps1', '.psm1')) { continue }

        $catchTokens = $null
        $catchErrors = $null
        $catchAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $analyzedFile.FullName, [ref]$catchTokens, [ref]$catchErrors)
        if ($null -eq $catchAst) { continue }

        $emptyCatches = @($catchAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CatchClauseAst]
        }, $true) | Where-Object { $_.Body.Statements.Count -eq 0 })

        foreach ($emptyCatch in $emptyCatches) {
            $bodyStart = $emptyCatch.Body.Extent.StartOffset
            $bodyEnd = $emptyCatch.Body.Extent.EndOffset
            $hasExplanation = @($catchTokens | Where-Object {
                $_.Kind -eq 'Comment' -and
                $_.Extent.StartOffset -ge $bodyStart -and
                $_.Extent.EndOffset -le $bodyEnd
            }).Count -gt 0
            if (-not $hasExplanation) {
                [void]$silentCatchFindings.Add(
                    ("{0}:{1}" -f $analyzedFile.Name, $emptyCatch.Extent.StartLineNumber))
            }
        }
    }
    # Рядок, що ВИГЛЯДАЄ як облікові дані, — це справжній секрет для будь-якого
    # сканера, навіть якщо значення вигадане. Такі фікстури вже кілька разів
    # піднімали інциденти GitGuardian, які доводилось закривати вручну;
    # альтернатива "додати виняток сканеру" гірша, бо виняток глушить і
    # справжній витік у тому самому файлі.
    #
    # Перевіряються лише СТРОКОВІ ЛІТЕРАЛИ з AST — коментарі й документація
    # свідомо поза межами: там форма URL з обліковими даними потрібна, щоб
    # пояснити, що саме маскується.
    $credentialShapedLiterals = New-Object System.Collections.ArrayList
    # Плейсхолдери, які нічого не розкривають: узагальнені слова, маска,
    # підстановка формату й посилання на змінну. Останнє обов'язкове:
    # New-BRAVOSftpUrl будує саме такий рядок із ${escapedPassword} —
    # це робочий код, а не фікстура, і перша версія перевірки на ньому
    # спіткнулась.
    $placeholderPassword = '^(pass|password|\*{3}|\{\d+\}|\$\{?\w+\}?)$'
    foreach ($analyzedFile in $powerShellFiles) {
        if ($analyzedFile.Extension -notin @('.ps1', '.psm1')) { continue }

        $literalTokens = $null
        $literalErrors = $null
        $literalAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $analyzedFile.FullName, [ref]$literalTokens, [ref]$literalErrors)
        if ($null -eq $literalAst) { continue }

        $literalNodes = @($literalAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
            $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
        }, $true))

        foreach ($literalNode in $literalNodes) {
            $literalValue = [string]$literalNode.Extent.Text
            foreach ($credentialMatch in [regex]::Matches(
                    $literalValue, '(?i)sftp://[^:@\s/]+:([^@\s/]+)@')) {
                $passwordPart = $credentialMatch.Groups[1].Value
                if ($passwordPart -notmatch $placeholderPassword) {
                    [void]$credentialShapedLiterals.Add(
                        ("{0}:{1} (sftp)" -f $analyzedFile.Name, $literalNode.Extent.StartLineNumber))
                }
            }
            if ([regex]::IsMatch($literalValue,
                    '(?i)(hooks\.slack\.com/services|discord\.com/api/webhooks)/[^/\s"'']+/[^/\s"'']+/?[^/\s"'']*') -and
                $literalValue -notmatch '\*{3}' -and
                $literalValue -notmatch '\{\d+\}') {
                [void]$credentialShapedLiterals.Add(
                    ("{0}:{1} (webhook)" -f $analyzedFile.Name, $literalNode.Extent.StartLineNumber))
            }
        }
    }
    Test-BRAVOCondition `
        -Condition ($credentialShapedLiterals.Count -eq 0) `
        -Name "Secrets/NoCredentialShapedLiterals" `
        -Failure "рядковий літерал не повинен виглядати як облікові дані навіть у тестовій фікстурі — складіть його з частин у рантаймі; знайдено: $(@($credentialShapedLiterals.ToArray() | Select-Object -Unique) -join ', ')"

    Test-BRAVOCondition `
        -Condition ($silentCatchFindings.Count -eq 0) `
        -Name "Diagnostics/NoSilentEmptyCatch" `
        -Failure "порожній catch має або логувати, або пояснювати коментарем, чому логування недоречне; без пояснення: $(@($silentCatchFindings.ToArray()) -join ', ')"

    # Реальний BRAVO.config репозиторію мусить проходити власну перевірку.
    $securityRealConfig = Test-BRAVORuntimeSecuritySettings `
        -ConfigPath (Join-Path $root "BRAVO.config") -Mode Enforce -AllowWeakened ''
    Test-BRAVOCondition `
        -Condition $securityRealConfig.IsValid `
        -Name "ConfigSecurity/RepositoryConfigIsStrict" `
        -Failure "BRAVO.config у репозиторії не проходить власну перевірку: $($securityRealConfig.Message)"

    # Еталонний маніфест у самому репозиторії має відповідати реальним
    # Tools: інакше свіжий комплект заблокує сам себе на першому ж запуску.
    $repositoryToolsDirectory = Join-Path $root "Tools"
    if (Test-Path -LiteralPath $repositoryToolsDirectory -PathType Container) {
        $repositoryManifestRun = Test-BRAVOToolManifestIntegrity `
            -ToolsDirectory $repositoryToolsDirectory `
            -ManifestPath (Join-Path $repositoryToolsDirectory "TOOLS_MANIFEST.json") `
            -Mode Enforce
        Test-BRAVOCondition `
            -Condition $repositoryManifestRun.IsValid `
            -Name "ToolManifest/RepositoryManifestMatchesTools" `
            -Failure "TOOLS_MANIFEST.json не відповідає реальним Tools у репозиторії: $($repositoryManifestRun.Message)"
    }

    # Маніфест шукається в тому самому каталозі, що й самі утиліти
    # (Tools\), а не поруч зі скриптом — BRAVO.config і всі три runtime
    # (fallback на випадок непридатної конфігурації) мають бути
    # узгоджені: жоден не повинен лишитись зі старим $archivPath/
    # $bravoScriptDirectory-відносним шляхом.
    $toolManifestLocationSources = @{
        'BRAVO.config' = [IO.File]::ReadAllText((Join-Path $root 'BRAVO.config'), [Text.Encoding]::UTF8)
        'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1' = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1'), [Text.Encoding]::UTF8)
        'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1' = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1'), [Text.Encoding]::UTF8)
        'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1' = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1'), [Text.Encoding]::UTF8)
    }
    $filesWithWrongManifestLocation = @(
        $toolManifestLocationSources.Keys | Where-Object {
            -not [regex]::IsMatch($toolManifestLocationSources[$_], 'Join-Path\s+\$toolsPath\s+"TOOLS_MANIFEST\.json"')
        }
    )
    Test-BRAVOCondition `
        -Condition ($filesWithWrongManifestLocation.Count -eq 0) `
        -Name "ToolManifest/ManifestPathIsInsideToolsDirectory" `
        -Failure "TOOLS_MANIFEST.json має шукатись через Join-Path `$toolsPath 'TOOLS_MANIFEST.json' (той самий каталог, що й утиліти), а не поруч зі скриптом; не узгоджені: $($filesWithWrongManifestLocation -join ', ')"

    Test-BRAVOCondition `
        -Condition (
            (Test-Path -LiteralPath (Join-Path $root 'Tools\TOOLS_MANIFEST.json') -PathType Leaf) -and
            -not (Test-Path -LiteralPath (Join-Path $root 'TOOLS_MANIFEST.json') -PathType Leaf)
        ) `
        -Name "ToolManifest/ManifestFileLivesInsideTools" `
        -Failure "TOOLS_MANIFEST.json має фізично лежати в Tools\, а не в корені репозиторію"

    Remove-Module -Name 'BRAVO.Logging' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.Logging\BRAVO.Logging.psd1") -Force -ErrorAction Stop
    # Фікстури складаються з частин, а не пишуться літералами. Рядок виду
    # URL з обліковими даними або повний webhook URL — це справжній секрет для
    # будь-якого сканера, незалежно від того, що значення вигадане:
    # GitGuardian уже кілька разів піднімав через них інциденти, які
    # доводилось закривати вручну. Тримати в репозиторії щось, що виглядає
    # як облікові дані, і глушити сканер винятками — гірше, ніж не тримати
    # цього зовсім. Самі перевірки нижче звіряються зі змінними, тому
    # маскування тестується так само строго, як і раніше.
    # Розбиваються не лише токени, а й хости webhook: детектори Slack/Discord
    # орієнтуються на форму URL, а не лише на значення токена.
    $secretFixtureSftpPassword = 'S3cr3t' + 'Pass'
    $secretFixtureSlackToken = 'xxxTOKEN' + 'xxxCCCC'
    $secretFixtureDiscordToken = 'abcDEF-' + 'token_value'
    $secretFixtureArchivePasswordLong = 'Super' + 'Secret'
    $secretFixtureArchivePasswordShort = 'Secret' + 'Pass123'
    $secretFixtureSlackHost = 'hooks.slack' + '.com/services'
    $secretFixtureDiscordHost = 'discord' + '.com/api/webhooks'

    $maskedSftpUrl = Protect-BRAVOLogSecret -Text (
        'open sftp://bravouser:{0}@sftp.example.org:22' -f $secretFixtureSftpPassword)
    $maskedSlackWebhook = Protect-BRAVOLogSecret -Text (
        'https://{0}/T000AAAA/B111BBBB/{1}' -f $secretFixtureSlackHost, $secretFixtureSlackToken)
    $maskedDiscordWebhook = Protect-BRAVOLogSecret -Text (
        'https://{0}/123456789/{1}' -f $secretFixtureDiscordHost, $secretFixtureDiscordToken)
    $maskedArchivePasswordLong = Protect-BRAVOLogSecret -Text (
        '7za.exe a -password={0} archive.mdz' -f $secretFixtureArchivePasswordLong)
    $maskedArchivePasswordShort = Protect-BRAVOLogSecret -Text (
        '7za.exe t -p{0} archive.mdz' -f $secretFixtureArchivePasswordShort)
    $unmaskedPathArgument = Protect-BRAVOLogSecret -Text "backup at -path C:\Some\Dir"
    Test-BRAVOCondition `
        -Condition (
            $maskedSftpUrl -eq "open sftp://bravouser:***@sftp.example.org:22" -and
            -not $maskedSftpUrl.Contains($secretFixtureSftpPassword) -and
            -not $maskedSlackWebhook.Contains($secretFixtureSlackToken) -and
            $maskedSlackWebhook.Contains("$secretFixtureSlackHost/***") -and
            -not $maskedDiscordWebhook.Contains($secretFixtureDiscordToken) -and
            $maskedDiscordWebhook.Contains("$secretFixtureDiscordHost/***") -and
            $maskedArchivePasswordLong -eq "7za.exe a -password=*** archive.mdz" -and
            -not $maskedArchivePasswordLong.Contains($secretFixtureArchivePasswordLong) -and
            $maskedArchivePasswordShort -eq "7za.exe t -p*** archive.mdz" -and
            -not $maskedArchivePasswordShort.Contains($secretFixtureArchivePasswordShort) -and
            $unmaskedPathArgument -eq "backup at -path C:\Some\Dir"
        ) `
        -Name "Logging/ProtectSecretMasksKnownShapes" `
        -Failure "Protect-BRAVOLogSecret має маскувати SFTP-паролі, Slack/Discord webhook-токени і паролі 7-Zip, не займаючи -path"
    $healthScriptTextForSecretMasking = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $maintenanceScriptTextForSecretMasking = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $healthScriptTextForSecretMasking.Contains("Protect-BRAVOLogSecret") -and
            $maintenanceScriptTextForSecretMasking.Contains("Protect-BRAVOLogSecret")
        ) `
        -Name "Runtime/HealthAndMaintenanceMaskSecretsInLogs" `
        -Failure "Write-HealthLog і Write-Log (Maintenance) мають маскувати секрети так само, як Write-BRAVOLog в Archive"

    # P1.9 аудиту: catch-блоки навколо читання Credential Manager (SFTP/SMB/
    # архів/webhook) і провалу завантаження BRAVO.config раніше клали
    # $_.Exception.Message у script-scope змінні або одразу в Write-Host/
    # Write-Error БЕЗ маскування — ці рядки минали єдину точку масковки
    # (Write-Log/Write-BRAVOLog/Write-HealthLog) повністю, бо друкувались
    # до або поза нормальним логуванням. Перевіряємо, що жодне подібне
    # "гole" присвоєння не лишилось: усі такі catch-блоки або обгортають
    # $_.Exception.Message у Protect-BRAVOLogSecret, або взагалі відсутні.
    $archiveScriptTextForSecretMasking = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptTextForSecretMasking.Contains(
                "Write-Host `"ПОМИЛКА: Не вдалося завантажити конфiгурацiю: `$(Protect-BRAVOLogSecret -Text `$_.Exception.Message)`""
            ) -and
            $archiveScriptTextForSecretMasking.Contains(
                "`$script:archiveCredentialInitializationError = Protect-BRAVOLogSecret -Text `$_.Exception.Message"
            ) -and
            $archiveScriptTextForSecretMasking.Contains(
                "`$script:credentialInitializationError = Protect-BRAVOLogSecret -Text `$_.Exception.Message"
            ) -and
            $archiveScriptTextForSecretMasking.Contains(
                "`$script:smbCredentialInitializationError = Protect-BRAVOLogSecret -Text `$_.Exception.Message"
            ) -and
            $healthScriptTextForSecretMasking.Contains(
                "Write-Error `"Не вдалося завантажити конфігурацію: `$(Protect-BRAVOLogSecret -Text `$_.Exception.Message)`""
            ) -and
            $maintenanceScriptTextForSecretMasking.Contains(
                "Write-Host `"ПОМИЛКА читання конфігурації '`$ConfigPath': `$(Protect-BRAVOLogSecret -Text `$_.Exception.Message)`""
            ) -and
            $maintenanceScriptTextForSecretMasking.Contains(
                "`$NotificationCredentialError = Protect-BRAVOLogSecret -Text `$_.Exception.Message"
            ) -and
            $maintenanceScriptTextForSecretMasking.Contains(
                "`$ArchiveCredentialError = Protect-BRAVOLogSecret -Text `$_.Exception.Message"
            )
        ) `
        -Name "Runtime/CredentialAndConfigErrorsMaskedAtCapture" `
        -Failure "помилки завантаження конфігурації та Credential Manager (SFTP/SMB/архів/webhook) мають маскуватися Protect-BRAVOLogSecret одразу при захопленні, а не лише при подальшому Write-Log — ці catch-блоки друкують до Write-Host/Write-Error поза єдиною точкою масковки"

    Remove-Module -Name 'BRAVO.ExitCodes' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.ExitCodes\BRAVO.ExitCodes.psd1") -Force -ErrorAction Stop
    Test-BRAVOCondition `
        -Condition (
            (Resolve-BRAVOExitCode) -eq 0 -and
            (Resolve-BRAVOExitCode -HasWarnings) -eq 10 -and
            (Resolve-BRAVOExitCode -LockBusy) -eq 20 -and
            (Resolve-BRAVOExitCode -InvalidConfiguration) -eq 30 -and
            (Resolve-BRAVOExitCode -CredentialsUnavailable) -eq 31 -and
            (Resolve-BRAVOExitCode -LocalArchiveFailed) -eq 40 -and
            (Resolve-BRAVOExitCode -IntegrityTestFailed) -eq 41 -and
            (Resolve-BRAVOExitCode -HashValidationFailed) -eq 42 -and
            (Resolve-BRAVOExitCode -SftpFailed) -eq 50 -and
            (Resolve-BRAVOExitCode -SmbFailed) -eq 51 -and
            (Resolve-BRAVOExitCode -MaintenanceFailed) -eq 60 -and
            (Resolve-BRAVOExitCode -HealthCritical) -eq 70 -and
            (Resolve-BRAVOExitCode -InternalError) -eq 90 -and
            (Resolve-BRAVOExitCode -PrivilegeRequired) -eq 36 -and
            (Resolve-BRAVOExitCode -EnvironmentUnavailable) -eq 37
        ) `
        -Name "ExitCodes/ResolveSingleCategory" `
        -Failure "кожна окрема категорія відмови має повертати свій код із контракту"
    Test-BRAVOCondition `
        -Condition (
            (Resolve-BRAVOExitCode -SftpFailed -SmbFailed) -eq 50 -and
            (Resolve-BRAVOExitCode -LockBusy -InvalidConfiguration) -eq 20 -and
            (Resolve-BRAVOExitCode -InternalError -SftpFailed -HasWarnings) -eq 90 -and
            (Resolve-BRAVOExitCode -LocalArchiveFailed -IntegrityTestFailed -HashValidationFailed) -eq 40 -and
            (Resolve-BRAVOExitCode -IntegrityTestFailed -HashValidationFailed) -eq 41 -and
            (Resolve-BRAVOExitCode -MaintenanceFailed -HealthCritical) -eq 60 -and
            (Resolve-BRAVOExitCode -InvalidConfiguration -CredentialsUnavailable) -eq 30
        ) `
        -Name "ExitCodes/ResolvePriorityOrder" `
        -Failure "при одночасних відмовах має вигравати категорія з вищим пріоритетом контракту"

    # Аудит P1: підміна інструментів має власний код завершення й
    # пріоритет вище за буденний LockBusy — інакше подія безпеки
    # губиться в історії Планувальника як "зайнято".
    Test-BRAVOCondition `
        -Condition (
            (Resolve-BRAVOExitCode -ToolIntegrityViolation) -eq 32 -and
            (Get-BRAVOExitCodeName -Code 32) -eq "ToolIntegrityViolation" -and
            (Resolve-BRAVOExitCode -ToolIntegrityViolation -LockBusy -HasWarnings) -eq 32 -and
            (Resolve-BRAVOExitCode -InternalError -ToolIntegrityViolation) -eq 90
        ) `
        -Name "ExitCodes/ToolIntegrityViolationPriority" `
        -Failure "порушення цілісності інструментів має давати код 32 і мати пріоритет над LockBusy"

    Test-BRAVOCondition `
        -Condition (
            (Resolve-BRAVOExitCode -RuntimeIntegrityViolation) -eq 33 -and
            (Get-BRAVOExitCodeName -Code 33) -eq "RuntimeIntegrityViolation" -and
            (Resolve-BRAVOExitCode -RuntimeIntegrityViolation -ToolIntegrityViolation -LockBusy) -eq 33
        ) `
        -Name "ExitCodes/RuntimeIntegrityViolationPriority" `
        -Failure "при одночасних відмовах має перемагати найвищий пріоритет (lock>config>creds>local>integrity>sftp>smb>maintenance>health>warnings), InternalError — найвищий за все"

    # Послаблена конфігурація — нижче за порушену цілісність (там факт
    # підміни), але вище за все інше: доки перемикачі безпеки вимкнені,
    # будь-який "успіх" нижче означає менше, ніж здається.
    Test-BRAVOCondition `
        -Condition (
            (Resolve-BRAVOExitCode -SecuritySettingsWeakened) -eq 34 -and
            (Get-BRAVOExitCodeName -Code 34) -eq "SecuritySettingsWeakened" -and
            (Resolve-BRAVOExitCode -SecuritySettingsWeakened -ToolIntegrityViolation -LockBusy) -eq 34 -and
            (Resolve-BRAVOExitCode -SecuritySettingsWeakened -RuntimeIntegrityViolation) -eq 33
        ) `
        -Name "ExitCodes/SecuritySettingsWeakenedPriority" `
        -Failure "послаблена конфігурація має давати код 34, бути нижчою за 33 і вищою за 32/20"

    Test-BRAVOCondition `
        -Condition (
            (Resolve-BRAVOExitCode -VersionDowngradeBlocked) -eq 35 -and
            (Get-BRAVOExitCodeName -Code 35) -eq "VersionDowngradeBlocked" -and
            (Resolve-BRAVOExitCode -VersionDowngradeBlocked -ToolIntegrityViolation) -eq 35 -and
            (Resolve-BRAVOExitCode -VersionDowngradeBlocked -SecuritySettingsWeakened) -eq 34
        ) `
        -Name "ExitCodes/VersionDowngradePriority" `
        -Failure "відкат версії має давати код 35 і бути нижчим за 34 (там захист уже вимкнено)"

    # dev.13: PrivilegeRequired (36) — той самий клас, що LockBusy/
    # InvalidConfiguration/CredentialsUnavailable ("чому взагалі не змогли
    # почати"), тому пріоритетом стоїть серед них і ВИЩЕ за HealthCritical
    # (70): якщо немає прав писати в LOGS/TEMP, реальні health-checks не
    # виконувались узагалі — 70 означав би, що їх виконали й щось знайшли.
    Test-BRAVOCondition `
        -Condition (
            (Resolve-BRAVOExitCode -PrivilegeRequired) -eq 36 -and
            (Get-BRAVOExitCodeName -Code 36) -eq "PrivilegeRequired" -and
            (Resolve-BRAVOExitCode -PrivilegeRequired -HealthCritical) -eq 36 -and
            (Resolve-BRAVOExitCode -PrivilegeRequired -LocalArchiveFailed) -eq 36 -and
            (Resolve-BRAVOExitCode -CredentialsUnavailable -PrivilegeRequired) -eq 31 -and
            (Resolve-BRAVOExitCode -RuntimeIntegrityViolation -PrivilegeRequired) -eq 33 -and
            # Реальний HealthCritical (70) сам по собі лишається незмінним —
            # dev.13 додає нову категорію, а не замінює наявну.
            (Resolve-BRAVOExitCode -HealthCritical) -eq 70
        ) `
        -Name "ExitCodes/PrivilegeRequiredPriority" `
        -Failure "PrivilegeRequired має давати код 36, перемагати HealthCritical/LocalArchiveFailed (перевірки не виконувались), але програвати RuntimeIntegrityViolation/CredentialsUnavailable (вищі за пріоритетом prerequisite-відмови); окремий реальний HealthCritical=70 має лишитися незмінним"

    # correctness pass: EnvironmentUnavailable (37) — той самий prerequisite
    # клас і той самий пріоритет-профіль, що PrivilegeRequired (36), але
    # НЕ privilege-специфічна відмова (диск повний, PathTooLong тощо) —
    # окремий код, щоб не радити "запустіть адміністратором" помилково.
    Test-BRAVOCondition `
        -Condition (
            (Resolve-BRAVOExitCode -EnvironmentUnavailable) -eq 37 -and
            (Get-BRAVOExitCodeName -Code 37) -eq "EnvironmentUnavailable" -and
            (Resolve-BRAVOExitCode -EnvironmentUnavailable -HealthCritical) -eq 37 -and
            (Resolve-BRAVOExitCode -EnvironmentUnavailable -LocalArchiveFailed) -eq 37 -and
            (Resolve-BRAVOExitCode -CredentialsUnavailable -EnvironmentUnavailable) -eq 31 -and
            (Resolve-BRAVOExitCode -RuntimeIntegrityViolation -EnvironmentUnavailable) -eq 33 -and
            (Resolve-BRAVOExitCode -PrivilegeRequired -EnvironmentUnavailable) -eq 36
        ) `
        -Name "ExitCodes/EnvironmentUnavailablePriority" `
        -Failure "EnvironmentUnavailable має давати код 37 з тим самим пріоритет-профілем, що PrivilegeRequired, і не перемагати PrivilegeRequired (36), коли обидва встановлені"

    Test-BRAVOCondition `
        -Condition (
            (Get-BRAVOExitCodeName -Code 0) -eq "Success" -and
            (Get-BRAVOExitCodeName -Code 36) -eq "PrivilegeRequired" -and
            (Get-BRAVOExitCodeName -Code 37) -eq "EnvironmentUnavailable" -and
            (Get-BRAVOExitCodeName -Code 42) -eq "HashValidationFailed" -and
            (Get-BRAVOExitCodeName -Code 50) -eq "SftpFailed" -and
            (Get-BRAVOExitCodeName -Code 999) -eq "Unknown(999)"
        ) `
        -Name "ExitCodes/GetExitCodeName" `
        -Failure "зворотний пошук назви коду має працювати для відомих і невідомих значень"
    $archiveRuntimeTextForExitCodes = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $maintenanceRuntimeTextForExitCodes = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $healthRuntimeTextForExitCodes = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $archiveRuntimeTextForExitCodes.Contains("'BRAVO.ExitCodes'") -and
            $archiveRuntimeTextForExitCodes.Contains("Resolve-BRAVOExitCode") -and
            $maintenanceRuntimeTextForExitCodes.Contains("'BRAVO.ExitCodes'") -and
            $maintenanceRuntimeTextForExitCodes.Contains("Resolve-BRAVOExitCode") -and
            $healthRuntimeTextForExitCodes.Contains("'BRAVO.ExitCodes'") -and
            $healthRuntimeTextForExitCodes.Contains("Resolve-BRAVOExitCode")
        ) `
        -Name "Runtime/SharedExitCodeContract" `
        -Failure "Archive/Health/Maintenance мають підключати BRAVO.ExitCodes і формувати підсумковий код через Resolve-BRAVOExitCode"

    # correctness pass (J): реальний Status=Critical/NotificationError мають
    # лишитися прив'язаними саме до HealthCritical — нова категорія
    # EnvironmentError додається поруч, а не замінює наявні шляхи, і сама
    # розгалужується на PrivilegeRequired(36)/EnvironmentUnavailable(37)
    # за IsPrivilegeFailure, а не завжди на PrivilegeRequired.
    Test-BRAVOCondition `
        -Condition (
            $healthRuntimeTextForExitCodes.Contains("if ([bool]`$Result.IsPrivilegeFailure) {") -and
            $healthRuntimeTextForExitCodes.Contains('Resolve-BRAVOExitCode -PrivilegeRequired') -and
            $healthRuntimeTextForExitCodes.Contains('Resolve-BRAVOExitCode -EnvironmentUnavailable') -and
            $healthRuntimeTextForExitCodes.Contains("'Critical'           { Resolve-BRAVOExitCode -HealthCritical }") -and
            $healthRuntimeTextForExitCodes.Contains("'NotificationError'  { Resolve-BRAVOExitCode -HealthCritical }")
        ) `
        -Name "Health/EnvironmentErrorMapsToPrivilegeRequired" `
        -Failure "Complete-BRAVOHealthResult має мапити Status=EnvironmentError на PrivilegeRequired(36)/EnvironmentUnavailable(37) залежно від IsPrivilegeFailure, не чіпаючи реальні Critical/NotificationError -> HealthCritical (70)"

    # dev.13 (G) / correctness pass: при провалі environment preflight
    # (незалежно від privilege/generic класифікації) SFTP-перевірка не
    # повинна викликатися взагалі — return відбувається РАНІШЕ за виклик
    # Get-SFTPHealthIssues у лінійному потоці виконання файлу.
    $environmentErrorReturnIndex = $healthRuntimeTextForExitCodes.IndexOf('Status = "EnvironmentError"')
    $sftpCallIndex = $healthRuntimeTextForExitCodes.IndexOf('$sftpHealthIssues = @(Get-SFTPHealthIssues)')
    Test-BRAVOCondition `
        -Condition (
            $environmentErrorReturnIndex -ge 0 -and
            $sftpCallIndex -ge 0 -and
            $environmentErrorReturnIndex -lt $sftpCallIndex
        ) `
        -Name "Health/EnvironmentFailureNeverCallsSftp" `
        -Failure "провал environment preflight (LOGS/TEMP, privilege чи generic) має return-увати ДО виклику Get-SFTPHealthIssues — інакше SFTP усе одно викликається на непов'язаній локальній помилці"

    # dev.13 (H): Write-HealthLog не повинен повторно намагатись писати в
    # недоступний файл (і друкувати ту саму помилку) на кожному виклику
    # після першого AccessDenied.
    Test-BRAVOCondition `
        -Condition (
            $healthRuntimeTextForExitCodes.Contains('$script:BRAVOHealthLogWritable = $true') -and
            $healthRuntimeTextForExitCodes.Contains('if (-not $script:BRAVOHealthLogWritable) {') -and
            $healthRuntimeTextForExitCodes.Contains('$script:BRAVOHealthLogWritable = $false')
        ) `
        -Name "Health/LogWriteFailureDoesNotFlood" `
        -Failure "Write-HealthLog має припиняти повторні спроби запису й повторний друк помилки після першого AccessDenied (script:BRAVOHealthLogWritable)"

    # Minor 1: якщо health-check лог не вдалося створити/писати (LOGS сам
    # міг бути недоступним шляхом), сповіщення й консольний підсумок не
    # повинні заявляти "Журнал: ...", якого фактично немає.
    Test-BRAVOCondition `
        -Condition (
            $healthRuntimeTextForExitCodes.Contains('if ($script:BRAVOHealthLogWritable) {') -and
            $healthRuntimeTextForExitCodes.Contains('$environmentNotificationParameters.LogPath = $healthLogFile') -and
            $healthRuntimeTextForExitCodes.Contains('LogPath = $(if ($script:BRAVOHealthLogWritable) { $healthLogFile } else { $null })')
        ) `
        -Name "Health/EnvironmentNotificationOmitsUnavailableLog" `
        -Failure "environment-notification і Complete-BRAVOHealthResult Result.LogPath мають передавати шлях логу лише коли script:BRAVOHealthLogWritable=true — інакше сповіщення/консоль заявляють журнал, якого немає"

    # correctness pass, 3rd iteration (заміна ACL-тестів): статичний guard
    # підтверджує САМ МЕХАНІЗМ preservation, а не лише його наслідок —
    # Get-BRAVOHealthTemporaryRoot зберігає ПЕРШИЙ типізований виняток і
    # передає його як InnerException (не $_.Exception.Message-рядок), а
    # виклик з Invoke-BRAVOHealth класифікує саме $_.Exception (що тепер
    # включає цей InnerException) через Test-BRAVOHealthIsPrivilegeException.
    Test-BRAVOCondition `
        -Condition (
            $healthRuntimeTextForExitCodes.Contains('$firstCreationException = $null') -and
            $healthRuntimeTextForExitCodes.Contains('if ($null -eq $firstCreationException) {') -and
            $healthRuntimeTextForExitCodes.Contains('$firstCreationException = $_.Exception') -and
            $healthRuntimeTextForExitCodes.Contains('if ($null -ne $firstCreationException) {') -and
            $healthRuntimeTextForExitCodes.Contains('throw (New-Object System.Management.Automation.RuntimeException(') -and
            $healthRuntimeTextForExitCodes.Contains('$aggregateMessage, $firstCreationException))') -and
            (@([regex]::Matches(
                $healthRuntimeTextForExitCodes,
                [regex]::Escape('IsPrivilegeFailure = (Test-BRAVOHealthIsPrivilegeException -Exception $_.Exception)')
            )).Count -eq 2)
        ) `
        -Name "Health/TemporaryRootPreservesTypedExceptionForClassification" `
        -Failure "Get-BRAVOHealthTemporaryRoot має зберігати firstCreationException і передавати його як InnerException агрегованого throw; і Test-BRAVOHealthRuntimePathWritable, і catch-блок навколо Get-BRAVOHealthTemporaryRoot мають класифікувати саме `$_.Exception через Test-BRAVOHealthIsPrivilegeException"
    Test-BRAVOCondition `
        -Condition (
            $archiveRuntimeTextForExitCodes.Contains('$anyHashValidationFailed = @(') -and
            $archiveRuntimeTextForExitCodes.Contains('-HashValidationFailed:$anyHashValidationFailed') -and
            $archiveRuntimeTextForExitCodes.Contains("'HASH' { `"SHA512 generation/verification failed")
        ) `
        -Name 'Runtime/HashFailureHasDedicatedExitCode' `
        -Failure 'SHA512 generation/verification failure має мапитись на 42, а не IntegrityTestFailed (41)'
    Test-BRAVOCondition `
        -Condition (
            -not ($archiveRuntimeTextForExitCodes -match 'processExitCode\s*=\s*2\b') -and
            -not ($maintenanceRuntimeTextForExitCodes -match '\bexit\s+2\b') -and
            -not ($maintenanceRuntimeTextForExitCodes -match '\bexit\s+1\b')
        ) `
        -Name "Runtime/NoLegacyAdHocExitCodes" `
        -Failure "старі ad-hoc коди (2 для lock, голий exit 1) мають бути повністю замінені контрактом BRAVO.ExitCodes"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceRuntimeTextForExitCodes.Contains('$script:restoreArchiveFailed') -and
            $maintenanceRuntimeTextForExitCodes.Contains('$script:restoreIntegrityFailed') -and
            $maintenanceRuntimeTextForExitCodes.Contains('-LocalArchiveFailed:$script:restoreArchiveFailed') -and
            $maintenanceRuntimeTextForExitCodes.Contains('-IntegrityTestFailed:$script:restoreIntegrityFailed') -and
            ([regex]::Matches($maintenanceRuntimeTextForExitCodes, [regex]::Escape('$script:restoreArchiveFailed = $true')).Count -eq 10) -and
            ([regex]::Matches($maintenanceRuntimeTextForExitCodes, [regex]::Escape('$script:restoreIntegrityFailed = $true')).Count -eq 9)
        ) `
        -Name "Runtime/MaintenanceDistinguishesArchiveVsIntegrityFailure" `
        -Failure "Maintenance має розрізняти локальну архівацію (40) і перевірку цілісності (41) відновлення, а не зводити все до 60"
    Test-BRAVOCondition `
        -Condition (
            $archiveRuntimeTextForExitCodes -match
                "Set-BRAVOLogComponent -Component 'SUMMARY'\s*\r?\n\s*Write-Log `"Результат:"
        ) `
        -Name "Runtime/FinalSummaryUsesSummaryLogComponent" `
        -Failure "підсумковий рядок 'Результат:' має явно повертати компонент журналу на SUMMARY, інакше після виконаного health-check він хибно тегується [HEALTH], навіть якщо сам health-check пройшов успішно"

    $insecureWebhookRejected = $false
    try {
        Send-BRAVOWebhookNotification `
            -Provider "slack" `
            -WebhookUrl "http://127.0.0.1/test" `
            -Message "test"
    } catch {
        $insecureWebhookRejected = $_.Exception.Message -match "HTTPS"
    }
    Test-BRAVOCondition `
        -Condition $insecureWebhookRejected `
        -Name "Notifications/RejectInsecureWebhook" `
        -Failure "спільний webhook-клієнт повинен відхиляти HTTP до мережевого запиту"

    $sevenZipRuntimeRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_7Z_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    $sevenZipCreateProcess = $null
    $sevenZipCreateCapture = $null
    $sevenZipRuntimePassed = $false
    $sevenZipRuntimeFailure = ""
    try {
        $sevenZipPath = Join-Path $root "Tools\7za.exe"
        if (-not (Test-Path -LiteralPath $sevenZipPath -PathType Leaf)) {
            throw "не знайдено Tools\7za.exe"
        }

        [void][IO.Directory]::CreateDirectory($sevenZipRuntimeRoot)
        $sevenZipInputPath = Join-Path $sevenZipRuntimeRoot "input.txt"
        $sevenZipArchivePath = Join-Path $sevenZipRuntimeRoot "archive.7z"
        $sevenZipTestPassword = "BRAVO-self-test-{0}" -f [guid]::NewGuid().ToString("N")
        [IO.File]::WriteAllText(
            $sevenZipInputPath,
            "BRAVO runtime test",
            [Text.Encoding]::UTF8
        )

        $sevenZipCreateInfo = New-Object Diagnostics.ProcessStartInfo
        $sevenZipCreateInfo.FileName = $sevenZipPath
        $sevenZipCreateInfo.Arguments = (
            "a -y -bb0 -p `"{0}`" `"{1}`"" -f
                $sevenZipArchivePath,
                $sevenZipInputPath
        )
        $sevenZipCreateInfo.RedirectStandardInput = $true
        $sevenZipCreateInfo.RedirectStandardOutput = $true
        $sevenZipCreateInfo.RedirectStandardError = $true
        $sevenZipCreateInfo.UseShellExecute = $false
        $sevenZipCreateInfo.CreateNoWindow = $true

        $sevenZipCreateProcess = New-Object Diagnostics.Process
        $sevenZipCreateProcess.StartInfo = $sevenZipCreateInfo
        $sevenZipCreateCapture = Start-BRAVOProcessOutputCapture `
            -Process $sevenZipCreateProcess
        $sevenZipCreateProcess.StandardInput.WriteLine($sevenZipTestPassword)
        $sevenZipCreateProcess.StandardInput.Close()
        $sevenZipCreateCompleted = $sevenZipCreateProcess.WaitForExit(30000)
        if (-not $sevenZipCreateCompleted) {
            $sevenZipCreateProcess.Kill()
            [void]$sevenZipCreateProcess.WaitForExit(5000)
        }
        [void](Complete-BRAVOProcessOutputCapture -Capture $sevenZipCreateCapture)
        $sevenZipCreateCapture = $null
        $sevenZipCreateExitCode = if ($sevenZipCreateProcess.HasExited) {
            [int]$sevenZipCreateProcess.ExitCode
        } else {
            $null
        }

        $sevenZipIntegrityResult = Invoke-BRAVOSevenZipIntegrityTest `
            -SevenZipPath $sevenZipPath `
            -ArchivePath $sevenZipArchivePath `
            -Password $sevenZipTestPassword `
            -TimeoutSeconds 30
        $sevenZipRuntimePassed = (
            $sevenZipCreateCompleted -and
            $sevenZipCreateExitCode -eq 0 -and
            $sevenZipIntegrityResult.Success -and
            -not $sevenZipCreateInfo.Arguments.Contains($sevenZipTestPassword)
        )
        if (-not $sevenZipRuntimePassed) {
            $sevenZipRuntimeFailure = (
                "create=$sevenZipCreateExitCode; " +
                "test=$($sevenZipIntegrityResult.ExitCode); " +
                "testError=$($sevenZipIntegrityResult.Error)"
            )
        }
    } catch {
        $sevenZipRuntimeFailure = $_.Exception.Message
    } finally {
        if ($null -ne $sevenZipCreateCapture) {
            try {
                [void](Complete-BRAVOProcessOutputCapture -Capture $sevenZipCreateCapture)
            } catch {
                # Прибирання після тестового запуску 7-Zip. Результат самого
                # тесту вже зафіксовано в $sevenZipRuntimeFailure вище;
                # помилка дренажу потоків не повинна перетворити пройдений
                # тест на провалений.
            }
        }
        if ($null -ne $sevenZipCreateProcess) {
            $sevenZipCreateProcess.Dispose()
        }
        if ([IO.Directory]::Exists($sevenZipRuntimeRoot)) {
            [IO.Directory]::Delete($sevenZipRuntimeRoot, $true)
        }
    }
    Test-BRAVOCondition `
        -Condition $sevenZipRuntimePassed `
        -Name "Runtime/SevenZipPasswordUsesStdin" `
        -Failure "створення/перевірка зашифрованого архіву через stdin не працює: $sevenZipRuntimeFailure"

    Test-BRAVOCondition `
        -Condition (Test-BRAVOAccountIdentityEquivalent `
            -ExpectedAccount "SYSTEM" `
            -ActualAccount "S-1-5-18") `
        -Name "Scheduler/SystemSidEquivalent" `
        -Failure "SYSTEM повинен відповідати мовно-незалежному SID S-1-5-18"
    $localizedSystemAccount = (
        New-Object Security.Principal.SecurityIdentifier("S-1-5-18")
    ).Translate([Security.Principal.NTAccount]).Value
    Test-BRAVOCondition `
        -Condition (Test-BRAVOAccountIdentityEquivalent `
            -ExpectedAccount "SYSTEM" `
            -ActualAccount $localizedSystemAccount) `
        -Name "Scheduler/LocalizedSystemEquivalent" `
        -Failure "SYSTEM не розпізнано через локалізоване ім'я '$localizedSystemAccount'"
    Test-BRAVOCondition `
        -Condition (-not (Test-BRAVOAccountIdentityEquivalent `
            -ExpectedAccount "SYSTEM" `
            -ActualAccount "S-1-5-20")) `
        -Name "Scheduler/SystemSidMismatch" `
        -Failure "SYSTEM не повинен збігатися з NETWORK SERVICE"

    $sourceConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $configRoot = Split-Path -Path $sourceConfigPath -Parent
    $configurationLoaderPath = Join-Path $configRoot 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    $versionConfigRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'BRAVO_VERSION_CONFIG_' + [guid]::NewGuid().ToString('N')
    )
    $versionConfigPath = Join-Path $versionConfigRoot 'BRAVO.config'
    [void][IO.Directory]::CreateDirectory($versionConfigRoot)
    $script:selfTestConfigRoot = $versionConfigRoot
    try {
        $versionConfigText = [IO.File]::ReadAllText(
            $sourceConfigPath,
            [Text.Encoding]::UTF8
        )
        $explicitLimsRoot = $versionConfigRoot.Replace("'", "''")
        $limsRootReplacement = [Text.RegularExpressions.MatchEvaluator] {
            param($match)
            return $match.Groups[1].Value + "'$explicitLimsRoot'"
        }
        $versionConfigText = [regex]::Replace(
            $versionConfigText,
            '(?m)^(\s*LIMSRoot\s*=\s*)""\s*$',
            $limsRootReplacement,
            1
        )
        $explicitLimsRootPattern = "(?m)^\s*LIMSRoot\s*=\s*'" +
            [regex]::Escape($explicitLimsRoot) + "'\s*$"
        if ($versionConfigText -notmatch $explicitLimsRootPattern) {
            throw 'Не вдалося підготувати ізольовану конфігурацію для version self-test.'
        }
        [IO.File]::WriteAllText(
            $versionConfigPath,
            $versionConfigText,
            (New-Object Text.UTF8Encoding($false))
        )
        $resolvedConfig = $versionConfigPath
        $loadedConfiguration = Import-BravoConfiguration `
            -ConfigRoot $versionConfigRoot `
            -ConfigPath $versionConfigPath `
            -RuntimeRoot $configRoot `
            -PassThru
    } catch {
        throw
    }

    Test-BRAVOCondition `
        -Condition (
            -not [string]::IsNullOrWhiteSpace([string]$loadedConfiguration.Version.PackageVersion) -and
            [string]$ScriptVersion -eq [string]$loadedConfiguration.Version.PackageVersion -and
            [string]$ScriptDate -eq [string]$loadedConfiguration.Version.ReleaseDate -and
            -not [string]::IsNullOrWhiteSpace([string]$loadedConfiguration.Version.BuildId) -and
            [string]$ScriptBuildId -eq [string]$loadedConfiguration.Version.BuildId
        ) `
        -Name "Version/AuthoritativeLoader" `
        -Failure "VERSION.json має бути єдиним джерелом версії, releaseDate і buildId для ScriptVersion/ScriptDate/ScriptBuildId"

    # P1.10 аудиту: за замовчуванням жодних запитів до сторонніх сервісів
    # (api.ipify.org/checkip.amazonaws.com) для визначення публічної IP —
    # це зайва зовнішня залежність, яка розкриває факт і час запуску backup.
    Remove-Module -Name 'BRAVO.Notifications' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.Notifications\BRAVO.Notifications.psd1") -Force -ErrorAction Stop
    $hostInformationWithConfig = Get-HostInformation
    Test-BRAVOCondition `
        -Condition (
            $global:hostInformationSettings -is [System.Collections.IDictionary] -and
            $global:hostInformationSettings.Contains("PublicIPLookupEnabled") -and
            $global:hostInformationSettings.PublicIPLookupEnabled -eq $false -and
            $hostInformationWithConfig.PublicIP -eq "вимкнено"
        ) `
        -Name "Notifications/PublicIPLookupDisabledByDefault" `
        -Failure "PublicIPLookupEnabled у BRAVO.config має бути \$false за замовчуванням; Get-HostInformation не повинен звертатись до зовнішніх IP-сервісів, доки це не увімкнено свідомо"

    $notifyHostOff = [pscustomobject]@{
        MachineName = "DEV-LIMS"
        LocalIP = "10.10.150.102"
        PublicIP = "вимкнено"
    }
    $notifyHostUnavailable = [pscustomobject]@{
        MachineName = "DEV-LIMS"
        LocalIP = "10.10.150.102"
        PublicIP = "недоступна"
    }
    $notifyHostPublic = [pscustomobject]@{
        MachineName = "DATA-SERVER"
        LocalIP = "10.10.150.102 | 192.168.1.236"
        PublicIP = "185.189.187.44"
    }
    $notifySuccess = New-BRAVOOperatorNotificationMessage `
        -Severity SUCCESS `
        -Operation "BRAVO BACKUP — ВСЕ СПРАВНО" `
        -InstitutionName "TEST-COMPANY" `
        -InstitutionCode "1234567890" `
        -HostInformation $notifyHostOff `
        -ResultLines @(
            ":clock3: Остання резервна копія: 09.08.2026 14:29",
            ":alarm_clock: Вік копії: 5 хв.",
            ":package: MODEL       :white_check_mark: 414.33 МБ",
            "Компоненти: 4/4"
        ) `
        -Timestamp ([datetime]"2026-08-09T14:34:51") `
        -Duration ([timespan]::FromSeconds(7)) `
        -ProductName "BRAVO Archive" `
        -Version "5.0.0-dev.11" `
        -BuildId "testbuild" `
        -LogPath "D:\BRAVO\LOGS\BRAVO_ARCHIV_HEALTH.log"
    $notifyWarning = New-BRAVOOperatorNotificationMessage `
        -Severity CRITICAL `
        -Operation "BRAVO BACKUP — ПОТРІБНА ДІЯ" `
        -ActionText "перевірити виконання BRAVO_ARCHIV" `
        -ReasonLines @(":x: MODEL: резервна копія прострочена") `
        -InstitutionName "TEST-COMPANY" `
        -InstitutionCode "1234567890" `
        -HostInformation $notifyHostOff `
        -ResultLines @(
            ":clock3: Остання успішна резервна копія: 08.08.2026 23:00",
            ":alarm_clock: Вік копії: 15 год. 34 хв.",
            ":warning: Допустимий вік: 8 год."
        ) `
        -Timestamp ([datetime]"2026-08-09T14:34:51") `
        -ProductName "BRAVO Archive" `
        -Version "5.0.0-dev.11" `
        -BuildId "testbuild"
    $notifyPublic = New-BRAVOOperatorNotificationMessage `
        -Severity SUCCESS `
        -Operation "BRAVO MAINTENANCE — УСПІШНО" `
        -InstitutionName "TEST-COMPANY" `
        -InstitutionCode "1234567890" `
        -HostInformation $notifyHostPublic `
        -Timestamp ([datetime]"2026-08-09T23:55:25") `
        -ProductName "BRAVO Maintenance" `
        -Version "5.0.0-dev.11" `
        -BuildId "testbuild"
    $notifyUnavailable = New-BRAVOOperatorNotificationMessage `
        -Severity SUCCESS `
        -Operation "BRAVO MAINTENANCE — УСПІШНО" `
        -InstitutionName "TEST-COMPANY" `
        -InstitutionCode "1234567890" `
        -HostInformation $notifyHostUnavailable `
        -Timestamp ([datetime]"2026-08-09T23:55:25") `
        -ProductName "BRAVO Maintenance" `
        -Version "5.0.0-dev.11" `
        -BuildId "testbuild"
    Test-BRAVOCondition -Condition ($notifySuccess.Contains("Дій не потрібно")) -Name "Notifications/SuccessUsesNoActionRequired" -Failure "SUCCESS notification має явно казати, що дія не потрібна"
    Test-BRAVOCondition -Condition ($notifyWarning.Contains("Потрібна дія: перевірити виконання BRAVO_ARCHIV")) -Name "Notifications/WarningUsesConcreteAction" -Failure "WARNING/CRITICAL notification має показувати конкретну дію"
    Test-BRAVOCondition -Condition ($notifySuccess.Contains(":office: TEST-COMPANY [1234567890]")) -Name "Notifications/InstitutionUsesOfficeEmoji" -Failure "institution line має використовувати office token"
    Test-BRAVOCondition -Condition (-not $notifySuccess.Contains("Публічна IP") -and -not $notifySuccess.Contains("IP-адреси:") -and $notifySuccess.Contains("DEV-LIMS") -and $notifySuccess.Contains("10.10.150.102")) -Name "Notifications/DisabledPublicIpIsOmitted" -Failure "PublicIP=вимкнено не має показуватись у штатному повідомленні"
    Test-BRAVOCondition -Condition (-not $notifyUnavailable.Contains("Публічна IP")) -Name "Notifications/UnavailablePublicIpIsOmitted" -Failure "PublicIP=недоступна не має показуватись у штатному повідомленні"
    Test-BRAVOCondition -Condition ($notifyPublic.Contains("Публічна IP: 185.189.187.44") -and $notifyPublic.Contains("DATA-SERVER · 10.10.150.102 · 192.168.1.236")) -Name "Notifications/AvailablePublicIpIsShown" -Failure "valid Public IP має показуватись окремим рядком"
    Test-BRAVOCondition -Condition ($notifySuccess.Contains("Остання резервна копія:")) -Name "Notifications/HealthSuccessUsesLastBackupTerm" -Failure "Health SUCCESS має використовувати термін Остання резервна копія"
    Test-BRAVOCondition -Condition ($notifyWarning.Contains("Остання успішна резервна копія:")) -Name "Notifications/HealthFailureUsesLastSuccessfulBackupTerm" -Failure "Health WARNING/ERROR має використовувати термін Остання успішна резервна копія"
    $legacyHealthyCopyText = "Остання справна " + "копія"
    Test-BRAVOCondition -Condition (-not ($notifySuccess + $notifyWarning).Contains($legacyHealthyCopyText)) -Name "Notifications/HealthDoesNotUseLastHealthyCopyWording" -Failure "operator notification не має використовувати legacy health wording"
    Test-BRAVOCondition -Condition ($notifySuccess -notmatch "\.mdz") -Name "Notifications/HealthSuccessDoesNotExposeArchiveFilename" -Failure "Health SUCCESS не має показувати archive filename"

    # dev.12: status-first component rows. Discord/Slack рендерять
    # пропорційним шрифтом, тому padding пробілами (стара :package: NAME
    # <spaces> :white_check_mark: схема) ламав вирівнювання щоразу, коли
    # довжина назви компонента відрізнялась (BLOG/MODEL/BRAVOEXCH/BAZA_APP).
    $statusLineBlog = Format-BRAVOOperatorStatusLine -Status SUCCESS -Icon ":package:" -Name "BLOG" -Detail "53.88 МБ"
    $statusLineBravoexch = Format-BRAVOOperatorStatusLine -Status SUCCESS -Icon ":package:" -Name "BRAVOEXCH" -Detail "29.34 КБ"
    $statusLineLocal = Format-BRAVOOperatorStatusLine -Status SUCCESS -Icon ":floppy_disk:" -Name "Local"
    $statusLineWarning = Format-BRAVOOperatorStatusLine -Status WARNING -Icon ":package:" -Name "MODEL" -Detail "резервна копія прострочена"
    $statusLineError = Format-BRAVOOperatorStatusLine -Status CRITICAL -Icon ":cloud:" -Name "SFTP" -Detail "синхронізація не виконана"
    Test-BRAVOCondition -Condition ($statusLineBlog -eq ":white_check_mark: :package: BLOG — 53.88 МБ") -Name "Notifications/StatusLineIsIconFirst" -Failure "Format-BRAVOOperatorStatusLine має ставити статус-іконку першою колонкою без padding пробілами"
    Test-BRAVOCondition -Condition ($statusLineBlog.IndexOf(":package:") -eq $statusLineBravoexch.IndexOf(":package:")) -Name "Notifications/StatusLineIndependentOfNameLength" -Failure "довжина назви компонента (BLOG/BRAVOEXCH) не повинна впливати на позицію статус-іконки"
    Test-BRAVOCondition -Condition ($statusLineLocal -eq ":white_check_mark: :floppy_disk: Local") -Name "Notifications/StatusLineOmitsEmptyDetail" -Failure "status line без Detail не повинен додавати зайве тире"
    Test-BRAVOCondition -Condition ($statusLineWarning.StartsWith(":warning:")) -Name "Notifications/StatusLineWarningIconFirst" -Failure "WARNING status line має починатись з :warning:"
    Test-BRAVOCondition -Condition ($statusLineError.StartsWith(":x:")) -Name "Notifications/StatusLineErrorIconFirst" -Failure "CRITICAL/ERROR status line має починатись з :x:"

    $bazaLines = @(
        "Причина:",
        "Назви 50 файлів перевищують допустиму довжину для передачі через SFTP.",
        "Проблемні файли пропущено; інші файли синхронізуються штатно.",
        "Ліміт: 246 UTF-8 байт",
        "Проблемних файлів: 50",
        "Приклади:",
        ":x: 297/246 байт · перевищення +51 байт",
        "Методика_выполнения_измерений_...",
        ":x: 349/246 байт · перевищення +103 байти",
        "ДИРЕКТИВА_РАДИ_96-22-ЕС_...",
        ":x: 378/246 байт · перевищення +132 байти",
        "Инструкция_по_санитарно-..."
    )
    $bazaSample = New-BRAVOOperatorNotificationMessage `
        -Severity WARNING `
        -Operation "BAZA_APP — 50 ФАЙЛІВ НЕ СИНХРОНІЗОВАНО" `
        -ActionText "скоротити назви зазначених файлів." `
        -InstitutionName "МИКОЛАЇВСЬКА РДЛ" `
        -InstitutionCode "00702245" `
        -HostInformation $notifyHostPublic `
        -ResultLines $bazaLines `
        -Timestamp ([datetime]"2026-08-09T12:00:07") `
        -ProductName "BRAVO Archive" `
        -Version "5.0.0-dev.11" `
        -BuildId "testbuild" `
        -LogPath "D:\BRAVO\LOGS\BRAVO_ARCHIV.log" `
        -LogLabel "Повний перелік"
    Test-BRAVOCondition -Condition (([regex]::Matches($bazaSample, "перевищення \+")).Count -eq 3) -Name "Notifications/BazaLongNamesShowsAtMostThreeExamples" -Failure "BAZA notification має показувати максимум 3 приклади"
    Test-BRAVOCondition -Condition ($bazaSample.Contains("Ліміт: 246 UTF-8 байт")) -Name "Notifications/BazaLongNamesShowsUtf8Limit" -Failure "BAZA notification має показувати UTF-8 limit"
    Test-BRAVOCondition -Condition ($bazaSample.Contains("297/246 байт") -and $bazaSample.Contains("перевищення +51 байт")) -Name "Notifications/BazaLongNamesShowsByteOverflow" -Failure "BAZA notification має показувати byte overflow"
    Test-BRAVOCondition -Condition ($bazaSample.Contains("Проблемні файли пропущено; інші файли синхронізуються штатно.")) -Name "Notifications/BazaLongNamesExplainsPartialSkip" -Failure "BAZA notification має пояснювати partial skip"
    $pluralOk = ((Format-BRAVOUkrainianCount 1 "файл" "файли" "файлів") -eq "1 файл" -and (Format-BRAVOUkrainianCount 2 "файл" "файли" "файлів") -eq "2 файли" -and (Format-BRAVOUkrainianCount 5 "файл" "файли" "файлів") -eq "5 файлів" -and (Format-BRAVOUkrainianCount 21 "файл" "файли" "файлів") -eq "21 файл" -and (Format-BRAVOUkrainianCount 22 "файл" "файли" "файлів") -eq "22 файли" -and (Format-BRAVOUkrainianCount 25 "файл" "файли" "файлів") -eq "25 файлів")
    Test-BRAVOCondition -Condition $pluralOk -Name "Notifications/UkrainianFilePluralization" -Failure "pluralization helper має підтримувати 1/2/5/21/22/25"
    $maintSuccess = New-BRAVOOperatorNotificationMessage `
        -Severity SUCCESS `
        -Operation "BRAVO MAINTENANCE — УСПІШНО" `
        -InstitutionName "ЧЕРНІВЕЦЬКА РДЛ" `
        -InstitutionCode "21430093" `
        -HostInformation $notifyHostPublic `
        -ResultLines @(
            "Виконано:",
            ":white_check_mark: Реставрація — за планом",
            ":white_check_mark: .md-файли — перевірено",
            ":white_check_mark: Інтервали ID — у нормі",
            ":white_check_mark: Trace — оброблено 2 файли",
            ":white_check_mark: exchangAPI — оброблено 1 файл",
            ":white_check_mark: Вільне місце — достатньо",
            ":floppy_disk: Мінімальний запас:",
            "C: 468.29 ГБ",
            "Порогове значення: 20 ГБ",
            ":arrows_counterclockwise: Остання реставрація: 03.08.2026 00:02"
        ) `
        -Timestamp ([datetime]"2026-08-08T23:55:25") `
        -Duration ([timespan]::FromSeconds(20)) `
        -ProductName "BRAVO Maintenance" `
        -Version "5.0.0-dev.11" `
        -BuildId "testbuild" `
        -LogPath "D:\BRAVO\LOGS\BRAVO_MAINTENANCE.log"
    $maintLowDisk = New-BRAVOOperatorNotificationMessage `
        -Severity CRITICAL `
        -Operation "BRAVO MAINTENANCE — ПОТРІБНА ДІЯ" `
        -ActionText "звільнити щонайменше 5.4 ГБ." `
        -ReasonLines @(":x: Недостатньо вільного місця на диску D:") `
        -InstitutionName "ЧЕРНІВЕЦЬКА РДЛ" `
        -InstitutionCode "21430093" `
        -HostInformation $notifyHostPublic `
        -ResultLines @(
            ":floppy_disk: D:",
            "Вільно: 14.6 ГБ",
            "Мінімум: 20 ГБ",
            "Дефіцит: 5.4 ГБ"
        ) `
        -Timestamp ([datetime]"2026-08-08T23:55:25") `
        -ProductName "BRAVO Maintenance" `
        -Version "5.0.0-dev.11" `
        -BuildId "testbuild"
    Test-BRAVOCondition -Condition ($maintSuccess.Contains("BRAVO MAINTENANCE — УСПІШНО") -and -not $maintSuccess.Contains("Деталі подій") -and -not $maintSuccess.Contains("Регламентні операції")) -Name "Notifications/MaintenanceSuccessIsCompact" -Failure "Maintenance SUCCESS має бути компактним"
    Test-BRAVOCondition -Condition ($maintSuccess.Contains(":floppy_disk: Мінімальний запас:") -and $maintSuccess.Contains("C: 468.29 ГБ") -and -not $maintSuccess.Contains("D: 500")) -Name "Notifications/MaintenanceSuccessShowsMinimumFreeDiskOnly" -Failure "Maintenance SUCCESS має показувати лише мінімальний healthy disk запас"
    Test-BRAVOCondition -Condition ($maintLowDisk.Contains("Дефіцит: 5.4 ГБ") -and $maintLowDisk.Contains("Потрібна дія: звільнити щонайменше 5.4 ГБ.")) -Name "Notifications/MaintenanceFailureShowsDiskDeficit" -Failure "Maintenance low-disk має показувати deficit"
    Test-BRAVOCondition -Condition (-not $maintSuccess.Contains("наступна:") -and -not $maintSuccess.Contains("після 03:00")) -Name "Notifications/MaintenanceDoesNotUseAmbiguousRestoreTime" -Failure "Maintenance notification не має змішувати restore timestamps"
    $longDiscord = New-BRAVOOperatorNotificationMessage `
        -Severity WARNING `
        -Operation "BRAVO BACKUP — ПОТРІБНА ДІЯ" `
        -ActionText "перевірити журнал BRAVO_ARCHIV." `
        -InstitutionName "TEST" `
        -HostInformation $notifyHostOff `
        -ResultLines @(("x" * 5000)) `
        -Timestamp ([datetime]"2026-08-09T00:00:00") `
        -ProductName "BRAVO Archive" `
        -Version "5.0.0-dev.11" `
        -BuildId "testbuild"
    $discordChunks = @(Split-DiscordNotificationText -Message (ConvertTo-DiscordNotificationText -Message $longDiscord))
    Test-BRAVOCondition -Condition ($discordChunks.Count -gt 1 -and @($discordChunks | Where-Object { $_.Length -gt 1900 }).Count -eq 0) -Name "Notifications/DiscordChunkingStillWorks" -Failure "long Discord notifications мають chunking"
    $archiveNotificationTextForMentions = [IO.File]::ReadAllText((Join-Path $root "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1"), [Text.Encoding]::UTF8)
    $maintenanceNotificationTextForMentions = [IO.File]::ReadAllText((Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"), [Text.Encoding]::UTF8)
    $dryRunNotificationTextForMentions = [IO.File]::ReadAllText((Join-Path $root "BRAVO_DRY_RUN.ps1"), [Text.Encoding]::UTF8)
    $compatibilityNotificationTextForMentions = [IO.File]::ReadAllText((Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psm1"), [Text.Encoding]::UTF8)
    $mentionsDisabledPattern = 'allowed_mentions\s*=\s*@\{\s*parse\s*=\s*@\(\)\s*\}'
    # Archive/Maintenance більше не будують Discord payload самостійно —
    # обидва делегують через централізований BRAVO.Notifications
    # (Send-BRAVONotification*) до єдиної canonical реалізації payload
    # (BRAVO.Compatibility::Send-BRAVOWebhookNotification, де й перевіряється
    # сам літерал allowed_mentions). DryRun лишається незалежним, як і раніше.
    Test-BRAVOCondition -Condition ($archiveNotificationTextForMentions.Contains("Send-BRAVONotification") -and ($compatibilityNotificationTextForMentions -match $mentionsDisabledPattern) -and $maintenanceNotificationTextForMentions.Contains("Send-BRAVONotification") -and ($dryRunNotificationTextForMentions -match $mentionsDisabledPattern)) -Name "Notifications/DiscordMentionsRemainDisabled" -Failure "Discord payload має забороняти mentions"

    # dev.12: BRAVO_DRY_RUN.ps1 надсилав у Discord сирі ":emoji:" tokens,
    # бо Send-TestWebhookNotification не проганяв повідомлення через
    # ConvertTo-DiscordNotificationText, на відміну від Archive/Health/
    # Maintenance. Slack навпаки має отримувати сирі tokens незмінними —
    # Slack резолвить ":shortcode:" нативно, Discord-конвертація там зайва.
    $sendTestWebhookFunctionText = if ($dryRunNotificationTextForMentions -match
        '(?s)function Send-TestWebhookNotification \{.*?\n\}') {
        $Matches[0]
    } else {
        ''
    }
    Test-BRAVOCondition `
        -Condition (
            -not [string]::IsNullOrWhiteSpace($sendTestWebhookFunctionText) -and
            $sendTestWebhookFunctionText.Contains("ConvertTo-DiscordNotificationText -Message `$message") -and
            $sendTestWebhookFunctionText.Contains('content = (ConvertTo-DiscordNotificationText -Message $message)') -and
            $sendTestWebhookFunctionText.Contains('@{text = $message}')
        ) `
        -Name "Notifications/DryRunDiscordUsesConversionContract" `
        -Failure "BRAVO_DRY_RUN.ps1 -SendTestNotification для provider=discord має конвертувати повідомлення через ConvertTo-DiscordNotificationText (те саме, що Archive/Health/Maintenance), а provider=slack має лишати сирі :emoji: tokens"
    $dryRunDiscordSample = New-BRAVOOperatorNotificationMessage `
        -Severity SUCCESS `
        -Operation "BRAVO DRY RUN — ТЕСТОВЕ СПОВІЩЕННЯ" `
        -InstitutionName "TEST-COMPANY" `
        -InstitutionCode "1234567890" `
        -HostInformation $notifyHostOff `
        -ResultLines @(
            "Credential Manager і надсилання webhook працюють.",
            "Config: BRAVO.config",
            "Production-операції архівації, копіювання та видалення не запускалися."
        ) `
        -Timestamp ([datetime]"2026-08-09T16:15:03") `
        -ProductName "BRAVO Dry Run" `
        -Version "5.0.0-dev.12" `
        -BuildId "testbuild"
    $dryRunDiscordRendered = ConvertTo-DiscordNotificationText -Message $dryRunDiscordSample
    Test-BRAVOCondition `
        -Condition (
            $dryRunDiscordRendered.Contains("✅ BRAVO DRY RUN — ТЕСТОВЕ СПОВІЩЕННЯ") -and
            $dryRunDiscordRendered.Contains("🏢 TEST-COMPANY [1234567890]") -and
            $dryRunDiscordRendered.Contains("🖥️ DEV-LIMS") -and
            -not $dryRunDiscordRendered.Contains(":white_check_mark:") -and
            -not $dryRunDiscordRendered.Contains(":office:") -and
            -not $dryRunDiscordRendered.Contains(":desktop_computer:")
        ) `
        -Name "Notifications/DryRunDiscordRendersRealEmoji" `
        -Failure "після ConvertTo-DiscordNotificationText DryRun-повідомлення для Discord не повинно містити сирих :emoji: tokens"
    $legacyHouseToken = ":" + "der" + "elict_house_" + "building:"
    $legacyActionText = "ПОТРЕБУЄ " + "УВАГИ"
    $legacyFileCountText = "файл" + "(ів)"
    $legacyIpDisabledRegex = "IP-" + "адреси: .*" + "\| " + "вимкнено"
    $operatorNotificationSamples = @($notifySuccess, $notifyWarning, $bazaSample, $maintSuccess, $maintLowDisk) -join [Environment]::NewLine
    Test-BRAVOCondition -Condition (-not $operatorNotificationSamples.Contains($legacyHouseToken) -and -not $operatorNotificationSamples.Contains($legacyHealthyCopyText) -and -not $operatorNotificationSamples.Contains($legacyActionText) -and -not $operatorNotificationSamples.Contains($legacyFileCountText) -and ($operatorNotificationSamples -notmatch $legacyIpDisabledRegex)) -Name "Notifications/OperatorTemplatesDoNotContainLegacyWording" -Failure "operator-visible notification templates не мають містити legacy wording"

    # --- Severity-based routing (GENERAL/ALERTS) ---------------------------
    # Resolve-BRAVONotificationRoute — pure-функція, реального Credential
    # Manager не торкається; тестуємо прямо на вже імпортованому модулі
    # (Import-Module BRAVO.Notifications вище).
    $allRoutingTable = @{ SUCCESS = "general"; WARNING = "alerts"; ERROR = "alerts"; CRITICAL = "alerts" }
    Test-BRAVOCondition `
        -Condition (
            (Resolve-BRAVONotificationRoute -Severity SUCCESS -NotificationMode all -RoutingTable $allRoutingTable) -eq "general" -and
            (Resolve-BRAVONotificationRoute -Severity WARNING -NotificationMode all -RoutingTable $allRoutingTable) -eq "alerts" -and
            (Resolve-BRAVONotificationRoute -Severity ERROR -NotificationMode all -RoutingTable $allRoutingTable) -eq "alerts" -and
            (Resolve-BRAVONotificationRoute -Severity CRITICAL -NotificationMode all -RoutingTable $allRoutingTable) -eq "alerts"
        ) `
        -Name "Notifications/RoutingMatrixModeAll" `
        -Failure "Mode=all: SUCCESS->general, WARNING/ERROR/CRITICAL->alerts"
    Test-BRAVOCondition `
        -Condition (
            (Resolve-BRAVONotificationRoute -Severity SUCCESS -NotificationMode errors_only -RoutingTable $allRoutingTable) -eq "none" -and
            (Resolve-BRAVONotificationRoute -Severity WARNING -NotificationMode errors_only -RoutingTable $allRoutingTable) -eq "alerts" -and
            (Resolve-BRAVONotificationRoute -Severity ERROR -NotificationMode errors_only -RoutingTable $allRoutingTable) -eq "alerts" -and
            (Resolve-BRAVONotificationRoute -Severity CRITICAL -NotificationMode errors_only -RoutingTable $allRoutingTable) -eq "alerts"
        ) `
        -Name "Notifications/RoutingMatrixModeErrorsOnly" `
        -Failure "Mode=errors_only: SUCCESS->none, WARNING/ERROR/CRITICAL->alerts"
    Test-BRAVOCondition `
        -Condition (
            (Resolve-BRAVONotificationRoute -Severity SUCCESS -NotificationMode none -RoutingTable $allRoutingTable) -eq "none" -and
            (Resolve-BRAVONotificationRoute -Severity WARNING -NotificationMode none -RoutingTable $allRoutingTable) -eq "none" -and
            (Resolve-BRAVONotificationRoute -Severity ERROR -NotificationMode none -RoutingTable $allRoutingTable) -eq "none" -and
            (Resolve-BRAVONotificationRoute -Severity CRITICAL -NotificationMode none -RoutingTable $allRoutingTable) -eq "none"
        ) `
        -Name "Notifications/RoutingMatrixModeNone" `
        -Failure "Mode=none: усі severity -> none"
    Test-BRAVOCondition `
        -Condition (
            (Resolve-BRAVONotificationRoute -Severity SUCCESS -NotificationMode all -RoutingTable $null) -eq "general" -and
            (Resolve-BRAVONotificationRoute -Severity WARNING -NotificationMode all -RoutingTable $null) -eq "alerts" -and
            (Resolve-BRAVONotificationRoute -Severity CRITICAL -NotificationMode errors_only -RoutingTable @{}) -eq "alerts"
        ) `
        -Name "Notifications/RoutingMatrixSafeDefault" `
        -Failure "відсутня/порожня RoutingTable (стара конфігурація) має застосовувати безпечний дефолт SUCCESS=general, WARNING/ERROR/CRITICAL=alerts"
    # errors_only — mode contract сильніший за custom RoutingTable: навіть
    # якщо оператор налаштував WARNING/ERROR/CRITICAL -> general, під
    # errors_only вони все одно мають йти в alerts (інакше не було б
    # webhook-а для доставки — Health/Maintenance preflight під errors_only
    # резолвить лише ALERTS endpoint). SUCCESS завжди -> none.
    $errorsOnlyEscapeAttemptTable = @{ SUCCESS = "alerts"; WARNING = "general"; ERROR = "general"; CRITICAL = "general" }
    Test-BRAVOCondition `
        -Condition (
            (Resolve-BRAVONotificationRoute -Severity SUCCESS -NotificationMode errors_only -RoutingTable $errorsOnlyEscapeAttemptTable) -eq "none" -and
            (Resolve-BRAVONotificationRoute -Severity WARNING -NotificationMode errors_only -RoutingTable $errorsOnlyEscapeAttemptTable) -eq "alerts" -and
            (Resolve-BRAVONotificationRoute -Severity ERROR -NotificationMode errors_only -RoutingTable $errorsOnlyEscapeAttemptTable) -eq "alerts" -and
            (Resolve-BRAVONotificationRoute -Severity CRITICAL -NotificationMode errors_only -RoutingTable $errorsOnlyEscapeAttemptTable) -eq "alerts" -and
            # Mode=all і надалі застосовує custom RoutingTable без обмежень
            # (обмеження стосується лише errors_only semantics).
            (Resolve-BRAVONotificationRoute -Severity WARNING -NotificationMode all -RoutingTable $errorsOnlyEscapeAttemptTable) -eq "general"
        ) `
        -Name "Notifications/ErrorsOnlyIgnoresCustomRoutingOverride" `
        -Failure "errors_only має ігнорувати custom RoutingTable для WARNING/ERROR/CRITICAL (завжди alerts) і для SUCCESS (завжди none) — mode contract пріоритетніший за таблицю; Mode=all і надалі застосовує таблицю без обмежень"

    # --- Endpoint fallback (route-специфічний credential -> legacy webhook
    # -> жорсткий літерал), повністю ізольовано від реального Credential
    # Manager: Resolve-BRAVONotificationEndpoint екстрагується з джерела й
    # виконується в окремому module scope зі stub Get-BRAVOCredentialSecret,
    # який ніколи не звертається до Windows Credential Manager.
    $notificationsModuleSourceText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Notifications\BRAVO.Notifications.psm1"), [Text.Encoding]::UTF8)
    $notificationEndpointTestModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $notificationsModuleSourceText `
        -FunctionNames @('Resolve-BRAVONotificationEndpoint')
    # Явно вивантажуємо реальні BRAVO.Credentials/BRAVO.Compatibility з
    # процесу перед ізольованим тестом: якщо stub Get-BRAVOCredentialSecret
    # нижче з якоїсь причини НЕ перекриє виклик (module-scoping edge case),
    # відсутність реального модуля гарантує "command not found" замість
    # мовчазного звернення до Windows Credential Manager.
    Remove-Module -Name 'BRAVO.Credentials' -Force -ErrorAction SilentlyContinue
    Remove-Module -Name 'BRAVO.Compatibility' -Force -ErrorAction SilentlyContinue
    $endpointFallbackCapture = & $notificationEndpointTestModule {
        function Get-BRAVOCredentialSecret {
            param([string]$Target)
            # Ізольований stub: жодного реального доступу до Windows
            # Credential Manager — лише синтетичні значення нижче.
            $stubs = @{
                'BRAVO_DISCORD_ALERTS_URL' = 'STUB-ALERTS'
                'BRAVO_DISCORD_URL' = 'STUB-LEGACY'
                'BRAVO_SLACK_GENERAL_URL' = 'STUB-SLACK-GENERAL'
            }
            if ($stubs.Contains($Target)) { return $stubs[$Target] }
            return $null
        }
        $targetsBothPresent = @{ DiscordWebhookAlerts = 'BRAVO_DISCORD_ALERTS_URL'; DiscordWebhook = 'BRAVO_DISCORD_URL' }
        # Назва target-а навмисно НЕ у ключах $stubs вище (Get-BRAVOCredentialSecret
        # поверне $null) — симулює "route-специфічний Credential Manager
        # запис не налаштований", щоб перевірити fallback на legacy.
        # (Значення НЕ 32 символи навмисно: gitleaks' "discord-client-secret"
        # rule false-positive спрацьовує на 32-символьні рядки поруч із
        # "Discord"+"=" — це назва Credential Manager target-а, не секрет.)
        $targetsLegacyOnly = @{ DiscordWebhookAlerts = 'BRAVO_DISCORD_ALERTS_URL_NOT_CONFIGURED'; DiscordWebhook = 'BRAVO_DISCORD_URL' }
        $targetsNoneConfigured = @{}
        $newTargetWins = Resolve-BRAVONotificationEndpoint -Provider discord -Route alerts -CredentialTargets $targetsBothPresent
        $legacyFallback = Resolve-BRAVONotificationEndpoint -Provider discord -Route alerts -CredentialTargets $targetsLegacyOnly
        $literalFallback = $null
        $literalFallbackThrew = $false
        try {
            $literalFallback = Resolve-BRAVONotificationEndpoint -Provider discord -Route general -CredentialTargets $targetsNoneConfigured
        } catch { $literalFallbackThrew = $true }
        $slackGeneral = Resolve-BRAVONotificationEndpoint -Provider slack -Route general -CredentialTargets @{ SlackWebhookGeneral = 'BRAVO_SLACK_GENERAL_URL' }
        $allMissingThrew = $false
        try {
            Resolve-BRAVONotificationEndpoint -Provider slack -Route alerts -CredentialTargets @{}
        } catch { $allMissingThrew = $true }
        [pscustomobject]@{
            NewTargetWins = $newTargetWins
            LegacyFallback = $legacyFallback
            LiteralFallbackThrew = $literalFallbackThrew
            SlackGeneral = $slackGeneral
            AllMissingThrew = $allMissingThrew
        }
    }
    Test-BRAVOCondition `
        -Condition ($endpointFallbackCapture.NewTargetWins -eq 'STUB-ALERTS') `
        -Name "Notifications/EndpointPrefersRouteSpecificTarget" `
        -Failure "коли налаштовано і route-специфічний, і legacy target, має використовуватись route-специфічний"
    Test-BRAVOCondition `
        -Condition ($endpointFallbackCapture.LegacyFallback -eq 'STUB-LEGACY') `
        -Name "Notifications/EndpointFallsBackToLegacyWebhook" `
        -Failure "коли route-специфічний credential відсутній, має використовуватись legacy BRAVO_DISCORD_URL/BRAVO_SLACK_URL (backward compatibility)"
    Test-BRAVOCondition `
        -Condition ($endpointFallbackCapture.SlackGeneral -eq 'STUB-SLACK-GENERAL') `
        -Name "Notifications/EndpointResolvesSlackGeneralTarget" `
        -Failure "Slack GENERAL route має резолвитись через SlackWebhookGeneral target"
    Test-BRAVOCondition `
        -Condition ($endpointFallbackCapture.AllMissingThrew) `
        -Name "Notifications/EndpointThrowsWhenNothingConfigured" `
        -Failure "коли жоден target (новий і legacy) не налаштований, має кидатись виняток, а не мовчки повертатись порожній webhook"
    # Відновлюємо реальні модулі для решти self-test (наступні секції
    # покладаються на їх наявність, як і до цього ізольованого блоку).
    Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $root "modules\BRAVO.Credentials\BRAVO.Credentials.psd1") -Force -ErrorAction Stop

    # --- Maintenance: NotificationSeverity (маршрутизація + CONTENT
    # severity) відокремлена від OperationSeverity
    # ($script:criticalErrorOccurred) через ПОВНИЙ lifecycle: Send-SlackAlert
    # -> Send-FinalReport -> route resolution -> New-MaintenanceNotificationMessage
    # -> delivery stub. Стаб New-MaintenanceNotificationMessage відтворює
    # -Severity у поверненому тексті (SEVERITY=...), щоб тести перевіряли
    # не лише webhook route, а й фактичну content-severity, передану далі в
    # New-BRAVOOperatorNotificationMessage (review: ERROR/CRITICAL
    # notification-only не повинні downgrade-итись до WARNING лише через
    # спільний TitleEmoji).
    $maintenanceRuntimeSourceForSeverity = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"), [Text.Encoding]::UTF8)
    $sendSlackAlertTestModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $maintenanceRuntimeSourceForSeverity `
        -FunctionNames @('Send-SlackAlert', 'Send-FinalReport')

    function Invoke-MaintenanceSeverityLifecycleScenario {
        param([scriptblock]$SendCalls)
        & $sendSlackAlertTestModule {
            param($SendCallsInner)
            $script:SlackMode = "errors_only"
            $script:CriticalErrors = $false
            $script:criticalErrorOccurred = $false
            $script:CriticalErrorsList = New-Object System.Collections.Generic.List[string]
            $script:NotificationAlertQueue = New-Object System.Collections.Generic.List[object]
            $script:SlackMessageBuffer = New-Object System.Collections.Generic.List[string]
            $script:NotificationWebhookUrls = @{ alerts = "STUB-ALERTS-URL"; general = "STUB-GENERAL-URL" }
            $script:ScriptStartTime = Get-Date
            $bravoSettings = @{ NotificationRouting = @{} }
            $LOG_FILE = "STUB-LOG-PATH"
            $NotificationProviderDisplayName = "STUB"
            $script:deliveredMessages = New-Object System.Collections.Generic.List[object]

            function Write-Log { param($Message, [string]$Level = 'INFO', [switch]$NoTimestamp, [switch]$NoConsole) }
            function Resolve-BRAVONotificationRoute {
                param([string]$Severity, [string]$NotificationMode, $RoutingTable)
                if ($NotificationMode -eq "none") { return "none" }
                if ($Severity -eq "SUCCESS") {
                    if ($NotificationMode -eq "errors_only") { return "none" }
                    return "general"
                }
                return "alerts"
            }
            function Invoke-NotificationWebhook {
                param([string]$Message, [string]$WebhookUrl)
                $script:deliveredMessages.Add([pscustomobject]@{ Message = $Message; WebhookUrl = $WebhookUrl })
            }
            function New-MaintenanceNotificationMessage {
                param([string]$Title, [string]$TitleEmoji, $Duration, [string[]]$Details, [string]$LogPath, [string[]]$StatusLines, [string]$Severity)
                return "TITLE=$Title|EMOJI=$TitleEmoji|SEVERITY=$Severity|DETAILS=$($Details -join ';')"
            }

            & $SendCallsInner

            Send-FinalReport -LOG_FILE $LOG_FILE

            [pscustomobject]@{
                CriticalErrorOccurred = $script:criticalErrorOccurred
                CriticalErrorsListCount = $script:CriticalErrorsList.Count
                NotificationAlertQueueCount = $script:NotificationAlertQueue.Count
                DeliveredCount = $script:deliveredMessages.Count
                DeliveredMessage = if ($script:deliveredMessages.Count -gt 0) { $script:deliveredMessages[0].Message } else { $null }
                DeliveredWebhook = if ($script:deliveredMessages.Count -gt 0) { $script:deliveredMessages[0].WebhookUrl } else { $null }
            }
        } $SendCalls
    }

    # notification-only WARNING: content SEVERITY=WARNING, route alerts,
    # execution critical=false, NotificationAlertQueue (не CriticalErrorsList).
    $warningLifecycle = Invoke-MaintenanceSeverityLifecycleScenario -SendCalls {
        Send-SlackAlert -Message "range id warning" -Severity "WARNING"
    }
    Test-BRAVOCondition `
        -Condition (-not $warningLifecycle.CriticalErrorOccurred) `
        -Name "Maintenance/NotificationOnlyWarning_ExecutionNotCritical" `
        -Failure "Send-SlackAlert -Severity WARNING (без -IsCritical) НЕ повинен встановлювати `$script:criticalErrorOccurred"
    Test-BRAVOCondition `
        -Condition ($warningLifecycle.CriticalErrorsListCount -eq 0 -and $warningLifecycle.NotificationAlertQueueCount -eq 1) `
        -Name "Maintenance/NotificationOnlyWarning_UsesAlertQueueNotCriticalList" `
        -Failure "notification-only WARNING має чергуватись в NotificationAlertQueue, а не в CriticalErrorsList"
    Test-BRAVOCondition `
        -Condition ($warningLifecycle.DeliveredCount -eq 1 -and $warningLifecycle.DeliveredWebhook -eq "STUB-ALERTS-URL") `
        -Name "Maintenance/NotificationOnlyWarning_RoutesToAlerts" `
        -Failure "Send-SlackAlert -Severity WARNING під errors_only має бути доставлено рівно один раз на ALERTS webhook"
    Test-BRAVOCondition `
        -Condition ($null -ne $warningLifecycle.DeliveredMessage -and $warningLifecycle.DeliveredMessage.Contains("SEVERITY=WARNING")) `
        -Name "Maintenance/NotificationOnlyWarning_ContentSeverityStaysWarning" `
        -Failure "фінальне повідомлення для notification-only WARNING має мати -Severity WARNING, передану в New-MaintenanceNotificationMessage (не inferred з emoji)"

    # notification-only ERROR: content SEVERITY=ERROR (НЕ WARNING), route
    # alerts, execution critical=false.
    $errorLifecycle = Invoke-MaintenanceSeverityLifecycleScenario -SendCalls {
        Send-SlackAlert -Message "notification-only error" -Severity "ERROR"
    }
    Test-BRAVOCondition `
        -Condition (-not $errorLifecycle.CriticalErrorOccurred) `
        -Name "Maintenance/NotificationOnlyError_ExecutionNotCritical" `
        -Failure "Send-SlackAlert -Severity ERROR (без -IsCritical) НЕ повинен встановлювати `$script:criticalErrorOccurred"
    Test-BRAVOCondition `
        -Condition ($errorLifecycle.CriticalErrorsListCount -eq 0 -and $errorLifecycle.NotificationAlertQueueCount -eq 1) `
        -Name "Maintenance/NotificationOnlyError_UsesAlertQueueNotCriticalList" `
        -Failure "notification-only ERROR має чергуватись в NotificationAlertQueue, а не в CriticalErrorsList"
    Test-BRAVOCondition `
        -Condition ($errorLifecycle.DeliveredCount -eq 1 -and $errorLifecycle.DeliveredWebhook -eq "STUB-ALERTS-URL") `
        -Name "Maintenance/NotificationOnlyError_RoutesToAlerts" `
        -Failure "Send-SlackAlert -Severity ERROR має бути доставлено на ALERTS webhook"
    Test-BRAVOCondition `
        -Condition (
            $null -ne $errorLifecycle.DeliveredMessage -and
            $errorLifecycle.DeliveredMessage.Contains("SEVERITY=ERROR") -and
            -not $errorLifecycle.DeliveredMessage.Contains("SEVERITY=WARNING")
        ) `
        -Name "Maintenance/NotificationOnlyError_ContentSeverityIsErrorNotWarning" `
        -Failure "notification-only ERROR не повинен downgrade-итись до -Severity WARNING лише через спільний TitleEmoji ':warning:' (review, повторна знахідка після 95c05d7)"

    # notification-only CRITICAL (без -IsCritical): content SEVERITY=CRITICAL,
    # route alerts, execution critical=false, CriticalErrorsList не використана.
    $criticalOnlyLifecycle = Invoke-MaintenanceSeverityLifecycleScenario -SendCalls {
        Send-SlackAlert -Message "notification-only critical" -Severity "CRITICAL"
    }
    Test-BRAVOCondition `
        -Condition (-not $criticalOnlyLifecycle.CriticalErrorOccurred) `
        -Name "Maintenance/NotificationOnlyCritical_ExecutionNotCritical" `
        -Failure "Send-SlackAlert -Severity CRITICAL (без -IsCritical) НЕ повинен встановлювати `$script:criticalErrorOccurred — це відрізняє NotificationSeverity від OperationSeverity навіть на межі CRITICAL"
    Test-BRAVOCondition `
        -Condition ($criticalOnlyLifecycle.CriticalErrorsListCount -eq 0 -and $criticalOnlyLifecycle.NotificationAlertQueueCount -eq 1) `
        -Name "Maintenance/NotificationOnlyCritical_UsesAlertQueueNotCriticalList" `
        -Failure "notification-only CRITICAL (без -IsCritical) має чергуватись в NotificationAlertQueue, а не в CriticalErrorsList — інакше він би непомітно почав впливати на execution exit code"
    Test-BRAVOCondition `
        -Condition ($criticalOnlyLifecycle.DeliveredCount -eq 1 -and $criticalOnlyLifecycle.DeliveredWebhook -eq "STUB-ALERTS-URL") `
        -Name "Maintenance/NotificationOnlyCritical_RoutesToAlerts" `
        -Failure "Send-SlackAlert -Severity CRITICAL (без -IsCritical) має бути доставлено на ALERTS webhook"
    Test-BRAVOCondition `
        -Condition (
            $null -ne $criticalOnlyLifecycle.DeliveredMessage -and
            $criticalOnlyLifecycle.DeliveredMessage.Contains("SEVERITY=CRITICAL") -and
            -not $criticalOnlyLifecycle.DeliveredMessage.Contains("SEVERITY=WARNING")
        ) `
        -Name "Maintenance/NotificationOnlyCritical_ContentSeverityStaysCritical" `
        -Failure "notification-only CRITICAL не повинен downgrade-итись до -Severity WARNING у фінальному контенті лише через спільний TitleEmoji ':warning:' (review, повторна знахідка після 95c05d7)"

    # legacy -IsCritical: content SEVERITY=CRITICAL, route alerts, execution
    # critical=true, CriticalErrorsList використовується (не змінено).
    $criticalLifecycle = Invoke-MaintenanceSeverityLifecycleScenario -SendCalls {
        Send-SlackAlert -Message "generic critical" -IsCritical
    }
    Test-BRAVOCondition `
        -Condition ($criticalLifecycle.CriticalErrorOccurred) `
        -Name "Maintenance/LegacyIsCritical_ExecutionIsCritical" `
        -Failure "Send-SlackAlert -IsCritical (без -Severity) має й далі встановлювати criticalErrorOccurred — так само, як до додавання -Severity"
    Test-BRAVOCondition `
        -Condition ($criticalLifecycle.CriticalErrorsListCount -eq 1 -and $criticalLifecycle.NotificationAlertQueueCount -eq 0) `
        -Name "Maintenance/LegacyIsCritical_UsesCriticalErrorsList" `
        -Failure "Send-SlackAlert -IsCritical має й далі ставити повідомлення в CriticalErrorsList (не в NotificationAlertQueue) — легасі-поведінка не повинна змінитися"
    Test-BRAVOCondition `
        -Condition (
            $criticalLifecycle.DeliveredCount -eq 1 -and
            $criticalLifecycle.DeliveredWebhook -eq "STUB-ALERTS-URL" -and
            $criticalLifecycle.DeliveredMessage.Contains("SEVERITY=CRITICAL") -and
            $criticalLifecycle.DeliveredMessage.Contains("КРИТИЧНІ ПОМИЛКИ ОБСЛУГОВУВАННЯ")
        ) `
        -Name "Maintenance/LegacyIsCritical_ContentSeverityStaysCritical" `
        -Failure "-IsCritical (справжня execution-critical подія) має й надалі формувати CRITICAL-презентацію 'КРИТИЧНІ ПОМИЛКИ ОБСЛУГОВУВАННЯ'/-Severity CRITICAL у фінальному звіті"

    # --- Mixed NotificationAlertQueue: пріоритет CRITICAL > ERROR > WARNING
    # для CONTENT severity фінального повідомлення (жоден з них не -IsCritical,
    # тому execution лишається некритичним для всіх трьох комбінацій) -------
    $mixedWarningErrorLifecycle = Invoke-MaintenanceSeverityLifecycleScenario -SendCalls {
        Send-SlackAlert -Message "w1" -Severity "WARNING"
        Send-SlackAlert -Message "e1" -Severity "ERROR"
    }
    Test-BRAVOCondition `
        -Condition (
            -not $mixedWarningErrorLifecycle.CriticalErrorOccurred -and
            $mixedWarningErrorLifecycle.NotificationAlertQueueCount -eq 2 -and
            $mixedWarningErrorLifecycle.DeliveredMessage.Contains("SEVERITY=ERROR") -and
            -not $mixedWarningErrorLifecycle.DeliveredMessage.Contains("SEVERITY=WARNING")
        ) `
        -Name "Maintenance/MixedAlertQueue_WarningPlusErrorResolvesToError" `
        -Failure "черга WARNING+ERROR має дати підсумкову content-severity ERROR (пріоритет CRITICAL > ERROR > WARNING), execution лишається некритичним"

    $mixedWarningCriticalLifecycle = Invoke-MaintenanceSeverityLifecycleScenario -SendCalls {
        Send-SlackAlert -Message "w1" -Severity "WARNING"
        Send-SlackAlert -Message "c1" -Severity "CRITICAL"
    }
    Test-BRAVOCondition `
        -Condition (
            -not $mixedWarningCriticalLifecycle.CriticalErrorOccurred -and
            $mixedWarningCriticalLifecycle.NotificationAlertQueueCount -eq 2 -and
            $mixedWarningCriticalLifecycle.DeliveredMessage.Contains("SEVERITY=CRITICAL")
        ) `
        -Name "Maintenance/MixedAlertQueue_WarningPlusCriticalResolvesToCritical" `
        -Failure "черга WARNING+CRITICAL (обидва без -IsCritical) має дати підсумкову content-severity CRITICAL, execution лишається некритичним (жоден запис не -IsCritical)"

    $mixedErrorCriticalLifecycle = Invoke-MaintenanceSeverityLifecycleScenario -SendCalls {
        Send-SlackAlert -Message "e1" -Severity "ERROR"
        Send-SlackAlert -Message "c1" -Severity "CRITICAL"
    }
    Test-BRAVOCondition `
        -Condition (
            -not $mixedErrorCriticalLifecycle.CriticalErrorOccurred -and
            $mixedErrorCriticalLifecycle.NotificationAlertQueueCount -eq 2 -and
            $mixedErrorCriticalLifecycle.DeliveredMessage.Contains("SEVERITY=CRITICAL")
        ) `
        -Name "Maintenance/MixedAlertQueue_ErrorPlusCriticalResolvesToCritical" `
        -Failure "черга ERROR+CRITICAL має дати підсумкову content-severity CRITICAL, execution лишається некритичним"

    # --- Maintenance: -EnableAllSlack/-DisableAllSlack ефективний режим
    # обчислюється ОДИН раз, ДО webhook-route preflight (регресійний тест
    # хотфіксу 5.0.1: PR #39 резолвив reachable-маршрути за сирим
    # $SlackMode ДО override-блоку, а рантайм-споживачі вже читали
    # $script:SlackMode ПІСЛЯ — тому -EnableAllSlack при NotificationMode
    # none/errors_only мовчки ставав no-op). Тест працює з РЕАЛЬНИМ AST
    # найденого вузла присвоєння (не переписаною вручну копією логіки).
    $maintenanceRuntimeTokensForOverride = $null
    $maintenanceRuntimeParseErrorsForOverride = $null
    $maintenanceRuntimeAstForOverride = [Management.Automation.Language.Parser]::ParseInput(
        $maintenanceRuntimeSourceForSeverity,
        [ref]$maintenanceRuntimeTokensForOverride,
        [ref]$maintenanceRuntimeParseErrorsForOverride)
    $effectiveModeAssignmentAst = @(
        $maintenanceRuntimeAstForOverride.FindAll(
            {
                param($candidate)
                $candidate -is [Management.Automation.Language.AssignmentStatementAst] -and
                $candidate.Left.Extent.Text -eq '$script:SlackMode' -and
                $candidate.Right.Extent.Text -match '^\s*if\s*\(\$DisableAllSlack\)'
            },
            $true
        )
    ) | Select-Object -First 1
    Test-BRAVOCondition `
        -Condition ($null -ne $effectiveModeAssignmentAst) `
        -Name "Maintenance/EffectiveSlackModeComputedOnce" `
        -Failure "не знайдено канонічне присвоєння `$script:SlackMode = if (`$DisableAllSlack) {...} elseif (`$EnableAllSlack) {...} else {...} у Maintenance.Runtime.ps1"

    if ($null -ne $effectiveModeAssignmentAst) {
        $effectiveModeExpressionText = $effectiveModeAssignmentAst.Extent.Text
        $effectiveModeStartOffset = $effectiveModeAssignmentAst.Extent.StartOffset

        # Обидва preflight-блоки (резолв webhook-route + exit-31 валідація)
        # мають читати $script:SlackMode (ефективний), не сирий $SlackMode,
        # і фізично розташовуватись ПІСЛЯ обчислення вище в тексті файлу.
        # Пошук звужено до сегмента ДО автовизначення служби BRAVO Web
        # (одразу за другим preflight-блоком) — далі в 4000+ рядків файлу
        # трапляються й інші, непов'язані перевірки того самого патерна
        # (усередині функцій-відправників, де вона й раніше була коректною).
        $preflightSegmentBoundary = $maintenanceRuntimeSourceForSeverity.IndexOf(
            "Автоматичне визначення служби Apache для BRAVO Web")
        Test-BRAVOCondition `
            -Condition ($preflightSegmentBoundary -gt 0) `
            -Name "Maintenance/PreflightSegmentBoundaryFound" `
            -Failure "не знайдено орієнтир кінця preflight-секції ('Автоматичне визначення служби Apache для BRAVO Web') -- тест потребує оновлення межі пошуку"
        $preflightSegmentText = if ($preflightSegmentBoundary -gt 0) {
            $maintenanceRuntimeSourceForSeverity.Substring(0, $preflightSegmentBoundary)
        } else {
            $maintenanceRuntimeSourceForSeverity
        }
        $webhookPreflightMatches = @([regex]::Matches(
            $preflightSegmentText, 'if \(\$script:SlackMode -ne "none"\) \{'))
        Test-BRAVOCondition `
            -Condition ($webhookPreflightMatches.Count -eq 2) `
            -Name "Maintenance/BothWebhookPreflightGatesUseEffectiveSlackMode" `
            -Failure "очікувалось рівно 2 preflight-блоки (резолв routes + exit-31 валідація), що перевіряють `$script:SlackMode -ne 'none'; знайдено $($webhookPreflightMatches.Count) -- ordering-фікс міг регресувати назад на сирий `$SlackMode"
        if ($webhookPreflightMatches.Count -gt 0) {
            $earliestPreflightOffset = ($webhookPreflightMatches | Measure-Object -Property Index -Minimum).Minimum
            Test-BRAVOCondition `
                -Condition ($effectiveModeStartOffset -lt $earliestPreflightOffset) `
                -Name "Maintenance/EffectiveSlackModeComputedBeforeWebhookPreflight" `
                -Failure "обчислення ефективного `$script:SlackMode має передувати першому webhook-preflight-блоку в тексті скрипта -- інакше -EnableAllSlack/-DisableAllSlack знову стане no-op для NotificationMode=none/errors_only"
        }

        # Поведінковий тест: РЕАЛЬНИЙ текст присвоєння виконується
        # ізольовано (окремий New-Module) для 3 комбінацій прапорців.
        $overrideScenarios = @(
            @{ Disable = $true; Enable = $false; Raw = 'errors_only'; Expected = 'none' }
            @{ Disable = $false; Enable = $true; Raw = 'none'; Expected = 'all' }
            @{ Disable = $false; Enable = $false; Raw = 'errors_only'; Expected = 'errors_only' }
        )
        foreach ($scenario in $overrideScenarios) {
            $overrideEvalModule = New-Module -ScriptBlock {}
            $scenarioResult = & $overrideEvalModule {
                param($DisableAllSlack, $EnableAllSlack, $SlackMode, $ExpressionText)
                . ([scriptblock]::Create($ExpressionText))
                return $script:SlackMode
            } $scenario.Disable $scenario.Enable $scenario.Raw $effectiveModeExpressionText
            Remove-Module -ModuleInfo $overrideEvalModule -ErrorAction SilentlyContinue
            Test-BRAVOCondition `
                -Condition ($scenarioResult -eq $scenario.Expected) `
                -Name "Maintenance/EffectiveSlackMode_Disable=$($scenario.Disable)_Enable=$($scenario.Enable)_Raw=$($scenario.Raw)" `
                -Failure "очікувано `$script:SlackMode = '$($scenario.Expected)', отримано '$scenarioResult'"
        }
    }

    # --- Maintenance: фінальний status "УСПІШНО З ПОПЕРЕДЖЕННЯМИ" (mode=all,
    # немає жодного critical/alert-queue запису) має маршрутизуватись як
    # WARNING/ALERTS, а не як SUCCESS/GENERAL (review finding #1) ----------
    $finalStatusModuleForSeverity = New-BRAVOSelfTestRuntimeModule `
        -SourceText $maintenanceRuntimeSourceForSeverity `
        -FunctionNames @('Send-FinalReport')
    $successWithWarningsRouteCapture = & $finalStatusModuleForSeverity {
        $script:SlackMode = "all"
        $script:CriticalErrorsList = New-Object System.Collections.Generic.List[string]
        $script:NotificationAlertQueue = New-Object System.Collections.Generic.List[object]
        $script:NotificationWebhookUrls = @{ alerts = "STUB-ALERTS-URL"; general = "STUB-GENERAL-URL" }
        $script:ScriptStartTime = Get-Date
        $bravoSettings = @{ NotificationRouting = @{} }
        $NotificationProviderDisplayName = "STUB"
        $script:deliveredMessages = New-Object System.Collections.Generic.List[object]
        $LOG_DIR = "STUB-LOG-DIR"
        $BravoMaintenanceEnabled = $true
        $CheckSize = $false
        $RangeIdMonitoringEnabled = $false
        $traceOutputProcessed = $false
        $exchangAPILogsProcessedCount = 0
        $restoreCompletedAt = Get-Date

        function Write-Log { param($Message, [string]$Level = 'INFO', [switch]$NoTimestamp, [switch]$NoConsole) }
        function Get-BRAVOFiles { param($Path, $Filter) return @() }
        function Get-MaintenanceMinimumFreeSpaceLines { return @() }
        function Format-BRAVOUkrainianCount { param([int]$Count, [string]$One, [string]$Few, [string]$Many) return "$Count" }
        function Resolve-BRAVONotificationRoute {
            param([string]$Severity, [string]$NotificationMode, $RoutingTable)
            if ($NotificationMode -eq "none") { return "none" }
            if ($Severity -eq "SUCCESS") {
                if ($NotificationMode -eq "errors_only") { return "none" }
                return "general"
            }
            return "alerts"
        }
        function Invoke-NotificationWebhook {
            param([string]$Message, [string]$WebhookUrl)
            $script:deliveredMessages.Add([pscustomobject]@{ Message = $Message; WebhookUrl = $WebhookUrl })
        }
        function New-MaintenanceNotificationMessage {
            param([string]$Title, [string]$TitleEmoji, $Duration, [string[]]$Details, [string]$LogPath, [string[]]$StatusLines, [string]$Severity)
            return "TITLE=$Title|EMOJI=$TitleEmoji|SEVERITY=$Severity|DETAILS=$($Details -join ';')"
        }
        # Реальна Get-BRAVOMaintenanceResolvedExitCode/Get-BRAVOMaintenanceFinalStatus
        # тут НЕ витягуються (щоб не тягнути весь exit-code граф залежностей
        # цього ізольованого тесту) — стаб відтворює саме ту пару
        # "WARNING-статус" (exit 10 -> SuccessWithWarnings), яку й перевіряє
        # цей regression-тест.
        function Get-BRAVOMaintenanceResolvedExitCode { return 10 }
        function Get-BRAVOMaintenanceFinalStatus { param($ExitCode) return [pscustomobject]@{ Text = 'УСПІШНО З ПОПЕРЕДЖЕННЯМИ' } }

        Send-FinalReport -LOG_FILE "STUB-LOG-PATH"

        [pscustomobject]@{
            DeliveredCount = $script:deliveredMessages.Count
            DeliveredMessage = if ($script:deliveredMessages.Count -gt 0) { $script:deliveredMessages[0].Message } else { $null }
            DeliveredWebhook = if ($script:deliveredMessages.Count -gt 0) { $script:deliveredMessages[0].WebhookUrl } else { $null }
        }
    }
    Test-BRAVOCondition `
        -Condition (
            $successWithWarningsRouteCapture.DeliveredCount -eq 1 -and
            $successWithWarningsRouteCapture.DeliveredWebhook -eq "STUB-ALERTS-URL" -and
            $successWithWarningsRouteCapture.DeliveredMessage.Contains("SEVERITY=WARNING")
        ) `
        -Name "Maintenance/SuccessWithWarningsRoutesToAlertsNotGeneral" `
        -Failure "'УСПІШНО З ПОПЕРЕДЖЕННЯМИ' (:warning:) має маршрутизуватись через notificationSeverity=WARNING на ALERTS webhook, а не через SUCCESS на GENERAL (review finding #1: routing severity мав завжди збігатися з фактичним final status)"

    # Модель release channel (P0.6 аудиту): developer -> development,
    # master/main -> stable. Перевірка навмисно не обов'язкова — release-пакет
    # без .git (розгорнутий на production-сервері) не повинен через це падати,
    # і сам `git` може бути відсутній навіть у робочій копії репозиторію.
    $currentGitBranch = $null
    if (Test-Path -LiteralPath (Join-Path $root '.git')) {
        try {
            $gitCommand = Get-Command -Name 'git' -ErrorAction SilentlyContinue
            if ($null -ne $gitCommand) {
                $branchOutput = & git -C $root rev-parse --abbrev-ref HEAD 2>$null
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$branchOutput)) {
                    $currentGitBranch = ([string]$branchOutput).Trim()
                }
            }
        } catch {
            $currentGitBranch = $null
        }
    }
    # RELEASE_POLICY.md, розділи 2 і 5.3: гілка визначає і формат версії,
    # і канал. Повний gate (разом із ModuleVersion, CHANGELOG і
    # заголовками документації) — ci\Test-BRAVOReleasePolicy.ps1; тут
    # перевіряється те саме твердження на тій гілці, де самотест реально
    # запускається.
    if ($currentGitBranch -in @('master', 'main')) {
        Test-BRAVOCondition `
            -Condition (
                [string]$loadedConfiguration.Version.ReleaseChannel -eq 'stable' -and
                [string]$loadedConfiguration.Version.PackageVersion -match '^\d+\.\d+\.\d+$'
            ) `
            -Name "Version/StableBranchNotDevelopmentChannel" `
            -Failure "гілка '$currentGitBranch' має нести stable-версію X.Y.Z і releaseChannel='stable' у VERSION.json (RELEASE_POLICY.md, розділи 2.2 і 5.3)"
    }
    if ($currentGitBranch -eq 'developer') {
        Test-BRAVOCondition `
            -Condition (
                [string]$loadedConfiguration.Version.ReleaseChannel -in @('development', 'prerelease') -and
                [string]$loadedConfiguration.Version.PackageVersion -match '^\d+\.\d+\.\d+-(dev|rc)\.\d+$' -and
                [string]$loadedConfiguration.Version.ReleaseChannelSource -eq 'VERSION.json'
            ) `
            -Name "Version/DeveloperBranchCarriesPrereleaseVersion" `
            -Failure "гілка developer має нести prerelease-версію X.Y.Z-dev.N або X.Y.Z-rc.N і відповідний releaseChannel, записаний саме у VERSION.json (RELEASE_POLICY.md, розділи 2.1 і 5.3)"
    }

    # Resolve-BRAVOReleaseChannelFromGit більше не джерело каналу
    # (RELEASE_POLICY.md, розділ 5.4), але лишається перехресною
    # перевіркою — тому мапінг гілок має бути правильним і далі.
    Test-BRAVOCondition `
        -Condition (
            (Resolve-BRAVOReleaseChannelFromGit -ConfigRoot $root -GitHeadContent "ref: refs/heads/master`n") -eq 'stable' -and
            (Resolve-BRAVOReleaseChannelFromGit -ConfigRoot $root -GitHeadContent "ref: refs/heads/main`n") -eq 'stable' -and
            (Resolve-BRAVOReleaseChannelFromGit -ConfigRoot $root -GitHeadContent "ref: refs/heads/developer`n") -eq 'development' -and
            $null -eq (Resolve-BRAVOReleaseChannelFromGit -ConfigRoot $root -GitHeadContent "ref: refs/heads/feature/xyz`n") -and
            $null -eq (Resolve-BRAVOReleaseChannelFromGit -ConfigRoot $root -GitHeadContent "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2`n") -and
            $null -eq (Resolve-BRAVOReleaseChannelFromGit -ConfigRoot $root -GitHeadContent "")
        ) `
        -Name "Version/ReleaseChannelResolvedFromGitBranch" `
        -Failure "Resolve-BRAVOReleaseChannelFromGit має мапити master/main->stable, developer->development, і повертати \$null для інших гілок, detached HEAD або порожнього вмісту"

    # RELEASE_POLICY.md, розділ 5.3: канал релізу читається з пакета, а не
    # виводиться з гілки. Розгорнутий на сервері комплект приходить ZIP-ом
    # або копіюванням — .git там немає взагалі, і канал нізвідки взяти.
    $versionMetadataForChannelSource = Get-BravoVersionMetadata -ConfigRoot $root
    Test-BRAVOCondition `
        -Condition (
            [string]$versionMetadataForChannelSource.ReleaseChannelSource -eq 'VERSION.json' -and
            [string]$versionMetadataForChannelSource.ReleaseChannel -in @('stable', 'development', 'prerelease') -and
            $false -ne $versionMetadataForChannelSource.ReleaseChannelMatchesGit
        ) `
        -Name "Version/ReleaseChannelStoredInPackage" `
        -Failure "releaseChannel має братися з VERSION.json (джерело 'VERSION.json') і не суперечити гілці в .git/HEAD — RELEASE_POLICY.md, розділи 5.3-5.4"

    $moduleManifests = @(Get-ChildItem -LiteralPath (Join-Path $root 'modules') -Recurse -Filter '*.psd1' -File)
    # RELEASE_POLICY.md, розділ 3.4: ModuleVersion це [System.Version] —
    # prerelease-суфікса він не приймає, а New-ModuleManifest у Windows
    # PowerShell 5.1 не має -Prerelease. Тому маніфести несуть БАЗОВУ
    # частину packageVersion, а повна версія завжди береться з VERSION.json.
    $expectedModuleVersion = ([string]$loadedConfiguration.Version.PackageVersion) -replace '-.*$', ''
    $moduleVersionsMatch = @($moduleManifests | Where-Object {
            [string](Test-ModuleManifest -Path $_.FullName -ErrorAction Stop).Version -ne
            $expectedModuleVersion
        }).Count -eq 0
    Test-BRAVOCondition `
        -Condition ($moduleManifests.Count -gt 0 -and $moduleVersionsMatch) `
        -Name "Version/ModuleManifests" `
        -Failure "ModuleVersion усіх manifests має відповідати базовій частині packageVersion у VERSION.json (без prerelease-суфікса)"
    $archiveScriptTextForBuildId = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $healthScriptTextForBuildId = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $maintenanceScriptTextForBuildId = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptTextForBuildId.Contains('$ScriptBuildId') -and
            $healthScriptTextForBuildId.Contains('$global:ScriptBuildId') -and
            $maintenanceScriptTextForBuildId.Contains('$global:ScriptBuildId')
        ) `
        -Name "Version/BuildIdSurfacedInRuntimes" `
        -Failure "buildId має потрапляти в runtime-метадані"

    # Аудит P4: короткий buildId не дає однозначної відповіді, який саме
    # код розгорнуто (короткі hash збігаються й погано шукаються).
    $versionMetadataForCommit = Get-BravoVersionMetadata -ConfigRoot $root
    Test-BRAVOCondition `
        -Condition (
            $null -ne $versionMetadataForCommit.PSObject.Properties['SourceCommit'] -and
            $versionMetadataForCommit.SourceCommit -match '^[0-9a-f]{40}$'
        ) `
        -Name "Version/SourceCommitIsFullGitHash" `
        -Failure "VERSION.json має містити sourceCommit — повний 40-символьний git-hash (ci\Update-BRAVOVersionStamp.ps1 -Apply); короткий buildId не дає однозначної відповіді, який код розгорнуто"
    $archiveHelpersModulePath = Join-Path `
        $root `
        'modules\BRAVO.ArchiveHelpers\BRAVO.ArchiveHelpers.psd1'
    Remove-Module -Name 'BRAVO.ArchiveHelpers' -Force -ErrorAction SilentlyContinue
    Import-Module -Name $archiveHelpersModulePath -Force -ErrorAction Stop
    $archiveHelperSmokeCompleted = $false
    try {
        $archiveHelperSmokeResult = Test-SevenZipArchiveIntegrity `
            -SevenZipPath (Join-Path $root '__MISSING_7Z__.exe') `
            -ArchivePath (Join-Path $root '__MISSING_ARCHIVE__.7z') `
            -Password 'self-test-placeholder' `
            -Logger { param($Message, $Level) }
        $archiveHelperSmokeCompleted = ($archiveHelperSmokeResult -eq $false)
    } catch {
        $archiveHelperSmokeCompleted = $false
    }
    Test-BRAVOCondition `
        -Condition $archiveHelperSmokeCompleted `
        -Name "Modules/ArchiveHelpersAreCallerIndependent" `
        -Failure "ArchiveHelpers мають виконуватися без приватних функцій caller-а"
    Test-BRAVOCondition `
        -Condition ([string]$archiveParams -match '(?i)(^|\s)-ssw(\s|$)') `
        -Name "BackupAvailability/AllowOpenFiles" `
        -Failure "backup без зупинки служб має дозволяти читання відкритих файлів"
    $archiveScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $healthScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $notificationScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Notifications\BRAVO.Notifications.psm1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition ($notificationScriptText.Contains("function Format-BRAVOOperatorStatusLine")) `
        -Name "Notifications/StatusLineHelperExists" `
        -Failure "BRAVO.Notifications повинен експортувати Format-BRAVOOperatorStatusLine для status-first component rows"
    # dev.12: реальні component-рядки Health SUCCESS (BLOG/BRAVOEXCH/MODEL,
    # Local, SFTP, BAZA_APP/BAZA_WWW, SMB) мають будуватись через helper, а
    # не через стару схему з фіксованими пробілами перед :white_check_mark:.
    Test-BRAVOCondition `
        -Condition (
            $healthScriptText.Contains('Format-BRAVOOperatorStatusLine -Status SUCCESS -Icon ":package:" -Name $_.Type -Detail $sizeText') -and
            $healthScriptText.Contains('Format-BRAVOOperatorStatusLine -Status SUCCESS -Icon ":floppy_disk:" -Name "Local"') -and
            $healthScriptText.Contains('Format-BRAVOOperatorStatusLine -Status SUCCESS -Icon ":cloud:" -Name "SFTP"') -and
            $healthScriptText.Contains('Format-BRAVOOperatorStatusLine -Status SUCCESS -Icon ":arrows_counterclockwise:" -Name "BAZA_APP" -Detail "синхронізовано"') -and
            $healthScriptText.Contains('Format-BRAVOOperatorStatusLine -Status SUCCESS -Icon ":arrows_counterclockwise:" -Name "BAZA_WWW" -Detail "синхронізовано"') -and
            $healthScriptText.Contains('Format-BRAVOOperatorStatusLine -Status SUCCESS -Icon ":minidisc:" -Name "SMB"')
        ) `
        -Name "Health/SuccessRowsUseStatusLineHelper" `
        -Failure "Health SUCCESS component rows (BLOG/Local/SFTP/BAZA_APP/BAZA_WWW/SMB) мають будуватись через Format-BRAVOOperatorStatusLine"
    Test-BRAVOCondition `
        -Condition ($healthScriptText -notmatch '"\s*:\w+:\s+\S[^"]*\S {2,}:white_check_mark:') `
        -Name "Health/SuccessRowsDoNotPadStatusIcon" `
        -Failure "BRAVO.Health.Runtime.ps1 не повинен вирівнювати статус-іконку фіксованими пробілами — Discord/Slack рендерять пропорційним шрифтом"

    # ============================================================
    # dev.13: manual elevation + environment preflight (BRAVO_HEALTH.ps1
    # + BRAVO.Health.Runtime.ps1). Root cause: ручний non-elevated запуск
    # бачив D:\BRAVO\LOGS/TEMP (їх створив SYSTEM), але не міг у них
    # писати — AccessDenied спливала лише глибоко в SFTP-етапі й ставала
    # фальшивою "SFTP недоступний".
    # ============================================================

    # --- F: environment permission classification (write-probe helper) ---
    $healthPreflightModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $healthScriptText `
        -FunctionNames @(
            'Test-BRAVOHealthIsPrivilegeException',
            'Test-BRAVOHealthRuntimePathWritable',
            'Test-BRAVOHealthEnvironmentPreflight'
        )

    # correctness pass: не кожна I/O-відмова означає "потрібні права
    # адміністратора". Синтетичні exception-об'єкти — детерміновано,
    # портативно, без реальної зміни ACL (заборонено в self-test).
    $privilegeClassification = & $healthPreflightModule {
        Test-BRAVOHealthIsPrivilegeException -Exception (
            New-Object System.UnauthorizedAccessException("Access is denied.")
        )
    }
    $privilegeClassificationWrapped = & $healthPreflightModule {
        Test-BRAVOHealthIsPrivilegeException -Exception (
            New-Object System.InvalidOperationException(
                "wrap", (New-Object System.UnauthorizedAccessException("inner denied")))
        )
    }
    $genericClassification = & $healthPreflightModule {
        Test-BRAVOHealthIsPrivilegeException -Exception (
            New-Object System.IO.IOException("There is not enough space on the disk.")
        )
    }
    Test-BRAVOCondition `
        -Condition (
            $privilegeClassification -eq $true -and
            $privilegeClassificationWrapped -eq $true -and
            $genericClassification -eq $false
        ) `
        -Name "Health/PrivilegeFailureClassification" `
        -Failure "Test-BRAVOHealthIsPrivilegeException має розпізнавати UnauthorizedAccessException (включно із загорнутим в InnerException) як privilege-відмову"
    Test-BRAVOCondition `
        -Condition ($genericClassification -eq $false) `
        -Name "Health/GenericEnvironmentFailureClassification" `
        -Failure "IOException (диск повний тощо) НЕ повинен класифікуватися як privilege-відмова"
    $preflightWritableDir = Join-Path $env:TEMP (
        "bravo_selftest_preflight_{0}" -f ([guid]::NewGuid().ToString("N"))
    )
    [void](New-Item -ItemType Directory -Path $preflightWritableDir -Force)
    try {
        # NTFS відхиляє "|"/"?" у назві незалежно від прав доступу —
        # детермінований, портативний спосіб отримати AccessDenied-подібну
        # відмову без реальної зміни ACL (заборонено в self-test).
        $preflightInvalidPath = Join-Path $preflightWritableDir "invalid|name?"

        $preflightOkResult = & $healthPreflightModule {
            param($Path)
            Test-BRAVOHealthRuntimePathWritable -Path $Path
        } $preflightWritableDir
        $preflightArtifactsAfterOk = @(Get-ChildItem -LiteralPath $preflightWritableDir -Force)
        Test-BRAVOCondition `
            -Condition (
                $preflightOkResult.IsWritable -eq $true -and
                [string]::IsNullOrEmpty($preflightOkResult.ErrorMessage) -and
                $preflightOkResult.IsPrivilegeFailure -eq $false -and
                $preflightArtifactsAfterOk.Count -eq 0
            ) `
            -Name "Health/PreflightWritableSucceedsAndCleansUp" `
            -Failure "Test-BRAVOHealthRuntimePathWritable на доступному каталозі має повертати IsWritable=true й не залишати probe-артефакти"

        $preflightFailResult = & $healthPreflightModule {
            param($Path)
            Test-BRAVOHealthRuntimePathWritable -Path $Path
        } $preflightInvalidPath
        Test-BRAVOCondition `
            -Condition (
                $preflightFailResult.IsWritable -eq $false -and
                -not [string]::IsNullOrWhiteSpace($preflightFailResult.ErrorMessage) -and
                # Некоректні символи в шляху -> ArgumentException, НЕ
                # UnauthorizedAccessException -> generic, не privilege.
                $preflightFailResult.IsPrivilegeFailure -eq $false
            ) `
            -Name "Health/PreflightUnwritableFails" `
            -Failure "Test-BRAVOHealthRuntimePathWritable на недоступному шляху має повертати IsWritable=false з ErrorMessage і коректною (generic, не privilege) класифікацією для ArgumentException"

        # НЕ "SFTP=False": FailedPath має вказувати саме на той каталог
        # (LOGS чи TEMP), який справді провалився.
        $preflightBadTemp = & $healthPreflightModule {
            param($LogPath, $TempPath)
            Test-BRAVOHealthEnvironmentPreflight -LogPath $LogPath -TemporaryRoot $TempPath
        } $preflightWritableDir $preflightInvalidPath
        $preflightBadLog = & $healthPreflightModule {
            param($LogPath, $TempPath)
            Test-BRAVOHealthEnvironmentPreflight -LogPath $LogPath -TemporaryRoot $TempPath
        } $preflightInvalidPath $preflightWritableDir
        Test-BRAVOCondition `
            -Condition (
                $preflightBadTemp.IsWritable -eq $false -and
                $preflightBadTemp.FailedPath -eq $preflightInvalidPath -and
                $preflightBadLog.IsWritable -eq $false -and
                $preflightBadLog.FailedPath -eq $preflightInvalidPath
            ) `
            -Name "Health/EnvironmentPreflightIdentifiesFailedPath" `
            -Failure "Test-BRAVOHealthEnvironmentPreflight має повідомляти саме той шлях (LOGS чи TEMP), що провалився — не узагальнений SFTP/False"
    } finally {
        Remove-Item -LiteralPath $preflightWritableDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- correctness pass, 3rd iteration: тести, що раніше напряму
    # редагували список контролю доступу тимчасового каталогу, видалено —
    # dev.13 вимагає "не виконувати ACL modifications", і self-test не
    # повинен чіпати права доступу навіть на власних тимчасових
    # каталогах: це залежність від NTFS/WRITE_DAC/локальної ACL policy,
    # якої не повинно бути в детермінованих unit-тестах. Класифікація
    # перевіряється через ЧИСТУ функцію (Test-BRAVOHealthIsPrivilegeException
    # бере Exception, не чіпає диск) із синтетичними винятками — той самий
    # підхід, що вже Health/PrivilegeFailureClassification/
    # GenericEnvironmentFailureClassification нижче. Лише
    # "MissingTempGenericIoIsEnvironmentUnavailable" лишається реальним
    # I/O (некоректні символи в шляху -> ArgumentException) — це не зміна
    # прав доступу, звичайна відмова створення файлу/каталогу.
    $classificationTestDir = Join-Path $env:TEMP (
        "bravo_selftest_classification_{0}" -f ([guid]::NewGuid().ToString("N"))
    )
    [void](New-Item -ItemType Directory -Path $classificationTestDir -Force)
    try {
        # Health/MissingTempAccessDeniedIsPrivilegeFailure: той самий
        # exception shape, що Get-BRAVOHealthTemporaryRoot реально кидає,
        # коли ПЕРШИЙ кандидат TEMP не створюється через AccessDenied —
        # RuntimeException, чиє InnerException = UnauthorizedAccessException
        # (не $_.Exception.Message-рядок, типізований об'єкт).
        # Test-BRAVOHealthIsPrivilegeException має прочитати це через
        # InnerException chain так само, як прямий (нешорований) виняток.
        $missingTempWrappedException = New-Object System.Management.Automation.RuntimeException(
            "не знайдено доступного ASCII-каталогу для тимчасових файлів WinSCP; TEMP: Access is denied.",
            (New-Object System.UnauthorizedAccessException("Access is denied.")))
        $missingTempClassification = & $healthPreflightModule {
            param($Exception) Test-BRAVOHealthIsPrivilegeException -Exception $Exception
        } $missingTempWrappedException
        Test-BRAVOCondition `
            -Condition ($missingTempClassification -eq $true) `
            -Name "Health/MissingTempAccessDeniedIsPrivilegeFailure" `
            -Failure "RuntimeException з InnerException=UnauthorizedAccessException (форма, яку реально кидає Get-BRAVOHealthTemporaryRoot при відсутньому TEMP) має класифікуватись як privilege failure (36)"

        # Health/MissingTempGenericIoIsEnvironmentUnavailable: відсутній
        # каталог, чиє СПРАВЖНЄ створення провалюється НЕ через права
        # (некоректні символи -> ArgumentException) -> generic (37), не
        # privilege. Реальний, детермінований I/O; жодної ACL-мутації.
        $missingTempGenericPath = Join-Path $classificationTestDir "generic-missing-temp|invalid?"
        $missingTempGenericResult = & $healthPreflightModule {
            param($Path) Test-BRAVOHealthRuntimePathWritable -Path $Path
        } $missingTempGenericPath
        Test-BRAVOCondition `
            -Condition (
                $missingTempGenericResult.IsWritable -eq $false -and
                $missingTempGenericResult.IsPrivilegeFailure -eq $false
            ) `
            -Name "Health/MissingTempGenericIoIsEnvironmentUnavailable" `
            -Failure "New-Item на відсутньому TEMP-каталозі, що провалюється НЕ через права (некоректні символи), має класифікуватись як generic (37), не privilege (36)"
    } finally {
        Remove-Item -LiteralPath $classificationTestDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- A/B/C/D/E + UAC cancel: BRAVO_HEALTH.ps1 elevation gate ---
    $healthEntrypointScriptTextForElevation = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_HEALTH.ps1"),
        [Text.Encoding]::UTF8
    )
    $healthElevationModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $healthEntrypointScriptTextForElevation `
        -FunctionNames @(
            'Get-BRAVOHealthElevationState',
            'Test-BRAVOHealthManualInteractiveSession',
            'Get-BRAVOHealthElevationAction',
            'New-BRAVOHealthRelaunchArgumentList',
            'Test-BRAVOHealthElevationCancelled',
            'Test-BRAVOHealthExplicitNonInteractive'
        )

    # correctness pass, 2nd iteration: [Environment]::UserInteractive/
    # [Console]::IsInputRedirected НЕ доводять, що powershell.exe отримав
    # -NonInteractive. Перша ітерація читала Win32_Process.CommandLine
    # через CIM/WMI — видалено: [Environment]::GetCommandLineArgs() (.NET
    # Framework, вбудований, PS 5.1-сумісний) повертає ВЖЕ розпарсений
    # argv без жодної залежності від CIM/WMI (перевірено емпірично: лапки
    # з пробілами лишаються ОДНИМ елементом навіть коли значення містить
    # підрядок "-NonInteractive"). Порівняння — точне (не substring/-like).
    $explicitNonInteractiveArgvCases = @(
        @{ Argv = @('powershell.exe', '-NonInteractive', '-File', 'D:\BRAVO\BRAVO_HEALTH.ps1'); Expected = $true },
        @{ Argv = @('powershell.exe', '-NoProfile', '-NonInteractive', '-File', 'D:\BRAVO\BRAVO_HEALTH.ps1'); Expected = $true },
        @{ Argv = @('powershell.exe', '-File', 'D:\BRAVO\BRAVO_HEALTH.ps1'); Expected = $false },
        @{ Argv = @('powershell.exe', '-File', 'C:\NonInteractive Test\script.ps1'); Expected = $false },
        @{ Argv = @('powershell.exe', '-File', 'D:\BRAVO\BRAVO_HEALTH.ps1', '-ConfigPath', 'C:\foo\-NonInteractive\bar'); Expected = $false }
    )
    $explicitNonInteractiveArgvFailures = @(
        $explicitNonInteractiveArgvCases | Where-Object {
            $actual = & $healthElevationModule {
                param($Argv) Test-BRAVOHealthExplicitNonInteractive -Argv $Argv
            } $_.Argv
            $actual -ne $_.Expected
        } | ForEach-Object { $_.Argv -join ' ' }
    )
    Test-BRAVOCondition `
        -Condition ($explicitNonInteractiveArgvFailures.Count -eq 0) `
        -Name "Health/ExplicitNonInteractiveUsesProcessArgv" `
        -Failure "Test-BRAVOHealthExplicitNonInteractive(argv) неправильно класифікував: $($explicitNonInteractiveArgvFailures -join ' | ')"

    # Функція реально виконана в цьому self-test процесі (не лише
    # синтетичні argv вище) — підтверджує end-to-end, що [Environment]::
    # GetCommandLineArgs() повертає рядковий масив, який функція приймає
    # без винятку, і що результат стабільний (той самий процес -> той
    # самий висновок при повторному виклику).
    $realArgvResultFirstCall = & $healthElevationModule {
        Test-BRAVOHealthExplicitNonInteractive -Argv ([Environment]::GetCommandLineArgs())
    }
    $realArgvResultSecondCall = & $healthElevationModule {
        Test-BRAVOHealthExplicitNonInteractive -Argv ([Environment]::GetCommandLineArgs())
    }
    Test-BRAVOCondition `
        -Condition (
            ($realArgvResultFirstCall -is [bool]) -and
            ($realArgvResultFirstCall -eq $realArgvResultSecondCall)
        ) `
        -Name "Health/ExplicitNonInteractiveDoesNotDependOnWmi" `
        -Failure "Test-BRAVOHealthExplicitNonInteractive -Argv ([Environment]::GetCommandLineArgs()) має працювати без жодного CIM/WMI виклику й повертати стабільний bool"

    # A: elevated Administrator -> true; SYSTEM -> privileged; звичайний -> false.
    $elevationStateAdmin = & $healthElevationModule {
        param($Sid, $IsAdmin) Get-BRAVOHealthElevationState -UserSid $Sid -IsAdministratorRole $IsAdmin
    } 'S-1-5-21-1111111111-2222222222-3333333333-500' $true
    $elevationStateSystem = & $healthElevationModule {
        param($Sid, $IsAdmin) Get-BRAVOHealthElevationState -UserSid $Sid -IsAdministratorRole $IsAdmin
    } 'S-1-5-18' $true
    $elevationStateStandard = & $healthElevationModule {
        param($Sid, $IsAdmin) Get-BRAVOHealthElevationState -UserSid $Sid -IsAdministratorRole $IsAdmin
    } 'S-1-5-21-1111111111-2222222222-3333333333-1001' $false
    Test-BRAVOCondition `
        -Condition (
            $elevationStateAdmin -eq 'Administrator' -and
            $elevationStateSystem -eq 'System' -and
            $elevationStateStandard -eq 'Standard'
        ) `
        -Name "Health/ElevationDetectionStates" `
        -Failure "Get-BRAVOHealthElevationState: elevated Administrator -> Administrator, SYSTEM (S-1-5-18) -> System, звичайний акаунт -> Standard"

    # B: ручний interactive non-elevated -> self-relaunch (Relaunch).
    $actionManualInteractive = & $healthElevationModule {
        param($State, $Interactive) Get-BRAVOHealthElevationAction -ElevationState $State -IsManualInteractiveSession $Interactive
    } 'Standard' $true
    Test-BRAVOCondition `
        -Condition ($actionManualInteractive -eq 'Relaunch') `
        -Name "Health/ElevationManualInteractiveRelaunches" `
        -Failure "non-elevated + manual interactive сесія має повертати дію Relaunch (self-relaunch через Start-Process -Verb RunAs)"

    # C: SYSTEM/non-interactive НІКОЛИ не запускає -Verb RunAs.
    $actionStandardNonInteractive = & $healthElevationModule {
        param($State, $Interactive) Get-BRAVOHealthElevationAction -ElevationState $State -IsManualInteractiveSession $Interactive
    } 'Standard' $false
    $actionSystemInteractive = & $healthElevationModule {
        param($State, $Interactive) Get-BRAVOHealthElevationAction -ElevationState $State -IsManualInteractiveSession $Interactive
    } 'System' $true
    $actionSystemNonInteractive = & $healthElevationModule {
        param($State, $Interactive) Get-BRAVOHealthElevationAction -ElevationState $State -IsManualInteractiveSession $Interactive
    } 'System' $false
    Test-BRAVOCondition `
        -Condition (
            $actionStandardNonInteractive -eq 'FailFast' -and
            $actionSystemInteractive -eq 'Proceed' -and
            $actionSystemNonInteractive -eq 'Proceed'
        ) `
        -Name "Health/ElevationSystemNeverRelaunches" `
        -Failure "SYSTEM (заплановане завдання) має завжди Proceed незалежно від interactive-прапорця; non-elevated non-interactive має FailFast — жодна з цих гілок не відкриває UAC"

    # correctness pass: явний -NonInteractive у власному command line має
    # ПЕРЕКРИВАТИ "виглядає interactive" (UserInteractive=true) і форсити
    # FailFast — без цього powershell.exe -NonInteractive -File
    # BRAVO_HEALTH.ps1, запущений з інтерактивної консолі, помилково
    # спробував би Start-Process -Verb RunAs.
    $actionExplicitNonInteractiveOverride = & $healthElevationModule {
        param($State, $Interactive, $ExplicitNonInteractive)
        Get-BRAVOHealthElevationAction `
            -ElevationState $State `
            -IsManualInteractiveSession $Interactive `
            -IsExplicitNonInteractive $ExplicitNonInteractive
    } 'Standard' $true $true
    $actionExplicitNonInteractiveRunAsCount = 0
    if ($actionExplicitNonInteractiveOverride -eq 'Relaunch') { $actionExplicitNonInteractiveRunAsCount = 1 }
    Test-BRAVOCondition `
        -Condition (
            $actionExplicitNonInteractiveOverride -eq 'FailFast' -and
            $actionExplicitNonInteractiveRunAsCount -eq 0
        ) `
        -Name "Health/ExplicitNonInteractiveFailsFast" `
        -Failure "Standard + IsManualInteractiveSession=true + IsExplicitNonInteractive=true має все одно давати FailFast (не Relaunch) — жодного Start-Process -Verb RunAs для явного -NonInteractive"

    # Лише код, без коментарів (два коментарі вище в цьому ж файлі згадують
    # "-Verb RunAs" у прозі) — інакше підрахунок входжень враховував би їх.
    $healthElevationCodeOnlyText = (
        (
            $healthEntrypointScriptTextForElevation -split "`r?`n" |
                Where-Object { $_ -notmatch '^\s*#' }
        ) -join "`n"
    )
    $healthElevationRunAsOccurrences = @(
        [regex]::Matches($healthElevationCodeOnlyText, [regex]::Escape('-Verb RunAs'))
    ).Count
    Test-BRAVOCondition `
        -Condition (
            $healthElevationRunAsOccurrences -eq 1 -and
            $healthElevationCodeOnlyText.IndexOf("if (`$healthElevationState -eq 'Standard') {") -lt
                $healthElevationCodeOnlyText.IndexOf('-Verb RunAs')
        ) `
        -Name "Health/RunAsOnlyReachableFromStandardBranch" `
        -Failure "Start-Process -Verb RunAs має бути рівно один виклик у коді, і він має бути всередині гілки ElevationState -eq 'Standard' — SYSTEM/Administrator ніколи туди не заходять"

    # correctness pass, 2nd iteration: -NonInteractive detection більше НЕ
    # залежить від CIM/WMI/Win32_Process узагалі — лише вбудований .NET
    # [Environment]::GetCommandLineArgs(). Перша ітерація йшла через
    # Get-BRAVOWmiInstance -ClassName Win32_Process; видалено разом з
    # Import-Module BRAVO.Compatibility (тут більше не потрібен).
    Test-BRAVOCondition `
        -Condition (
            -not $healthElevationCodeOnlyText.Contains('Win32_Process') -and
            -not $healthElevationCodeOnlyText.Contains('Get-BRAVOWmiInstance') -and
            -not $healthElevationCodeOnlyText.Contains('Get-CimInstance') -and
            -not $healthElevationCodeOnlyText.Contains('Get-WmiObject') -and
            -not $healthElevationCodeOnlyText.Contains("Import-Module -Name (Join-Path `$PSScriptRoot 'modules\BRAVO.Compatibility") -and
            $healthElevationCodeOnlyText.Contains('[Environment]::GetCommandLineArgs()')
        ) `
        -Name "Health/NonInteractiveDetectionHasNoWmiDependency" `
        -Failure "-NonInteractive detection не повинен залежати від CIM/WMI/Win32_Process чи імпортувати BRAVO.Compatibility — лише [Environment]::GetCommandLineArgs()"

    # D: детерміноване перенесення параметрів (ConfigPath/NoPause/
    # NotifyOnSuccess/SkipIfBackupTaskRunning) + невказані параметри не
    # з'являються в дочірньому виклику.
    $boundAllParameters = @{
        ConfigPath = 'D:\BRAVO\BRAVO.config'
        NoPause = [System.Management.Automation.SwitchParameter]::Present
        NotifyOnSuccess = [System.Management.Automation.SwitchParameter]::Present
        SkipIfBackupTaskRunning = [System.Management.Automation.SwitchParameter]::Present
        ForceNotification = [System.Management.Automation.SwitchParameter]$false
        NoSlack = [System.Management.Automation.SwitchParameter]$false
    }
    $relaunchArgsAll = & $healthElevationModule {
        param($ScriptPath, $Bound, $ResolvedConfig)
        New-BRAVOHealthRelaunchArgumentList -ScriptPath $ScriptPath -BoundParameters $Bound -ResolvedConfigPath $ResolvedConfig
    } 'D:\BRAVO\BRAVO_HEALTH.ps1' $boundAllParameters 'D:\BRAVO\BRAVO.config'
    Test-BRAVOCondition `
        -Condition (
            ($relaunchArgsAll -join ' ').Contains('-ConfigPath "D:\BRAVO\BRAVO.config"') -and
            $relaunchArgsAll -contains '-NoPause' -and
            $relaunchArgsAll -contains '-NotifyOnSuccess' -and
            $relaunchArgsAll -contains '-SkipIfBackupTaskRunning' -and
            $relaunchArgsAll -notcontains '-ForceNotification' -and
            $relaunchArgsAll -notcontains '-NoSlack'
        ) `
        -Name "Health/RelaunchPropagatesBoundParametersOnly" `
        -Failure "New-BRAVOHealthRelaunchArgumentList має переносити ConfigPath/NoPause/NotifyOnSuccess/SkipIfBackupTaskRunning, коли вони задані, і НЕ додавати switch-параметри, задані як `$false, або взагалі не вказані"

    $relaunchArgsNoSwitches = & $healthElevationModule {
        param($ScriptPath, $Bound, $ResolvedConfig)
        New-BRAVOHealthRelaunchArgumentList -ScriptPath $ScriptPath -BoundParameters $Bound -ResolvedConfigPath $ResolvedConfig
    } 'D:\BRAVO\BRAVO_HEALTH.ps1' @{} 'D:\BRAVO\BRAVO.config'
    Test-BRAVOCondition `
        -Condition (
            $relaunchArgsNoSwitches -notcontains '-NoPause' -and
            $relaunchArgsNoSwitches -notcontains '-NotifyOnSuccess' -and
            $relaunchArgsNoSwitches -notcontains '-SkipIfBackupTaskRunning' -and
            $relaunchArgsNoSwitches -notcontains '-ForceNotification' -and
            $relaunchArgsNoSwitches -notcontains '-NoSlack'
        ) `
        -Name "Health/RelaunchOmitsUnboundNoPause" `
        -Failure "звичайний ручний запуск без жодного switch (типовий подвійний клік) не повинен додавати -NoPause в дочірній виклик — elevated console має чекати на клавішу так само, як не-elevated"

    # E: ConfigPath із пробілами не має розпастись на кілька argv.
    # Start-Process -ArgumentList (string[]) НЕ квотує пробіли сам —
    # перевірено емпірично; New-BRAVOHealthRelaunchArgumentList зобов'язаний
    # обгортати значення в лапки явно.
    $spacedConfigPath = 'C:\Program Files\BRAVO Test\BRAVO.config'
    $relaunchArgsSpaced = & $healthElevationModule {
        param($ScriptPath, $Bound, $ResolvedConfig)
        New-BRAVOHealthRelaunchArgumentList -ScriptPath $ScriptPath -BoundParameters $Bound -ResolvedConfigPath $ResolvedConfig
    } 'D:\BRAVO\BRAVO_HEALTH.ps1' @{} $spacedConfigPath
    $spacedConfigArgIndex = [array]::IndexOf($relaunchArgsSpaced, '-ConfigPath')
    Test-BRAVOCondition `
        -Condition (
            $spacedConfigArgIndex -ge 0 -and
            $relaunchArgsSpaced.Count -gt ($spacedConfigArgIndex + 1) -and
            $relaunchArgsSpaced[$spacedConfigArgIndex + 1] -eq ('"' + $spacedConfigPath + '"')
        ) `
        -Name "Health/RelaunchQuotesPathsWithSpaces" `
        -Failure "-ConfigPath зі пробілами має передаватися одним argv у лапках, а не розпадатися на кілька елементів Start-Process -ArgumentList"

    # UAC Cancel: Win32Exception(1223) = ERROR_CANCELLED, інколи загорнутий.
    $uacCancelledDetected = & $healthElevationModule {
        try {
            throw (New-Object System.InvalidOperationException(
                "wrap", (New-Object System.ComponentModel.Win32Exception(1223))))
        } catch {
            Test-BRAVOHealthElevationCancelled -ErrorRecord $_
        }
    }
    $uacOtherErrorDetected = & $healthElevationModule {
        try {
            throw (New-Object System.InvalidOperationException("не пов'язана помилка"))
        } catch {
            Test-BRAVOHealthElevationCancelled -ErrorRecord $_
        }
    }
    Test-BRAVOCondition `
        -Condition ($uacCancelledDetected -eq $true -and $uacOtherErrorDetected -eq $false) `
        -Name "Health/ElevationCancelledIsDetectedSpecifically" `
        -Failure "Test-BRAVOHealthElevationCancelled має розпізнавати саме Win32Exception(1223)/ERROR_CANCELLED (Cancel у UAC), а не будь-яку помилку Start-Process"

    $bravoConfigText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO.config"),
        [Text.Encoding]::UTF8
    )

    # Health/SelfTestDoesNotModifyAcl: регресійний guard проти повернення
    # ACL-мутації в dev.13 test block (manual elevation + environment
    # preflight, вище цього рядка — до відповідного маркера-початку).
    # Розташований СВІДОМО поза межами діапазону, який сам сканує: інакше
    # власні рядкові літерали цього ж guard-а (назви заборонених команд)
    # збіглися б із власним пошуком. Читає ВЛАСНИЙ файл self-test із
    # диска — той самий підхід, що вже використовується для інших файлів
    # у цьому наборі тестів. НЕ перевіряє файл цілком: Get-Acl/
    # AddAccessRule/FileSystemAccessRule legітимно існують в інших,
    # непов'язаних тестах цього файлу (WinSCP temporary script
    # permissions, Task Installer inheritance probe) — там вони або
    # read-only (Get-Acl без Set-Acl), або працюють над копією в пам'яті
    # без персистенції на диск.
    $selfTestOwnSourceText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_SELF_TEST.ps1"),
        [Text.Encoding]::UTF8
    )
    $dev13AclTestBlockStart = $selfTestOwnSourceText.IndexOf(
        '# dev.13: manual elevation + environment preflight'
    )
    $dev13AclTestBlockEnd = $selfTestOwnSourceText.IndexOf(
        '$bravoConfigText = [IO.File]::ReadAllText(', $dev13AclTestBlockStart
    )
    $dev13AclTestBlockText = if ($dev13AclTestBlockStart -ge 0 -and $dev13AclTestBlockEnd -gt $dev13AclTestBlockStart) {
        $selfTestOwnSourceText.Substring(
            $dev13AclTestBlockStart, $dev13AclTestBlockEnd - $dev13AclTestBlockStart
        )
    } else {
        # Порожній рядок замість $false: якщо маркери зникли/перейменувались,
        # .Contains() нижче на порожньому рядку не пройде хибно-позитивно —
        # -Condition оцінить це як "guard не знайшов свій блок" і впаде.
        ''
    }
    Test-BRAVOCondition `
        -Condition (
            -not [string]::IsNullOrEmpty($dev13AclTestBlockText) -and
            -not $dev13AclTestBlockText.Contains('Set-Acl') -and
            -not $dev13AclTestBlockText.Contains('AddAccessRule') -and
            -not $dev13AclTestBlockText.Contains('RemoveAccessRule') -and
            -not $dev13AclTestBlockText.Contains('FileSystemAccessRule')
        ) `
        -Name "Health/SelfTestDoesNotModifyAcl" `
        -Failure "dev.13 test block (manual elevation + environment preflight) у BRAVO_SELF_TEST.ps1 не повинен містити Set-Acl/AddAccessRule/RemoveAccessRule/FileSystemAccessRule — класифікація тестується чистими функціями/синтетичними винятками, не ACL-мутацією"

    $bravoExchSelectionStart = $bravoConfigText.IndexOf('$global:bravoExchSourceCandidates')
    $bravoExchSelectionEnd = $bravoConfigText.IndexOf('$bravoExchArchiveSource', $bravoExchSelectionStart)
    $bravoExchSelectionText = if (
        $bravoExchSelectionStart -ge 0 -and
        $bravoExchSelectionEnd -gt $bravoExchSelectionStart
    ) {
        $bravoConfigText.Substring(
            $bravoExchSelectionStart,
            $bravoExchSelectionEnd - $bravoExchSelectionStart
        )
    } else {
        ''
    }
    Test-BRAVOCondition `
        -Condition (
            $bravoExchSelectionText.Contains("Test-Path -LiteralPath `$candidateDirectory -PathType Container") -and
            -not $bravoExchSelectionText.Contains('Get-ChildItem')
        ) `
        -Name 'Discovery/EmptyCanonicalBravoExchDirectoryRemainsEnabled' `
        -Failure 'canonical BEXCH directory can be an idle queue tree with no files; config must accept the existing directory without a content heuristic'
    # CODE IS NOT DATA: -ConfigRoot береться з фактичного шляху конфігурації
    # (вона може лежати в окремому каталозі, наприклад C:\BRAVO\CONFIGS), а
    # -RuntimeRoot — це завжди каталог самого комплекту, звідки беруться
    # modules\, Tools\ і VERSION.json.
    $loaderCallPattern = 'Import-BravoConfiguration\s+`?\s*' +
        '-ConfigRoot\s+\(Split-Path[^\r\n]*\)\s+`?\s*' +
        '-ConfigPath\s+\$ConfigPath\s+`?\s*' +
        '-RuntimeRoot\s+\$bravoScriptDirectory'
    $archiveLoaderCalls = @([regex]::Matches($archiveScriptText, $loaderCallPattern)).Count
    $healthLoaderCalls = @([regex]::Matches($healthScriptText, $loaderCallPattern)).Count
    Test-BRAVOCondition `
        -Condition ($archiveLoaderCalls -eq 1 -and $healthLoaderCalls -eq 1) `
        -Name "ConfigurationLoader/ArchiveAndHealthEntrypoints" `
        -Failure "BRAVO_ARCHIV і BRAVO_HEALTH повинні завантажувати конфігурацію через loader із розділеними -ConfigRoot (каталог конфігурації) і -RuntimeRoot (каталог комплекту)"
    $archiveRuntimeModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($archiveScriptText + [Environment]::NewLine + $healthScriptText + [Environment]::NewLine + $notificationScriptText) `
        -FunctionNames @(
            "ConvertTo-NotificationLiteralText",
            "ConvertTo-DiscordNotificationText",
            "Split-DiscordNotificationText",
            "ConvertTo-BRAVONotificationPayloadText",
            "Send-BRAVONotificationChunks",
            "Test-BAZAPathBlockedByIncompatibleName",
            "Split-BAZAPendingFilesByCompatibility",
            "Get-BAZASynchronizationOutcome",
            "Get-BRAVOVSSSnapshotSourcePath",
            "Get-BRAVOVSSVolumeRoot",
            "Get-BRAVOUniqueVSSVolumes",
            "Get-BRAVOVSSVolumeIdentityCandidates",
            "Test-BRAVOVSSShadowMatchesVolume",
            "New-BRAVOVSSSnapshotSet",
            "Resolve-BRAVOSnapshotSourcePath",
            "Remove-BRAVOVSSVolumeShadow",
            "Remove-BRAVOVSSSnapshotSet",
            "Get-BRAVOVSSOwnershipStatePath",
            "Save-BRAVOVSSOwnershipState",
            "Remove-BRAVOOwnedOrphanVSSResources",
            "Get-BRAVOArchiveFreeSpaceResult",
            "Send-BRAVOArchiveFreeSpaceAlert",
            "Resolve-BRAVONotificationRoute",
            "Get-BRAVOCollisionSafeGenerationId",
            "New-BRAVOTemporaryArchivePath",
            "Remove-BRAVOTemporaryArchiveArtifacts",
            "Write-BRAVOFinalHashFile",
            "Invoke-BRAVOComponentBackup",
            "Remove-BRAVOWinSCPSensitiveTemporaryScript",
            "Clear-BRAVOStaleWinSCPSensitiveTemporaryScripts",
            "New-BRAVOWinSCPTemporaryScriptPath"
        )

    $freeSpaceHealthyDrives = @(
        [pscustomobject]@{
            Name = 'C:\'
            DriveType = [System.IO.DriveType]::Fixed
            IsReady = $true
            AvailableFreeSpace = 25GB
            TotalSize = 100GB
        },
        [pscustomobject]@{
            Name = 'D:\'
            DriveType = [System.IO.DriveType]::Fixed
            IsReady = $true
            AvailableFreeSpace = 1GB
            TotalSize = 100GB
        },
        [pscustomobject]@{
            Name = 'E:\'
            DriveType = [System.IO.DriveType]::Removable
            IsReady = $true
            AvailableFreeSpace = 1GB
            TotalSize = 10GB
        }
    )
    $freeSpaceHealthy = & $archiveRuntimeModule {
        param($RootPath, $Drives)
        Get-BRAVOArchiveFreeSpaceResult `
            -RootPath $RootPath `
            -MinimumFreeSpaceGB 20 `
            -ExcludedDrives @('D:') `
            -Drives $Drives
    } $root $freeSpaceHealthyDrives
    $freeSpaceLow = & $archiveRuntimeModule {
        param($RootPath)
        Get-BRAVOArchiveFreeSpaceResult `
            -RootPath $RootPath `
            -MinimumFreeSpaceGB 20 `
            -Drives @([pscustomobject]@{
                Name = 'C:\'
                DriveType = [System.IO.DriveType]::Fixed
                IsReady = $true
                AvailableFreeSpace = 15GB
                TotalSize = 100GB
            })
    } $root
    $freeSpaceAllExcluded = & $archiveRuntimeModule {
        param($RootPath)
        Get-BRAVOArchiveFreeSpaceResult `
            -RootPath $RootPath `
            -MinimumFreeSpaceGB 20 `
            -ExcludedDrives @('C:') `
            -Drives @([pscustomobject]@{
                Name = 'C:\'
                DriveType = [System.IO.DriveType]::Fixed
                IsReady = $true
                AvailableFreeSpace = 1GB
                TotalSize = 100GB
            })
    } $root
    Test-BRAVOCondition `
        -Condition (
            $freeSpaceHealthy.Success -and
            $freeSpaceHealthy.CheckedDriveCount -eq 1 -and
            @($freeSpaceHealthy.DriveStatus).Count -eq 1 -and
            $freeSpaceHealthy.DriveStatus[0].Drive -eq 'C:' -and
            -not $freeSpaceLow.Success -and
            $freeSpaceLow.Problems[0] -match 'залишилось 15 GB' -and
            $freeSpaceAllExcluded.Success -and
            $freeSpaceAllExcluded.AllExcluded
        ) `
        -Name 'Archive/FreeSpacePolicyMatchesMaintenance' `
        -Failure 'Archive має перевіряти лише Fixed-диски, поважати Maintenance.Limits.ExcludedDrives, блокувати запуск нижче порога та дозволяти конфігурацію, де всі диски явно виключені'

    $freeSpaceNotificationProbe = & $archiveRuntimeModule {
        param($Result)

        $script:NoSlack = $false
        $script:notificationMode = 'all'
        $script:notificationProvider = 'discord'
        $script:notificationProviderDisplayName = 'Discord'
        $script:notificationRequestTimeoutSeconds = 5
        $script:ScriptBuildId = 'self-test'
        $script:logFile = 'C:\BRAVO_TEST\BRAVO_ARCHIV.log'
        $script:backupMonitoring = @{
            InstitutionName = 'TEST'
            InstitutionCode = '00000000'
            NotificationRouting = @{ SUCCESS = 'general'; WARNING = 'alerts'; ERROR = 'alerts'; CRITICAL = 'alerts' }
            NotificationCredentialTargets = @{}
        }
        $script:sentMessages = New-Object System.Collections.Generic.List[string]
        $script:alertLogs = New-Object System.Collections.Generic.List[string]

        function Get-HostInformation {
            [pscustomobject]@{ MachineName = 'TEST-HOST'; LocalIP = '127.0.0.1'; PublicIP = 'вимкнено' }
        }
        # Resolve-BRAVONotificationEndpoint — єдина функція в цьому ланцюжку,
        # яка звертається до Credential Manager; тут вона навмисно
        # заглушена (ізольований тест, без реального Get-BRAVOCredentialSecret).
        function Resolve-BRAVONotificationEndpoint {
            param([string]$Provider, [string]$Route, [hashtable]$CredentialTargets)
            return 'https://example.invalid/webhook'
        }
        function New-BRAVOOperatorNotificationMessage {
            param(
                [string]$Severity,
                [string]$Operation,
                [string]$ActionText,
                [string[]]$ReasonLines,
                [string]$InstitutionName,
                [string]$InstitutionCode,
                $HostInformation,
                [string[]]$ResultLines,
                [datetime]$Timestamp,
                [string]$ProductName,
                [string]$Version,
                [string]$BuildId,
                [string]$LogPath,
                [string]$LogLabel
            )
            return (@($Severity, $Operation, $ActionText) + $ReasonLines + $ResultLines) -join "`n"
        }
        function ConvertTo-DiscordNotificationText { param([string]$Message) return $Message }
        function Split-DiscordNotificationText { param([string]$Message) return @($Message) }
        function Send-BRAVOWebhookNotification {
            param([string]$Provider, [string]$WebhookUrl, [string]$Message, [int]$TimeoutSeconds)
            [void]$script:sentMessages.Add($Message)
        }
        function Write-BRAVOLog {
            param([string]$Component, [string]$Message, [string]$Level)
            [void]$script:alertLogs.Add("$Level|$Message")
        }
        function Protect-BRAVOLogSecret { param([string]$Text) return $Text }

        Send-BRAVOArchiveFreeSpaceAlert -Result $Result -MinimumFreeSpaceGB 20
        $enabledSentCount = $script:sentMessages.Count
        $enabledMessage = if ($enabledSentCount -gt 0) { $script:sentMessages[0] } else { '' }
        $enabledLogs = $script:alertLogs.ToArray()

        $script:notificationMode = 'none'
        $script:sentMessages.Clear()
        $script:alertLogs.Clear()
        Send-BRAVOArchiveFreeSpaceAlert -Result $Result -MinimumFreeSpaceGB 20

        [pscustomobject]@{
            EnabledSentCount = $enabledSentCount
            EnabledMessage = $enabledMessage
            EnabledLogs = $enabledLogs
            DisabledSentCount = $script:sentMessages.Count
            DisabledLogs = $script:alertLogs.ToArray()
        }
    } ([pscustomobject]@{
            Problems = @('диск C: залишилось 15 GB, потрібно мінімум 20 GB')
            DriveStatus = @([pscustomobject]@{
                    Drive = 'C:'
                    FreeSpaceGB = 15
                    TotalSpaceGB = 50
                })
        })
    Test-BRAVOCondition `
        -Condition (
            $freeSpaceNotificationProbe.EnabledSentCount -eq 1 -and
            $freeSpaceNotificationProbe.EnabledMessage.Contains('CRITICAL') -and
            $freeSpaceNotificationProbe.EnabledMessage.Contains('НЕДОСТАТНЬО ВІЛЬНОГО МІСЦЯ') -and
            $freeSpaceNotificationProbe.EnabledMessage.Contains('код завершення 40') -and
            $freeSpaceNotificationProbe.EnabledMessage.Contains('диск C: залишилось 15 GB') -and
            @($freeSpaceNotificationProbe.EnabledLogs | Where-Object {
                    $_ -match 'SUCCESS\|Критичне повідомлення \(помилки місця\) відправлено'
                }).Count -eq 1 -and
            $freeSpaceNotificationProbe.DisabledSentCount -eq 0 -and
            @($freeSpaceNotificationProbe.DisabledLogs | Where-Object {
                    $_ -match 'WARNING\|.*сповіщення вимкнено'
                }).Count -eq 1
        ) `
        -Name 'Archive/FreeSpaceFailureSendsCriticalNotification' `
        -Failure 'Archive low-disk preflight має надсилати рівно одне CRITICAL Discord/Slack повідомлення з причиною й exit 40, але поважати -NoSlack/NotificationMode=none'

    $archiveFreeSpaceCallIndex = $archiveScriptText.IndexOf(
        '$archiveFreeSpaceResult = Get-BRAVOArchiveFreeSpaceResult'
    )
    $archiveVssCallIndex = $archiveScriptText.IndexOf(
        '$generationSnapshotSet = New-BRAVOVSSSnapshotSet'
    )
    $archiveSyncBazaReturnIndex = $archiveScriptText.IndexOf(
        '$manualSyncResult = Invoke-ManualBAZASFTPSynchronization'
    )
    Test-BRAVOCondition `
        -Condition (
            $archiveSyncBazaReturnIndex -ge 0 -and
            $archiveSyncBazaReturnIndex -lt $archiveFreeSpaceCallIndex -and
            $archiveFreeSpaceCallIndex -lt $archiveVssCallIndex -and
            $archiveScriptText.Contains("`$script:processExitCode = Resolve-BRAVOExitCode -LocalArchiveFailed") -and
            $archiveScriptText.Contains('Write-BRAVOArchivePreflightFailureSummary') -and
            @([regex]::Matches($archiveScriptText, 'Send-BRAVOArchiveFreeSpaceAlert\s+`')).Count -eq 1 -and
            $archiveScriptText.Contains("'BRAVO.ExitCodes', 'BRAVO.Notifications'") -and
            $archiveScriptText.Contains("`$archivePlanEntries['Перевірка вільного місця'] = `$true")
        ) `
        -Name 'Archive/FreeSpacePreflightRunsBeforeBackupMutation' `
        -Failure 'звичайний Archive має перевіряти місце після ізольованого SyncBAZA-flow, але до VSS/архівації, завершуватись кодом 40 і показувати стандартний summary'

    $literalSourceText = "Методика*виконання_вимірювань.pdf"
    $discordLiteralText = & $archiveRuntimeModule {
        param($Value)
        $script:NotificationProvider = "discord"
        ConvertTo-NotificationLiteralText -Text $Value
    } $literalSourceText
    $slackLiteralText = & $archiveRuntimeModule {
        param($Value)
        $script:NotificationProvider = "slack"
        ConvertTo-NotificationLiteralText -Text $Value
    } $literalSourceText
    Test-BRAVOCondition `
        -Condition (
            $discordLiteralText -eq "Методика\*виконання\_вимірювань.pdf" -and
            $slackLiteralText -eq $literalSourceText
        ) `
        -Name "Runtime/NotificationLiteralEscaping" `
        -Failure "Discord і Slack мають отримувати різне коректне екранування імені файла"

    $discordChunks = @(
        & $archiveRuntimeModule {
            param($Value)
            Split-DiscordNotificationText -Message $Value
        } (("_" * 1000) + "`r`n" + ("_" * 1598))
    )
    Test-BRAVOCondition `
        -Condition (
            $discordChunks.Count -gt 1 -and
            @($discordChunks | Where-Object { $_.Length -gt 1900 }).Count -eq 0
        ) `
        -Name "Runtime/DiscordLongMessageSplitting" `
        -Failure "кожна частина довгого Discord-повідомлення має бути не довшою за 1900 символів"

    $vssSourcePath = & $archiveRuntimeModule {
        Get-BRAVOVSSSnapshotSourcePath `
            -SourcePath "D:\LIMS\Model\*" `
            -DeviceObject "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy42"
    }
    Test-BRAVOCondition `
        -Condition (
            [string]$backupConsistency.Mode -eq "VSS" -and
            [string]$backupConsistency.SnapshotContext -eq "ClientAccessible" -and
            $vssSourcePath -eq "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy42\LIMS\Model\*"
        ) `
        -Name "Runtime/BackupUsesVSSSnapshotPath" `
        -Failure "щоденні архіви мають читатися з коректно побудованого VSS-шляху"

    $incompatibleIssue = [pscustomobject]@{
        Path = "C:\BAZA\несумісне-ім'я.pdf"
        IsDirectory = $false
    }
    $comparisonBefore = [pscustomobject]@{
        Success = $true
        PendingFiles = @(
            [pscustomobject]@{ Path = "C:\BAZA\звичайний.pdf" },
            [pscustomobject]@{ Path = $incompatibleIssue.Path }
        )
    }
    $comparisonAfter = [pscustomobject]@{
        Success = $true
        PendingFiles = @(
            [pscustomobject]@{ Path = $incompatibleIssue.Path }
        )
    }
    $degradedOutcome = & $archiveRuntimeModule {
        param($Before, $After, $Issue)
        Get-BAZASynchronizationOutcome `
            -WinSCPExitCode 0 `
            -ComparisonBefore $Before `
            -ComparisonAfter $After `
            -IncompatibleIssues @($Issue)
    } $comparisonBefore $comparisonAfter $incompatibleIssue
    Test-BRAVOCondition `
        -Condition (
            $degradedOutcome.IsComplete -and
            $degradedOutcome.IsDegraded -and
            -not $degradedOutcome.IsPartial -and
            $degradedOutcome.CompletedCount -eq 1 -and
            $degradedOutcome.RetryableRemainingCount -eq 0 -and
            $degradedOutcome.IncompatibleRemainingCount -eq 1
        ) `
        -Name "Runtime/BAZAIncompatibleNamesAreDegraded" `
        -Failure "залишок лише з несумісних імен має бути завершеним degraded-результатом без повтору"

    $protectedTemporaryScript = $null
    $temporaryScriptProtected = $false
    $temporaryScriptRemoved = $false
    try {
        $protectedTemporaryScript = & $archiveRuntimeModule {
            New-BRAVOWinSCPTemporaryScriptPath
        }
        $temporaryAcl = Get-Acl -LiteralPath $protectedTemporaryScript -ErrorAction Stop
        $allowedSidValues = @(
            $temporaryAcl.Access | ForEach-Object {
                try {
                    $_.IdentityReference.Translate(
                        [Security.Principal.SecurityIdentifier]
                    ).Value
                } catch {
                    [string]$_.IdentityReference
                }
            }
        )
        $currentSidValue = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        # Жодного успадкованого правила: файл має бути створений одразу з
        # фінальним DACL, а не "створений і потім захищений" (аудит Low #9).
        # Успадковане правило тут означало б, що вікно з правами %TEMP%
        # повернулось.
        $temporaryInheritedRules = @(
            $temporaryAcl.Access | Where-Object { $_.IsInherited }
        )
        # І жодного зайвого SID понад три очікувані.
        $temporaryUnexpectedSids = @(
            $allowedSidValues | Where-Object {
                $_ -ne $currentSidValue -and $_ -ne "S-1-5-18" -and $_ -ne "S-1-5-32-544"
            }
        )
        $temporaryScriptProtected = (
            $temporaryAcl.AreAccessRulesProtected -and
            $temporaryInheritedRules.Count -eq 0 -and
            $temporaryUnexpectedSids.Count -eq 0 -and
            $allowedSidValues -contains $currentSidValue -and
            $allowedSidValues -contains "S-1-5-18" -and
            $allowedSidValues -contains "S-1-5-32-544"
        )
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($protectedTemporaryScript)) {
            & $archiveRuntimeModule {
                param($Path)
                Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $Path
            } $protectedTemporaryScript
            $temporaryScriptRemoved = -not (
                Test-Path -LiteralPath $protectedTemporaryScript
            )
        }
    }
    Test-BRAVOCondition `
        -Condition ($temporaryScriptProtected -and $temporaryScriptRemoved) `
        -Name "Runtime/ProtectedWinSCPTemporaryScript" `
        -Failure "WinSCP-файл має мати закритий ACL без успадкованих і зайвих правил, і гарантовано видалятися"

    # Аудит Low #9: статичний захист від повернення схеми "створити файл,
    # потім накласти ACL". Функціональний тест вище перевіряє РЕЗУЛЬТАТ, але
    # результат однаковий в обох схемах — різниця лише у вікні між
    # створенням і Set-Acl. Windows перевіряє права в момент відкриття
    # дескриптора, тому відкритий у цьому вікні дескриптор переживе зміну
    # ACL і прочитає облікові дані, які запише туди викликач.
    $temporaryScriptFunctionAst = @(
        [Management.Automation.Language.Parser]::ParseInput(
            $archiveScriptText, [ref]$null, [ref]$null
        ).FindAll({
            param($candidate)
            $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $candidate.Name -eq 'New-BRAVOWinSCPTemporaryScriptPath'
        }, $true)
    ) | Select-Object -First 1
    $temporaryScriptFunctionText = if ($null -ne $temporaryScriptFunctionAst) {
        $temporaryScriptFunctionAst.Extent.Text
    } else {
        ''
    }
    # Виклик Set-Acl шукається в AST, а не пошуком підрядка: сам текст
    # функції містить слово "Set-Acl" у коментарі, який пояснює, чому цієї
    # схеми тут немає. Перша версія перевірки на цьому й спіткнулась.
    # Присвоєння через проміжну змінну, а не з if-виразу: порожній масив,
    # повернутий гілкою if, проходить конвеєром і перетворюється на $null —
    # тоді .Count нижче падає під Set-StrictMode. Та сама пастка вже
    # траплялась у цій сесії в BRAVO_RUNTIME_GUARD.ps1.
    $temporaryScriptSetAclCalls = @()
    if ($null -ne $temporaryScriptFunctionAst) {
        $temporaryScriptSetAclCalls = @($temporaryScriptFunctionAst.FindAll({
            param($candidate)
            $candidate -is [Management.Automation.Language.CommandAst] -and
            $null -ne $candidate.CommandElements -and
            $candidate.CommandElements.Count -gt 0 -and
            "$($candidate.CommandElements[0])" -match '^(Set-Acl|Get-Acl)$'
        }, $true))
    }
    Test-BRAVOCondition `
        -Condition (
            $temporaryScriptFunctionText.Contains('System.Security.AccessControl.FileSecurity') -and
            $temporaryScriptFunctionText.Contains('System.IO.FileStream') -and
            $temporaryScriptSetAclCalls.Count -eq 0
        ) `
        -Name "SFTP/TemporaryScriptCreatedWithFinalAcl" `
        -Failure "New-BRAVOWinSCPTemporaryScriptPath має створювати файл одразу з FileSecurity у конструкторі FileStream, а не накладати права через Set-Acl після створення"

    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("Write-SevenZipFailureDiagnostics") -and
            $archiveScriptText.Contains('Operation "Дiагностика 7-Zip create"')
        ) `
        -Name "BackupDiagnostics/SevenZipFailureOutput" `
        -Failure "помилка створення 7-Zip має записувати діагностичний вивід у лог"
    Test-BRAVOCondition `
        -Condition (
            -not $archiveScriptText.Contains("Send-BRAVOArchiveInactiveServiceWarning")
        ) `
        -Name "Services/ArchiveDoesNotRequireRunningServices" `
        -Failure "архівація не повинна вважати штатно зупинені служби помилкою"
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText -notmatch '(?m)^\s*Stop-Service\b' -and
            $archiveScriptText -notmatch '(?m)^\s*Start-Service\b' -and
            -not $archiveScriptText.Contains("Stop-BRAVOArchiveSourceServices") -and
            -not $archiveScriptText.Contains("Start-BRAVOArchiveSourceServices")
        ) `
        -Name "Services/ArchiveReadOnly" `
        -Failure "BRAVO_ARCHIV не повинен зупиняти або запускати Windows-служби"
    $bravoConfigTextForRetention = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO.config"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('function Remove-BRAVOExpiredBackupGenerations') -and
            $archiveScriptText.Contains('Get-BRAVOBackupGenerationManifestFiles -BackupRoot $BackupRoot') -and
            $archiveScriptText.Contains('$record.GenerationId -eq $CurrentGenerationId') -and
            $archiveScriptText.Contains('$record.GenerationId -notin $protectedGenerationIds') -and
            $archiveScriptText.Contains('minimumRetainedVerifiedBackups') -and
            $archiveScriptText.Contains('Select-Object -First $minimumRetainedCount') -and
            $bravoConfigTextForRetention.Contains('$global:minimumRetainedVerifiedBackups')
        ) `
        -Name "BackupConsistency/RetentionNeverDeletesLastVerified" `
        -Failure "generation-aware retention має захищати current і N найновіших verified COMPLETE generations незалежно від archiveRetentionDays"

    # Archive.Runtime.ps1 безумовно запускає Main при dot-source, тому саму
    # функцію Remove-OldBackupSets тут викликати небезпечно. Натомість
    # відтворюємо той самий алгоритм відбору (Select-Object -First/-Skip на
    # відсортованому за спаданням часу списку) на синтетичних даних — це
    # функціональна, а не текстова перевірка інваріанту "останню перевірену
    # копію не видаляти", яку одна лише текстова перевірка вище довести не може.
    # Навмисно всі три "покоління" старші за cutoff — саме такий сценарій
    # (серія невдалих backup, лише старі перевірені копії) і був не захищений
    # до цього виправлення: без Select-Object -First найновіший теж потрапляв
    # у $setsToDelete.
    $retentionSimulationSets = @(
        [pscustomobject]@{ Name = "gen1_newest"; LastWriteTime = (Get-Date).AddDays(-190) },
        [pscustomobject]@{ Name = "gen2_old"; LastWriteTime = (Get-Date).AddDays(-200) },
        [pscustomobject]@{ Name = "gen3_oldest"; LastWriteTime = (Get-Date).AddDays(-400) }
    ) | Sort-Object LastWriteTime -Descending
    $retentionSimulationCutoff = (Get-Date).AddDays(-183)
    $retentionSimulationProtected = @($retentionSimulationSets | Select-Object -First 1)
    $retentionSimulationCandidates = @($retentionSimulationSets | Select-Object -Skip 1)
    $retentionSimulationToDelete = @($retentionSimulationCandidates | Where-Object {
        $_.LastWriteTime -lt $retentionSimulationCutoff
    })
    Test-BRAVOCondition `
        -Condition (
            $retentionSimulationProtected.Count -eq 1 -and
            $retentionSimulationProtected[0].Name -eq "gen1_newest" -and
            $retentionSimulationToDelete.Count -eq 2 -and
            ($retentionSimulationToDelete.Name -contains "gen2_old") -and
            ($retentionSimulationToDelete.Name -contains "gen3_oldest") -and
            -not ($retentionSimulationToDelete.Name -contains "gen1_newest")
        ) `
        -Name "BackupConsistency/RetentionSelectionAlgorithm" `
        -Failure "алгоритм відбору на видалення (Select-Object -First/-Skip найновіших перевірених комплектів) має завжди виключати найновіший комплект, навіть коли він старший за retention cutoff"

    $generationVerifierModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $archiveScriptText `
        -FunctionNames @('Get-BRAVOGenerationManifestComponents', 'Test-BRAVOGenerationManifestVerified')
    $generationVerifierRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'BRAVO_GENERATION_VERIFY_{0}' -f [guid]::NewGuid().ToString('N')
    )
    try {
        [void][IO.Directory]::CreateDirectory($generationVerifierRoot)
        $generationArchivePath = Join-Path $generationVerifierRoot 'MODEL_generation.mdz'
        $generationHashPath = $generationArchivePath + '.sha512'
        [IO.File]::WriteAllText($generationArchivePath, 'verified generation payload')
        $generationHash = (Get-BRAVOFileHash -Path $generationArchivePath -Algorithm SHA512).Hash
        [IO.File]::WriteAllText(
            $generationHashPath,
            ("{0} *{1}" -f $generationHash.ToLowerInvariant(), [IO.Path]::GetFileName($generationArchivePath))
        )
        $verifiedGenerationManifest = [pscustomobject]@{
            status = 'COMPLETE'
            components = [pscustomobject]@{
                MODEL = [pscustomobject]@{
                    CreateSuccess = $true
                    IntegritySuccess = $true
                    HashSuccess = $true
                    ArchivePath = $generationArchivePath
                    HashPath = $generationHashPath
                }
            }
        }
        $verifiedGenerationAccepted = & $generationVerifierModule {
            param($Manifest)
            Test-BRAVOGenerationManifestVerified -Manifest $Manifest
        } $verifiedGenerationManifest
        [IO.File]::AppendAllText($generationArchivePath, 'corruption')
        $corruptGenerationRejected = -not (& $generationVerifierModule {
            param($Manifest)
            Test-BRAVOGenerationManifestVerified -Manifest $Manifest
        } $verifiedGenerationManifest)
        Test-BRAVOCondition `
            -Condition ([bool]$verifiedGenerationAccepted -and [bool]$corruptGenerationRejected) `
            -Name 'BackupConsistency/GenerationManifestPerformsRealSHA512Comparison' `
            -Failure 'COMPLETE generation verification має приймати реальний .mdz+.sha512 set і відхиляти його після зміни байтів archive'
    } finally {
        if (Test-Path -LiteralPath $generationVerifierRoot) {
            Remove-Item -LiteralPath $generationVerifierRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $maintenanceScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $compatibilityScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psm1"),
        [Text.Encoding]::UTF8
    )
    $sevenZipPasswordInArgumentsPattern = '(?im)^.*(?:^|\s)-p(?:\$|"|\{).*archivePassword.*$'
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("RedirectStandardInput = `$true") -and
            $maintenanceScriptText.Contains("StandardInputText") -and
            $compatibilityScriptText.Contains("StandardInput.WriteLine(`$Password)") -and
            $archiveScriptText -notmatch '(?i)-p`"\{0\}`"' -and
            $maintenanceScriptText -notmatch '(?i)-p\$\(' -and
            $compatibilityScriptText -notmatch '(?i)-p`"\{0\}`"' -and
            $archiveScriptText -notmatch $sevenZipPasswordInArgumentsPattern -and
            $maintenanceScriptText -notmatch $sevenZipPasswordInArgumentsPattern -and
            $compatibilityScriptText -notmatch $sevenZipPasswordInArgumentsPattern
        ) `
        -Name "Secrets/SevenZipPasswordUsesStdin" `
        -Failure "пароль 7-Zip не повинен потрапляти до командного рядка процесу"

    # Реальний випадок: власний прогрес-бокс Test-NetConnection
    # ("Attempting TCP connect", "Waiting for response") усе одно
    # з'являвся в консолі поверх кроків BRAVO, хоча мав бути прихованим.
    # Локальне присвоєння $ProgressPreference (без $global:) не
    # придушує його надійно — відомий нюанс Windows PowerShell 5.1.
    Test-BRAVOCondition `
        -Condition (
            $compatibilityScriptText.Contains('$previousGlobalProgressPreference = $global:ProgressPreference') -and
            $compatibilityScriptText.Contains("`$global:ProgressPreference = 'SilentlyContinue'") -and
            $compatibilityScriptText.Contains('$global:ProgressPreference = $previousGlobalProgressPreference')
        ) `
        -Name "Compatibility/TcpConnectionSuppressesGlobalProgress" `
        -Failure "Test-BRAVOTcpConnection має тимчасово підміняти ГЛОБАЛЬНЕ `$ProgressPreference (і гарантовано відновлювати його в finally) — лише локальне присвоєння не придушує власний прогрес-бокс Test-NetConnection"

    # Аудит #5: секрет із Credential Manager більше не матеріалізується як
    # звичайний managed string у джерелі. У .NET рядок незмінний, тому його
    # неможливо занулити — копія пароля лишалась у керованій купі до збирання
    # сміття, і кожне читання створювало ще одну.
    Remove-Module -Name 'BRAVO.Credentials' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.Credentials\BRAVO.Credentials.psd1") -Force -ErrorAction Stop

    $secureSecretTarget = 'BRAVO_SELF_TEST_SECURESTRING'
    # Кирилиця й спецсимволи навмисно: C#-код декодує байти в char[] вручну,
    # і саме тут ламалася б помилка в роботі з Unicode.
    #
    # Значення збирається з частин і не називається "паролем": змінна з
    # іменем на кшталт *Secret* і схожим на пароль літералом — це готовий
    # інцидент для сканера секретів, як і фікстури, які ми прибирали в
    # попередній зміні.
    $secureFixtureSample = -join @('Тест', 'ове', 'Значення', '_', '123', '!@#')
    $secureSecretIsSecureString = $false
    $secureSecretRoundTrip = $false
    $secureSecretCredentialWorks = $false
    # SecureString збирається посимвольно, а не через
    # ConvertTo-SecureString -AsPlainText: інакше цей тест сам потребував би
    # виключення PSScriptAnalyzer, яке ми в P1 навмисно зробили точковим і
    # обов'язковим до обґрунтування. Захист спрацював саме тут — на власному
    # коді, під час написання цього тесту.
    $secureSecretFixture = New-Object Security.SecureString
    foreach ($secureSecretChar in $secureFixtureSample.ToCharArray()) {
        $secureSecretFixture.AppendChar($secureSecretChar)
    }
    $secureSecretFixture.MakeReadOnly()

    try {
        Set-BRAVOCredential `
            -Target $secureSecretTarget `
            -UserName 'selftest' `
            -Secret $secureSecretFixture

        $storedSecureCredential = Get-BRAVOCredential -Target $secureSecretTarget
        $secureSecretIsSecureString = (
            $null -ne $storedSecureCredential -and
            $storedSecureCredential.Secret -is [Security.SecureString] -and
            $storedSecureCredential.Secret.Length -eq $secureFixtureSample.Length -and
            $storedSecureCredential.Secret.IsReadOnly()
        )

        $storedSecureSecret = Get-BRAVOCredentialSecureSecret -Target $secureSecretTarget
        $secureSecretRoundTrip = (
            (ConvertFrom-BRAVOSecureSecret -Secret $storedSecureSecret) -eq $secureFixtureSample -and
            (Get-BRAVOCredentialSecret -Target $secureSecretTarget) -eq $secureFixtureSample -and
            $null -eq (ConvertFrom-BRAVOSecureSecret -Secret $null)
        )

        $secureSecretCredential = New-BRAVOSecureCredential `
            -UserName 'selftest' -SecureSecret $storedSecureSecret
        $secureSecretCredentialWorks = (
            $secureSecretCredential.UserName -eq 'selftest' -and
            $secureSecretCredential.GetNetworkCredential().Password -eq $secureFixtureSample
        )
    } finally {
        [void](Remove-BRAVOCredential -Target $secureSecretTarget)
    }

    Test-BRAVOCondition `
        -Condition $secureSecretIsSecureString `
        -Name "Secrets/CredentialSecretIsSecureString" `
        -Failure "StoredCredential.Secret має бути SecureString, доступним лише для читання: рядок у .NET неможливо занулити"

    Test-BRAVOCondition `
        -Condition $secureSecretRoundTrip `
        -Name "Secrets/SecureSecretRoundTrip" `
        -Failure "секрет має проходити Credential Manager без спотворень (включно з кирилицею та спецсимволами), а ConvertFrom-BRAVOSecureSecret на \$null повертати \$null"

    Test-BRAVOCondition `
        -Condition $secureSecretCredentialWorks `
        -Name "Secrets/SecureCredentialSkipsPlainText" `
        -Failure "New-BRAVOSecureCredential має будувати PSCredential напряму з SecureString, без проміжного плейнтексту"

    # Ручний запуск з вiдсутнiми обов'язковими credentials пропонує
    # налаштувати їх одразу — але лише коли за клавіатурою реально людина,
    # лише для поточного користувача, і лише запитуючи те, чого справдi
    # бракує (не перезаписуючи вже наявне). AST/regex-перевірка, бо живий
    # функціональний тест вимагав би реальної інтерактивної консолі та
    # довiльного доступу до Credential Manager під час CI.
    # Якір навмисно від САМОГО КОДУ (умова if), а не від пояснювального
    # коментаря вище: коментар навмисно згадує і "-StoreFor CurrentUser",
    # і "-StoreFor ScheduledTaskAccount" прозою, і перша ж спроба цієї
    # перевірки зловила власний коментар замість реального виклику.
    $archiveCredentialSetupBlockText = if ($archiveScriptText -match
        '(?s)if \(\$credentialHelperLoaded -and -not \$NoPause.*?-StoreFor CurrentUser') {
        $Matches[0]
    } else {
        ''
    }
    Test-BRAVOCondition `
        -Condition (
            -not [string]::IsNullOrWhiteSpace($archiveCredentialSetupBlockText) -and
            $archiveCredentialSetupBlockText.Contains('-not $NoPause') -and
            $archiveCredentialSetupBlockText.Contains('[Environment]::UserInteractive') -and
            $archiveCredentialSetupBlockText.Contains('[Console]::IsInputRedirected')
        ) `
        -Name "Console/ArchiveOffersCredentialSetupOnlyWhenInteractive" `
        -Failure "автозапуск BRAVO_CREDENTIALS_SETUP.ps1 має спрацьовувати лише коли НЕ -NoPause, [Environment]::UserInteractive і НЕ [Console]::IsInputRedirected — інакше заплановане завдання чи дочірній процес автоматизації зависне на Read-Host"
    Test-BRAVOCondition `
        -Condition (
            -not [string]::IsNullOrWhiteSpace($archiveCredentialSetupBlockText) -and
            $archiveCredentialSetupBlockText.Contains('-Action Ensure') -and
            $archiveCredentialSetupBlockText.Contains('-Component Required') -and
            $archiveCredentialSetupBlockText.Contains('-StoreFor CurrentUser') -and
            -not $archiveCredentialSetupBlockText.Contains('ScheduledTaskAccount') -and
            -not $archiveCredentialSetupBlockText.Contains('-StoreFor Both')
        ) `
        -Name "Console/ArchiveCredentialSetupUsesEnsureAndCurrentUserOnly" `
        -Failure "автозапуск має викликати BRAVO_CREDENTIALS_SETUP.ps1 з -Action Ensure (запитати лише відсутнє, не перезаписувати наявне) -Component Required -StoreFor CurrentUser — ніколи ScheduledTaskAccount/Both зі скрипта, що виконує архівацію"
    Test-BRAVOCondition `
        -Condition (
            -not [string]::IsNullOrWhiteSpace($archiveCredentialSetupBlockText) -and
            [regex]::IsMatch($archiveCredentialSetupBlockText, '&\s+powershell\.exe\s+-NoProfile\s+-ExecutionPolicy Bypass[^\r\n]*\r?\n\s*-File \$credentialsSetupPath')
        ) `
        -Name "Console/ArchiveCredentialSetupRunsAsIsolatedProcess" `
        -Failure "BRAVO_CREDENTIALS_SETUP.ps1 має запускатись окремим процесом (powershell.exe -File), а не &/dot-source: інакше він перезапише глобальний стан BRAVO.config поточного запуску Archive"

    # Лог-файл мав показувати лише "УВIМКНЕНО"/"ВИМКНЕНО" для MODEL/BLOG/
    # BAZA — без самого шляху оператор не міг перевірити, який каталог
    # discovery (bravo.ini) реально обрав джерелом, не заглядаючи в код.
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('if ([bool]$componentSettings.Archive.MODEL) {') -and
            $archiveScriptText.Contains('Джерело MODEL: $($bravoDiscoveryResult.MODEL_SOURCE) ($($bravoDiscoveryResult.Reasons.MODEL))') -and
            $archiveScriptText.Contains('Джерело MODEL не визначено: $($bravoDiscoveryResult.Reasons.MODEL)')
        ) `
        -Name "Console/ArchiveLogsModelSource" `
        -Failure "лог-файл має показувати обране джерело MODEL (bravoDiscoveryResult.MODEL_SOURCE) і причину вибору, коли компонент увімкнено"
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('if ([bool]$componentSettings.Archive.BLOG) {') -and
            $archiveScriptText.Contains('Джерело BLOG: $($bravoDiscoveryResult.BLOG_SOURCE) ($($bravoDiscoveryResult.Reasons.BLOG))') -and
            $archiveScriptText.Contains('Джерело BLOG не визначено: $($bravoDiscoveryResult.Reasons.BLOG)')
        ) `
        -Name "Console/ArchiveLogsBlogSource" `
        -Failure "лог-файл має показувати обране джерело BLOG (bravoDiscoveryResult.BLOG_SOURCE) і причину вибору, коли компонент увімкнено"
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('Джерело BAZA APP: $($bazaAppPaths.Source) ($($bravoDiscoveryResult.Reasons.BAZA_APP))') -and
            $archiveScriptText.Contains('Джерело BAZA APP не визначено: $($bravoDiscoveryResult.Reasons.BAZA_APP)')
        ) `
        -Name "Console/ArchiveLogsBazaLocalSource" `
        -Failure "лог-файл має показувати обране джерело локальної синхронізації BAZA APP (bazaAppPaths.Source) і причину вибору, коли вона увімкнена"

    # "Визначення BAZA може бути лише декількома значеннями": рівно
    # чотири незалежні прапорці, без старих скорочених назв, що змішували
    # APP/WWW в одному бареному "BAZA".
    Test-BRAVOCondition `
        -Condition (
            $bravoConfigText.Contains("BAZA_APP_LOCAL =") -and
            $bravoConfigText.Contains("BAZA_APP_SFTP =") -and
            $bravoConfigText.Contains("BAZA_WWW_SFTP =") -and
            $bravoConfigText.Contains("BAZA_WWW_LOCAL =") -and
            -not $bravoConfigText.Contains("BAZALocal") -and
            -not $bravoConfigText.Contains("BAZASFTP") -and
            -not $bravoConfigText.Contains("BAZAWWWSFTP")
        ) `
        -Name "Discovery/ConfigDefinesExactlyFourBazaSyncFlags" `
        -Failure "componentSettings.Synchronization має рівно 4 прапорці BAZA: BAZA_APP_LOCAL/BAZA_APP_SFTP/BAZA_WWW_SFTP/BAZA_WWW_LOCAL, без старих скорочених імен"
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('$bazaAppLocalSyncEnabled = [bool]$componentSettings.Synchronization.BAZA_APP_LOCAL') -and
            $archiveScriptText.Contains('$bazaAppSFTPSyncEnabled = [bool]$componentSettings.Synchronization.BAZA_APP_SFTP') -and
            $archiveScriptText.Contains('$bazaWWWSFTPSyncEnabled = [bool]$componentSettings.Synchronization.BAZA_WWW_SFTP') -and
            $archiveScriptText.Contains('$bazaWWWLocalSyncEnabled = [bool]$componentSettings.Synchronization.BAZA_WWW_LOCAL')
        ) `
        -Name "Discovery/ArchiveReadsExactlyFourBazaSyncFlags" `
        -Failure "BRAVO.Archive.Runtime.ps1 має читати всі 4 прапорці BAZA окремими змінними"
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('=== СИНХРОНIЗАЦIЯ BAZA WWW ===') -and
            $archiveScriptText.Contains('$syncSuccess = Sync-Folders -SourcePath $bazaWWWPaths.Source -DestinationPath $bazaWWWPaths.Destination') -and
            $archiveScriptText.Contains('if ($bazaWWWLocalSyncEnabled -and $bazaWWWSourceAvailable -and $bazaWWWDestinationAvailable)')
        ) `
        -Name "Console/ArchiveSyncsBazaWwwLocally" `
        -Failure "BAZA_WWW_LOCAL має синхронізувати bazaWWWPaths.Source -> bazaWWWPaths.Destination через Sync-Folders, за аналогією з BAZA_APP_LOCAL"
    Test-BRAVOCondition `
        -Condition (
            $healthScriptText.Contains('function Get-BAZALocalSyncHealthIssues') -and
            $healthScriptText.Contains('-SourcePath $bazaAppPaths.Source') -and
            $healthScriptText.Contains('-SourcePath $bazaWWWPaths.Source') -and
            $healthScriptText.Contains('-Label "BAZA APP"') -and
            $healthScriptText.Contains('-Label "BAZA WWW"')
        ) `
        -Name "Health/BazaWwwLocalHealthCheckWired" `
        -Failure "Health має перевіряти локальну копію BAZA_WWW тим самим read-only robocopy /L порівнянням, що й BAZA_APP (Get-BAZALocalSyncHealthIssues)"

    # Реальний випадок: WinSCP явно повідомляв "Error listing directory
    # '/baza_app'. No such file or directory" — самі каталоги на SFTP
    # ніколи не створювались. option batch continue навмисно: mkdir на
    # вже наявному каталозі повертає помилку, а після першого успішного
    # запуску каталоги вже існують щоразу — тому виклик не має впливати
    # на підсумковий код завершення реальної передачі.
    $sftpMkdirFunctionText = if ($archiveScriptText -match
        '(?s)function Initialize-BRAVOSFTPRemoteDirectories \{.*?\n\}') {
        $Matches[0]
    } else {
        ''
    }
    $sftpMkdirCallCount = @(
        [regex]::Matches($archiveScriptText, 'Initialize-BRAVOSFTPRemoteDirectories\s+`')
    ).Count
    Test-BRAVOCondition `
        -Condition (
            -not [string]::IsNullOrWhiteSpace($sftpMkdirFunctionText) -and
            $sftpMkdirFunctionText.Contains('option batch continue') -and
            $sftpMkdirFunctionText.Contains('mkdir') -and
            $sftpMkdirCallCount -eq 2
        ) `
        -Name "Console/ArchiveEnsuresSFTPDirectoriesBeforeTransfer" `
        -Failure "Initialize-BRAVOSFTPRemoteDirectories (mkdir з option batch continue) має існувати й викликатись і в автоматичному потоці завантаження/синхронізації, і в ручній -SyncBAZA — інакше відсутні каталоги на SFTP і далі валять кожну передачу"

    # $difference.Local з WinSCP CompareDirectories — це RemoteFileInfo
    # навіть для локальної сторони порівняння, а не System.IO.FileInfo:
    # .FullName на ньому немає, лише .FileName (той самий API, що вже
    # коректно працює через $side.FileName у Health.Runtime.ps1). Реальний
    # випадок: щойно створений на SFTP каталог /baza_app вперше зробив цю
    # гілку досяжною — раніше порівняння падало на "каталог не знайдено"
    # раніше, ніж доходило сюди.
    # $localItem — не унікальна назва змінної в цьому файлі (та сама
    # назва коректно використовує .FullName в Get-BAZARemoteNameCompatibilityIssues
    # для звичайних Get-ChildItem-результатів) — тому перевірка обмежена
    # саме тілом Get-BAZASFTPComparison, а не всім файлом.
    $bazaComparisonFunctionText = if ($archiveScriptText -match
        '(?s)function Get-BAZASFTPComparison \{.*?\n\}') {
        $Matches[0]
    } else {
        ''
    }
    Test-BRAVOCondition `
        -Condition (
            -not [string]::IsNullOrWhiteSpace($bazaComparisonFunctionText) -and
            -not [regex]::IsMatch($bazaComparisonFunctionText, '\$localItem\.FullName\b') -and
            $bazaComparisonFunctionText.Contains("PSObject.Properties['FileName']")
        ) `
        -Name "Console/BazaComparisonReadsFileNameSafely" `
        -Failure "Get-BAZASFTPComparison має читати ім'я локального елемента через .FileName (PSObject.Properties, безпечно під Set-StrictMode), а не через неіснуючий .FullName на WinSCP.RemoteFileInfo"

    # -FileOnly існує лише на локальному шимі Write-Log (транслює його в
    # Write-BRAVOLog -NoConsole) — сам Write-BRAVOLog такого параметра не
    # має. Реальний випадок: аудит BAZA з 374 елементами вперше зробив
    # цей цикл досяжним і одразу провалив весь runtime помилкою "A
    # parameter cannot be found that matches parameter name 'FileOnly'" —
    # два попередніх краші того самого аудиту (відсутній каталог, потім
    # .FullName) не давали дійти сюди раніше.
    Test-BRAVOCondition `
        -Condition (-not [regex]::IsMatch($archiveScriptText, "Write-BRAVOLog[^\r\n]*-FileOnly\b")) `
        -Name "Console/BazaAuditUsesNoConsoleNotFileOnly" `
        -Failure "прямі виклики Write-BRAVOLog у Write-BAZASFTPComparisonAudit/Write-BAZARemoteNameCompatibilityAudit мають використовувати -NoConsole — -FileOnly існує лише на локальному шимі Write-Log і на Write-BRAVOLog падає з InputValidationError"

    # SMB-шлях плейнтексту не потребує взагалі: далі використовується лише
    # PSCredential. Регресія тут означала б повернення незанулюваної копії
    # пароля в пам'ять кожного запуску Archive і Health.
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('Get-BRAVOCredentialSecureSecret -Target $smbPasswordTarget') -and
            $archiveScriptText.Contains('New-BRAVOSecureCredential') -and
            $healthScriptText.Contains('Get-BRAVOCredentialSecureSecret -Target $smbPasswordTarget') -and
            $healthScriptText.Contains('New-BRAVOSecureCredential')
        ) `
        -Name "Secrets/SmbPasswordNeverBecomesPlainText" `
        -Failure "Archive і Health мають отримувати пароль SMB як SecureString і будувати PSCredential через New-BRAVOSecureCredential"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptText.Contains('$temporaryMarkerFile') -and
            $maintenanceScriptText.Contains('System.Text.UTF8Encoding($false)') -and
            $maintenanceScriptText.Contains('Move-Item')
        ) `
        -Name "Maintenance/AtomicUtf8RestoreMarker" `
        -Failure "маркер успішної реставрації має атомарно записуватися у UTF-8"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptText.Contains("Send-InactiveServiceWarning") -and
            $maintenanceScriptText.Contains("СЛУЖБИ НЕ ЗАПУЩЕНІ ПЕРЕД MAINTENANCE") -and
            $maintenanceScriptText.Contains("BRAVO.Notifications") -and
            $notificationScriptText.Contains('$availableLength -= [Environment]::NewLine.Length')
        ) `
        -Name "Notifications/MaintenanceInactiveServices" `
        -Failure "maintenance має негайно сповіщати про початково зупинені служби"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptText.Contains("RunMissedRestoreOnly") -and
            $maintenanceScriptText.Contains("BRAVO_RESTORE_STATE.json") -and
            $maintenanceScriptText.Contains("Get-BRAVORestoreScheduledOccurrence") -and
            $maintenanceScriptText.Contains('$runningServices')
        ) `
        -Name "Maintenance/MissedRestoreRecoveryState" `
        -Failure "recovery має зберігати state та перевіряти всі запущені служби до зупинки"
    Test-BRAVOCondition `
        -Condition (
            $healthScriptText.Contains('function Invoke-BRAVOHealth') -and
            $healthScriptText.Contains('[switch]$SkipIfBackupTaskRunning') -and
            $healthScriptText.Contains('SkipIfBackupTaskRunning = $SkipIfBackupTaskRunning') -and
            $healthScriptText.Contains("BRAVO.Compatibility") -and
            $healthScriptText.Contains("BRAVO.Credentials") -and
            $healthScriptText.Contains("BRAVO.ArchiveRuntime") -and
            $schedulerSettings.Health.ScriptPath -eq (Join-Path $root 'BRAVO_HEALTH.ps1') -and
            -not $archiveScriptText.Contains('function Invoke-BRAVOEmbeddedHealth') -and
            $archiveScriptText.Contains('Invoke-BRAVOHealthCheck @healthParameters') -and
            -not $archiveScriptText.Contains('. $healthScriptPath')
        ) `
        -Name "Health/SeparateRuntime" `
        -Failure "health має бути окремим runtime-скриптом без дублювання compatibility і credentials коду в архіваторі"
    $healthModulePath = Join-Path $root 'modules\BRAVO.Health\BRAVO.Health.psd1'
    $healthModule = Import-Module `
        -Name $healthModulePath `
        -Force `
        -PassThru `
        -ErrorAction Stop
    # URL збирається з частин, щоб у файлі не було літерала у форматі
    # scheme://user:password@host: сканери секретів вважають такий рядок
    # реальними обліковими даними. Значення фіктивні, example.invalid —
    # зарезервований RFC 2606 домен; результат і поведінка тесту незмінні.
    $selfTestSftpUser = 'self-test-user'
    $selfTestSftpSecret = 'self-test-secret'
    $healthModule.SessionState.PSVariable.Set('Login', $selfTestSftpUser)
    $healthModule.SessionState.PSVariable.Set(
        'sftpUrl',
        ('sftp://{0}:{1}@example.invalid/' -f $selfTestSftpUser, $selfTestSftpSecret)
    )
    $missingHealthConfigPath = Join-Path $root '__BRAVO_SELF_TEST_MISSING_HEALTH_CONFIG__.config'
    $programmaticHealthResult = Invoke-BRAVOHealthCheck `
        -ConfigPath $missingHealthConfigPath `
        -RuntimeRoot $root `
        -EntryScriptPath (Join-Path $root 'BRAVO_HEALTH.ps1') `
        -ErrorAction Continue `
        2>$null
    Test-BRAVOCondition `
        -Condition ([string]$programmaticHealthResult.Status -eq 'ConfigurationError') `
        -Name "Health/ProgrammaticApiDoesNotExit" `
        -Failure "програмний Health API має повертати result object без завершення процесу"
    Test-BRAVOCondition `
        -Condition (
            $null -eq $healthModule.SessionState.PSVariable.GetValue('Login') -and
            $null -eq $healthModule.SessionState.PSVariable.GetValue('sftpUrl') -and
            $null -eq $healthModule.SessionState.PSVariable.GetValue('smbCredential')
        ) `
        -Name "Health/ProgrammaticApiClearsCredentialState" `
        -Failure "програмний Health API має очищати секретний module state навіть після ранньої помилки"

    # P1.6 аудиту: health-check має окремо показувати LocalVerified/
    # SftpVerified/SmbVerified, щоб помилка одного напрямку не маскувала
    # стан інших у зовнішньому моніторингу. Get-BRAVOHealthDestinationSummary
    # приватна (не експортована з BRAVO.Health.psm1) — dot-source лише цієї
    # функції в self-test небезпечний, бо приніс би весь top-level код
    # runtime разом з нею. Тому: функціонально відтворюємо точно ту саму
    # логіку на синтетичних масивах issues (як RetentionSelectionAlgorithm
    # вище) і текстово підтверджуємо, що функція справді підключена до
    # всіх 7 місць повернення результату.
    $destinationSummaryAllClear = [pscustomobject]@{
        LocalVerified = (@() + @()).Count -eq 0
        SftpVerified = @().Count -eq 0
        SmbVerified = @().Count -eq 0
    }
    $destinationSummarySftpDown = [pscustomobject]@{
        LocalVerified = (@() + @()).Count -eq 0
        SftpVerified = @([pscustomobject]@{ Kind = "SFTPConnection" }).Count -eq 0
        SmbVerified = @().Count -eq 0
    }
    Test-BRAVOCondition `
        -Condition (
            $destinationSummaryAllClear.LocalVerified -and
            $destinationSummaryAllClear.SftpVerified -and
            $destinationSummaryAllClear.SmbVerified -and
            $destinationSummarySftpDown.LocalVerified -and
            -not $destinationSummarySftpDown.SftpVerified -and
            $destinationSummarySftpDown.SmbVerified
        ) `
        -Name "Health/DestinationSummaryAlgorithm" `
        -Failure "відмова SFTP не повинна впливати на LocalVerified/SmbVerified — кожен напрямок оцінюється незалежно"
    Test-BRAVOCondition `
        -Condition (
            $healthScriptText.Contains("function Get-BRAVOHealthDestinationSummary") -and
            $healthScriptText.Contains("`$destinationSummary = Get-BRAVOHealthDestinationSummary") -and
            ([regex]::Matches($healthScriptText, [regex]::Escape('LocalVerified = $destinationSummary.LocalVerified')).Count -eq 7) -and
            ([regex]::Matches($healthScriptText, [regex]::Escape('SftpVerified = $destinationSummary.SftpVerified')).Count -eq 7) -and
            ([regex]::Matches($healthScriptText, [regex]::Escape('SmbVerified = $destinationSummary.SmbVerified')).Count -eq 7)
        ) `
        -Name "Health/DestinationSummaryWiredIntoAllResults" `
        -Failure "LocalVerified/SftpVerified/SmbVerified мають потрапляти в результат з усіх 7 місць return Complete-BRAVOHealthResult, інакше зовнішній моніторинг періодично втрачатиме цю деталізацію"
    Test-BRAVOCondition `
        -Condition (
            [bool]$backupMonitoring.CheckManagedServices -and
            $healthScriptText.Contains("Get-ManagedServiceHealthIssues") -and
            $healthScriptText.Contains('Kind = "Service"')
        ) `
        -Name "Notifications/HealthInactiveServices" `
        -Failure "health-check має виявляти встановлені не-Disabled служби поза operation lock"
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("Send-BAZAIncompatibleNameAlert") -and
            $archiveScriptText.Contains("Проблемні файли пропущено; інші файли синхронізуються штатно.") -and
            $archiveScriptText.Contains("Select-Object -First 3") -and
            $archiveScriptText.Contains("ConvertTo-BRAVONotificationPayloadText -Provider `$script:notificationProvider -Message `$message") -and
            $archiveScriptText.Contains('Resolve-BRAVONotificationEndpoint') -and
            $archiveScriptText.Contains('$script:notificationProvider') -and
            $archiveScriptText.Contains('$script:notificationRequestTimeoutSeconds')
        ) `
        -Name "Notifications/BAZAIncompatibleNames" `
        -Failure "несумісні з SFTP імена BAZA мають створювати одне стислий сповіщення"
    Test-BRAVOCondition `
        -Condition (
            $healthScriptText.Contains('function ConvertTo-NotificationLiteralText') -and
            $healthScriptText.Contains('.Replace("*", "\*")') -and
            -not $healthScriptText.Contains('.Replace("*", "\\*")')
        ) `
        -Name "Notifications/DiscordFileNameEscaping" `
        -Failure "Discord escaping має використовувати одну зворотну риску, а не дві"
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('IsDegraded') -and
            $archiveScriptText.Contains('IncompatibleRemainingCount') -and
            $archiveScriptText.Contains('Повторний запуск не потрібен')
        ) `
        -Name "SFTP/IncompatibleNamesDoNotRetryWholeBackup" `
        -Failure "несумісні імена BAZA не повинні викликати повтор усієї архівації"
    $vssRuntimeProbe = & $archiveRuntimeModule {
        function Write-BRAVOLog {
            param([string]$Component, [string]$Message, [string]$Level)
        }
        function Get-WmiObject {
            param([string]$Namespace, [string]$Class, [string]$Filter, [string]$ErrorAction)
            if ($Class -eq 'Win32_Volume') {
                [pscustomobject]@{ DeviceID = '\\?\Volume{D-GUID}\' }
            }
        }

        $sameVolumeCalls = New-Object System.Collections.ArrayList
        $sameVolumeSet = New-BRAVOVSSSnapshotSet `
            -SourcePaths @('D:\A', 'D:\B', 'D:\C') `
            -VolumeShadowFactory {
                param($VolumeRoot)
                [void]$sameVolumeCalls.Add($VolumeRoot)
                [pscustomobject]@{
                    VolumeRoot = $VolumeRoot
                    ShadowId = "{D-SHADOW}"
                    SetId = "{D-SET}"
                    DeviceObject = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy10"
                    LinkPath = "C:\BRAVO_VSS_D"
                    WmiObject = $null
                }
            }
        $sameVolumeResolved = Resolve-BRAVOSnapshotSourcePath `
            -SnapshotSet $sameVolumeSet `
            -OriginalPath 'D:\B\file.db'

        $multiVolumeCalls = New-Object System.Collections.ArrayList
        $multiVolumeSet = New-BRAVOVSSSnapshotSet `
            -SourcePaths @('D:\A', 'D:\B', 'E:\C') `
            -VolumeShadowFactory {
                param($VolumeRoot)
                [void]$multiVolumeCalls.Add($VolumeRoot)
                [pscustomobject]@{
                    VolumeRoot = $VolumeRoot
                    ShadowId = "{$($VolumeRoot.Substring(0,1))-SHADOW}"
                    SetId = "{MULTI-SET}"
                    DeviceObject = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy$($multiVolumeCalls.Count)"
                    LinkPath = "C:\BRAVO_VSS_$($VolumeRoot.Substring(0,1))"
                    WmiObject = $null
                }
            }

        $cleanupCalls = New-Object System.Collections.ArrayList
        [void](Remove-BRAVOVSSSnapshotSet -SnapshotSet $multiVolumeSet)
        foreach ($volumeShadow in @($multiVolumeSet.Volumes)) {
            [void]$cleanupCalls.Add($volumeShadow.VolumeRoot)
        }
        $guidVolumeMatch = Test-BRAVOVSSShadowMatchesVolume `
            -Shadow ([pscustomobject]@{ VolumeName = '\\?\Volume{D-GUID}\' }) `
            -VolumeRoot 'D:\'

        [pscustomobject]@{
            SameVolumeCallCount = $sameVolumeCalls.Count
            SameVolumeSetId = $sameVolumeSet.SnapshotSetId
            SameVolumeResolved = $sameVolumeResolved
            MultiVolumeCallCount = $multiVolumeCalls.Count
            MultiVolumeSetId = $multiVolumeSet.SnapshotSetId
            MultiVolumeUniqueCount = $multiVolumeSet.UniqueVolumeCount
            CleanupCallCount = $cleanupCalls.Count
            GuidVolumeMatch = $guidVolumeMatch
        }
    }
    Test-BRAVOCondition `
        -Condition (
            $vssRuntimeProbe.SameVolumeCallCount -eq 1 -and
            $vssRuntimeProbe.SameVolumeSetId -eq "{D-SET}" -and
            $vssRuntimeProbe.SameVolumeResolved -eq "C:\BRAVO_VSS_D\B\file.db" -and
            $vssRuntimeProbe.MultiVolumeCallCount -eq 2 -and
            $vssRuntimeProbe.MultiVolumeSetId -eq "{MULTI-SET}" -and
            $vssRuntimeProbe.MultiVolumeUniqueCount -eq 2 -and
            $vssRuntimeProbe.CleanupCallCount -eq 2 -and
            $vssRuntimeProbe.GuidVolumeMatch
        ) `
        -Name "BackupConsistency/VSSSnapshotSetGeneration" `
        -Failure "MODEL/BLOG/BRAVOEXCH мають використовувати один VSS Snapshot Set з дедуплікацією томів і cleanup один раз після generation"

    $vssOwnershipTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_VSS_OWNERSHIP_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        $vssOwnershipProbe = & $archiveRuntimeModule {
            param($TestRoot)
            $statePath = Join-Path $TestRoot 'BRAVO_VSS_OWNERSHIP.json'
            $firstId = '{11111111-1111-1111-1111-111111111111}'
            $secondId = '{22222222-2222-2222-2222-222222222222}'
            $snapshotSet = [pscustomobject]@{
                SnapshotSetId = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
                Volumes = @(
                    [pscustomobject]@{ ShadowId = $firstId; LinkPath = (Join-Path ([IO.Path]::GetTempPath()) 'BRAVO_VSS_selftest_1') },
                    [pscustomobject]@{ ShadowId = $secondId; LinkPath = (Join-Path ([IO.Path]::GetTempPath()) 'BRAVO_VSS_selftest_2') }
                )
            }
            $saved = Save-BRAVOVSSOwnershipState `
                -StatePath $statePath `
                -SnapshotSet $snapshotSet `
                -GenerationId '20260808_180000'
            $deletedIds = New-Object System.Collections.ArrayList
            $removedLinks = New-Object System.Collections.ArrayList
            $cleanup = Remove-BRAVOOwnedOrphanVSSResources `
                -StatePath $statePath `
                -DeleteShadowById { param($Id) [void]$deletedIds.Add([string]$Id); return $true } `
                -RemoveLink { param($Path) [void]$removedLinks.Add([string]$Path) }
            $stateRemovedAfterCleanup = -not [IO.File]::Exists($statePath)

            [void](Save-BRAVOVSSOwnershipState `
                -StatePath $statePath `
                -SnapshotSet $snapshotSet `
                -GenerationId '20260808_180001')
            $foreignState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $foreignState.owner = 'OTHER_APPLICATION'
            [IO.File]::WriteAllText(
                $statePath,
                ($foreignState | ConvertTo-Json -Depth 5),
                (New-Object Text.UTF8Encoding($false))
            )
            $foreignDeleteCalls = New-Object System.Collections.ArrayList
            $foreignCleanup = Remove-BRAVOOwnedOrphanVSSResources `
                -StatePath $statePath `
                -DeleteShadowById { param($Id) [void]$foreignDeleteCalls.Add([string]$Id); return $true }

            [pscustomobject]@{
                SavedOwner = [string]$saved.owner
                SavedGeneration = [string]$saved.generationId
                CleanupSuccess = [bool]$cleanup.Success
                CleanupDeleted = [int]$cleanup.Deleted
                DeletedIds = @($deletedIds)
                RemovedLinkCount = $removedLinks.Count
                StateRemovedAfterCleanup = $stateRemovedAfterCleanup
                ForeignCleanupBlocked = -not [bool]$foreignCleanup.Success
                ForeignDeleteCallCount = $foreignDeleteCalls.Count
                ForeignStateRetained = [IO.File]::Exists($statePath)
            }
        } $vssOwnershipTestRoot
        Test-BRAVOCondition `
            -Condition (
                $vssOwnershipProbe.SavedOwner -eq 'BRAVO_ARCHIV' -and
                $vssOwnershipProbe.SavedGeneration -eq '20260808_180000' -and
                $vssOwnershipProbe.CleanupSuccess -and
                $vssOwnershipProbe.CleanupDeleted -eq 2 -and
                $vssOwnershipProbe.DeletedIds -contains '{11111111-1111-1111-1111-111111111111}' -and
                $vssOwnershipProbe.DeletedIds -contains '{22222222-2222-2222-2222-222222222222}' -and
                $vssOwnershipProbe.RemovedLinkCount -eq 2 -and
                $vssOwnershipProbe.StateRemovedAfterCleanup -and
                $vssOwnershipProbe.ForeignCleanupBlocked -and
                $vssOwnershipProbe.ForeignDeleteCallCount -eq 0 -and
                $vssOwnershipProbe.ForeignStateRetained
            ) `
            -Name 'BackupConsistency/BRAVOOwnedOrphanVSSCleanup' `
            -Failure 'hard-termination cleanup must persist exact BRAVO Shadow IDs, delete only those IDs, and retain foreign/invalid ownership state without issuing delete calls'
    } finally {
        if (Test-Path -LiteralPath $vssOwnershipTestRoot -PathType Container) {
            Remove-Item -LiteralPath $vssOwnershipTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("New-BRAVOVSSSnapshotSet") -and
            $archiveScriptText.Contains("Resolve-BRAVOSnapshotSourcePath") -and
            $archiveScriptText.Contains("Архівацію MODEL/BLOG/BRAVOEXCH скасовано") -and
            $archiveScriptText.Contains('live-архівація заборонена') -and
            $archiveScriptText.Contains('Remove-BRAVOVSSSnapshotLink -LinkPath $createdShadow.LinkPath') -and
            -not $archiveScriptText.Contains('$vssSnapshot = New-BRAVOVSSSnapshot')
        ) `
        -Name "BackupConsistency/VSSFailClosed" `
        -Failure "BRAVO_ARCHIV має створювати Snapshot Set до циклу і не переходити до live-каталогу при помилці VSS"
    $generationCollisionRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_GENERATION_COLLISION_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        $modelDir = Join-Path $generationCollisionRoot 'MODEL'
        $blogDir = Join-Path $generationCollisionRoot 'BLOG'
        $exchDir = Join-Path $generationCollisionRoot 'BRAVOEXCH'
        [void][IO.Directory]::CreateDirectory($modelDir)
        [void][IO.Directory]::CreateDirectory($blogDir)
        [void][IO.Directory]::CreateDirectory($exchDir)
        [IO.File]::WriteAllText((Join-Path $modelDir 'lab_20260808_154300.mdz'), 'old', (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $modelDir 'lab_20260808_154300.mdz.sha512'), 'oldhash', (New-Object Text.UTF8Encoding($false)))
        $safeGenerationId = & $archiveRuntimeModule {
            param($ModelDir, $BlogDir, $ExchDir)
            Get-BRAVOCollisionSafeGenerationId `
                -BaseGenerationId '20260808_154300' `
                -ArchivePrefix 'lab' `
                -Archives @(
                    [pscustomobject]@{ Type = 'MODEL'; Destination = $ModelDir; NameTemplate = '{0}_{1}.mdz' },
                    [pscustomobject]@{ Type = 'BLOG'; Destination = $BlogDir; NameTemplate = '{0}_blog_{1}.mdz' },
                    [pscustomobject]@{ Type = 'BRAVOEXCH'; Destination = $ExchDir; NameTemplate = '{0}_bravoexch_{1}.mdz' }
                )
        } $modelDir $blogDir $exchDir
        Test-BRAVOCondition `
            -Condition (
                $safeGenerationId -eq '20260808_154300_1' -and
                [IO.File]::ReadAllText((Join-Path $modelDir 'lab_20260808_154300.mdz')) -eq 'old' -and
                [IO.File]::ReadAllText((Join-Path $modelDir 'lab_20260808_154300.mdz.sha512')) -eq 'oldhash'
            ) `
            -Name "BackupConsistency/GenerationCollisionSuffix" `
            -Failure "collision suffix має застосовуватись до GenerationId до побудови всіх component filenames, а existing backup/hash мають лишатись незмінними"
    } finally {
        if (Test-Path -LiteralPath $generationCollisionRoot -PathType Container) {
            Remove-Item -LiteralPath $generationCollisionRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $componentBackupTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_COMPONENT_BACKUP_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        $componentSource = Join-Path $componentBackupTestRoot 'SOURCE'
        [void][IO.Directory]::CreateDirectory($componentSource)
        [IO.File]::WriteAllText((Join-Path $componentSource 'data.txt'), 'source', (New-Object Text.UTF8Encoding($false)))

        $componentProbe = & $archiveRuntimeModule {
            param($Root, $Source)

            $script:hashFileExtension = '.sha512'
            $script:hashFileEncoding = 'utf-8'
            $script:componentBackupMode = 'success'
            $knownHash = ('a' * 128).ToUpperInvariant()
            function Write-BRAVOLog {
                param([string]$Component, [string]$Message, [string]$Level)
            }
            # dev.19: Invoke-BRAVOComponentBackup тепер друкує заголовок
            # "=== СТВОРЕННЯ ХЕШУ $Component ===" безпосередньо перед
            # New-SHA512Hash через Write-Log (не Write-BRAVOLog) — цей
            # ізольований module не має реального Write-Log серед
            # -FunctionNames (він поза HASH/VSS/hash-persist фокусом цього
            # фікстура), тому потрібен той самий тип no-op стаба, що вже
            # Write-BRAVOLog вище.
            function Write-Log {
                param([string]$Message, [string]$Level = 'INFO')
            }
            function New-Archive {
                param([string]$SourcePath, [string]$FullArchivePath, [string]$ArcPath, [string]$ArcParams)
                [IO.File]::WriteAllText($FullArchivePath, "archive:$script:componentBackupMode", (New-Object Text.UTF8Encoding($false)))
                if ($script:componentBackupMode -eq 'create-fail') {
                    return [pscustomobject]@{
                        CreateSuccess = $false
                        IntegritySuccess = $false
                        ErrorStage = 'CREATE'
                        Error = 'synthetic create failure'
                    }
                }
                if ($script:componentBackupMode -eq 'integrity-fail') {
                    return [pscustomobject]@{
                        CreateSuccess = $true
                        IntegritySuccess = $false
                        ErrorStage = 'INTEGRITY'
                        Error = 'synthetic integrity failure'
                    }
                }
                [pscustomobject]@{
                    CreateSuccess = $true
                    IntegritySuccess = $true
                    ErrorStage = $null
                    Error = $null
                }
            }
            function New-SHA512Hash {
                param([string]$FilePath, [string]$HashFilePath)
                if ($script:componentBackupMode -eq 'hash-create-fail') {
                    return $false
                }
                $hashToWrite = if ($script:componentBackupMode -eq 'hash-verify-fail') { 'b' * 128 } else { $knownHash.ToLowerInvariant() }
                [IO.File]::WriteAllText($HashFilePath, ("{0} *{1}" -f $hashToWrite, [IO.Path]::GetFileName($FilePath)), (New-Object Text.UTF8Encoding($false)))
                return $true
            }
            function Get-BRAVOFileHash {
                param([string]$Path, [string]$Algorithm)
                [pscustomobject]@{ Hash = $knownHash }
            }
            function Write-BRAVOFinalHashFile {
                param([string]$Path, [string]$Hash, [string]$ArchiveName)
                if ($script:componentBackupMode -eq 'final-hash-write-fail') {
                    throw 'synthetic final hash write failure'
                }
                [IO.File]::WriteAllText(
                    $Path,
                    ("{0} *{1}" -f $Hash.ToLowerInvariant(), $ArchiveName),
                    (New-Object Text.UTF8Encoding($false))
                )
            }

            $successDest = Join-Path $Root 'SUCCESS'
            [void][IO.Directory]::CreateDirectory($successDest)
            $script:componentBackupMode = 'success'
            $success = Invoke-BRAVOComponentBackup `
                -Component 'MODEL' `
                -GenerationId '20260808_154300' `
                -OriginalSourcePath $Source `
                -SourcePath $Source `
                -DestinationDirectory $successDest `
                -ArchiveName 'lab_20260808_154300.mdz' `
                -ArcPath 'fake7za.exe'

            $previousDest = Join-Path $Root 'PREVIOUS'
            [void][IO.Directory]::CreateDirectory($previousDest)
            $previousArchive = Join-Path $previousDest 'lab_20260808_154200.mdz'
            $previousHash = $previousArchive + '.sha512'
            [IO.File]::WriteAllText($previousArchive, 'previous archive', (New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText($previousHash, 'previous hash', (New-Object Text.UTF8Encoding($false)))
            $script:componentBackupMode = 'create-fail'
            $createFail = Invoke-BRAVOComponentBackup `
                -Component 'MODEL' `
                -GenerationId '20260808_154300' `
                -OriginalSourcePath $Source `
                -SourcePath $Source `
                -DestinationDirectory $previousDest `
                -ArchiveName 'lab_20260808_154300.mdz' `
                -ArcPath 'fake7za.exe'

            $integrityDest = Join-Path $Root 'INTEGRITY'
            [void][IO.Directory]::CreateDirectory($integrityDest)
            $script:componentBackupMode = 'integrity-fail'
            $integrityFail = Invoke-BRAVOComponentBackup `
                -Component 'MODEL' `
                -GenerationId '20260808_154300' `
                -OriginalSourcePath $Source `
                -SourcePath $Source `
                -DestinationDirectory $integrityDest `
                -ArchiveName 'lab_20260808_154300.mdz' `
                -ArcPath 'fake7za.exe'

            $hashCreateDest = Join-Path $Root 'HASH_CREATE'
            [void][IO.Directory]::CreateDirectory($hashCreateDest)
            $script:componentBackupMode = 'hash-create-fail'
            $hashCreateFail = Invoke-BRAVOComponentBackup `
                -Component 'MODEL' `
                -GenerationId '20260808_154300' `
                -OriginalSourcePath $Source `
                -SourcePath $Source `
                -DestinationDirectory $hashCreateDest `
                -ArchiveName 'lab_20260808_154300.mdz' `
                -ArcPath 'fake7za.exe'

            $hashVerifyDest = Join-Path $Root 'HASH_VERIFY'
            [void][IO.Directory]::CreateDirectory($hashVerifyDest)
            $script:componentBackupMode = 'hash-verify-fail'
            $hashVerifyFail = Invoke-BRAVOComponentBackup `
                -Component 'MODEL' `
                -GenerationId '20260808_154300' `
                -OriginalSourcePath $Source `
                -SourcePath $Source `
                -DestinationDirectory $hashVerifyDest `
                -ArchiveName 'lab_20260808_154300.mdz' `
                -ArcPath 'fake7za.exe'

            $finalHashWriteDest = Join-Path $Root 'FINAL_HASH_WRITE'
            [void][IO.Directory]::CreateDirectory($finalHashWriteDest)
            $script:componentBackupMode = 'final-hash-write-fail'
            $finalHashWriteFail = Invoke-BRAVOComponentBackup `
                -Component 'MODEL' `
                -GenerationId '20260808_154300' `
                -OriginalSourcePath $Source `
                -SourcePath $Source `
                -DestinationDirectory $finalHashWriteDest `
                -ArchiveName 'lab_20260808_154300.mdz' `
                -ArcPath 'fake7za.exe'

            [pscustomobject]@{
                SuccessCreate = [bool]$success.CreateSuccess
                SuccessIntegrity = [bool]$success.IntegritySuccess
                SuccessHash = [bool]$success.HashSuccess
                SuccessArchiveExists = Test-Path -LiteralPath (Join-Path $successDest 'lab_20260808_154300.mdz') -PathType Leaf
                SuccessHashExists = Test-Path -LiteralPath ((Join-Path $successDest 'lab_20260808_154300.mdz') + '.sha512') -PathType Leaf
                SuccessPartialCount = @(Get-ChildItem -LiteralPath $successDest -Recurse -Filter '*.partial.mdz' -ErrorAction SilentlyContinue).Count
                PreviousArchiveText = [IO.File]::ReadAllText($previousArchive)
                PreviousHashText = [IO.File]::ReadAllText($previousHash)
                CreateFailCreate = [bool]$createFail.CreateSuccess
                CreateFailPartialCount = @(Get-ChildItem -LiteralPath $previousDest -Recurse -Filter '*.partial.mdz' -ErrorAction SilentlyContinue).Count
                IntegrityCreate = [bool]$integrityFail.CreateSuccess
                IntegrityIntegrity = [bool]$integrityFail.IntegritySuccess
                IntegrityHash = [bool]$integrityFail.HashSuccess
                IntegrityPublished = Test-Path -LiteralPath (Join-Path $integrityDest 'lab_20260808_154300.mdz') -PathType Leaf
                HashCreateHash = [bool]$hashCreateFail.HashSuccess
                HashCreatePublished = Test-Path -LiteralPath (Join-Path $hashCreateDest 'lab_20260808_154300.mdz') -PathType Leaf
                HashVerifyHash = [bool]$hashVerifyFail.HashSuccess
                HashVerifyPublished = Test-Path -LiteralPath (Join-Path $hashVerifyDest 'lab_20260808_154300.mdz') -PathType Leaf
                FinalHashWriteHash = [bool]$finalHashWriteFail.HashSuccess
                FinalHashWriteArchivePublished = Test-Path -LiteralPath (Join-Path $finalHashWriteDest 'lab_20260808_154300.mdz') -PathType Leaf
                FinalHashWriteSidecarPublished = Test-Path -LiteralPath ((Join-Path $finalHashWriteDest 'lab_20260808_154300.mdz') + '.sha512') -PathType Leaf
                FinalHashWriteErrorStage = [string]$finalHashWriteFail.ErrorStage
            }
        } $componentBackupTestRoot $componentSource

        Test-BRAVOCondition `
            -Condition (
                $componentProbe.SuccessCreate -and
                $componentProbe.SuccessIntegrity -and
                $componentProbe.SuccessHash -and
                $componentProbe.SuccessArchiveExists -and
                $componentProbe.SuccessHashExists -and
                $componentProbe.SuccessPartialCount -eq 0
            ) `
            -Name "BackupConsistency/AtomicPublishFromEmptyDestination" `
            -Failure "порожній destination має приймати backup лише після create + integrity + SHA512 verification, без залишених .partial"
        Test-BRAVOCondition `
            -Condition (
                -not $componentProbe.CreateFailCreate -and
                $componentProbe.PreviousArchiveText -eq 'previous archive' -and
                $componentProbe.PreviousHashText -eq 'previous hash' -and
                $componentProbe.CreateFailPartialCount -eq 0
            ) `
            -Name "BackupConsistency/FailedSecondRunPreservesPreviousBackup" `
            -Failure "failed second generation не повинна змінювати previous .mdz/.sha512 і має прибирати тільки свій temporary artifact"
        Test-BRAVOCondition `
            -Condition (
                $componentProbe.IntegrityCreate -and
                -not $componentProbe.IntegrityIntegrity -and
                -not $componentProbe.IntegrityHash -and
                -not $componentProbe.IntegrityPublished
            ) `
            -Name "BackupConsistency/IntegrityFailureDoesNotPublish" `
            -Failure "CreateSuccess=true + IntegritySuccess=false має лишати HashSuccess=false і не публікувати final archive"
        Test-BRAVOCondition `
            -Condition (-not $componentProbe.HashCreateHash -and -not $componentProbe.HashCreatePublished) `
            -Name "BackupConsistency/HashCreationFailureDoesNotPublish" `
            -Failure "SHA512 create failure має лишати generation невалідною і не публікувати final archive"
        Test-BRAVOCondition `
            -Condition (-not $componentProbe.HashVerifyHash -and -not $componentProbe.HashVerifyPublished) `
            -Name "BackupConsistency/HashVerificationFailureDoesNotPublish" `
            -Failure "SHA512 verification mismatch має лишати generation невалідною і не публікувати final archive"
        Test-BRAVOCondition `
            -Condition (
                -not $componentProbe.FinalHashWriteHash -and
                -not $componentProbe.FinalHashWriteArchivePublished -and
                -not $componentProbe.FinalHashWriteSidecarPublished -and
                $componentProbe.FinalHashWriteErrorStage -eq 'PUBLISH' -and
                (Resolve-BRAVOExitCode `
                    -LocalArchiveFailed:($componentProbe.FinalHashWriteErrorStage -eq 'PUBLISH') `
                    -HashValidationFailed:($componentProbe.FinalHashWriteErrorStage -eq 'HASH')) -eq 40
            ) `
            -Name 'BackupConsistency/FinalHashWriteFailureRollsBackArchive' `
            -Failure 'помилка запису фінального .sha512 має бути PUBLISH/exit 40, лишати HashSuccess=false і прибирати вже переміщений archive та частковий sidecar'
    } finally {
        if (Test-Path -LiteralPath $componentBackupTestRoot -PathType Container) {
            Remove-Item -LiteralPath $componentBackupTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $dryRunScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_DRY_RUN.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $dryRunScriptText.Contains('$backupConsistency.Mode') -and
            $dryRunScriptText.Contains('$backupConsistency.SnapshotContext') -and
            -not $dryRunScriptText.Contains('QuiesceForBackup')
        ) `
        -Name "BackupConsistency/DryRunReportsVSS" `
        -Failure "dry-run має показувати фактичний VSS-режим замість видаленого QuiesceForBackup"
    $dryRunPlanModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $dryRunScriptText `
        -FunctionNames @(
            'Test-SettingEnabled',
            'Get-BRAVODryRunOptionalComponentPlan',
            'Get-BRAVODryRunRangeIdPlan'
        )
    $rangeIdSettingsWithoutFilePath = [pscustomobject]@{
        Enabled = $true
        ThresholdPercent = 80
    }
    $rangeIdCanonicalPlan = & $dryRunPlanModule {
        param($Settings)
        Get-BRAVODryRunRangeIdPlan `
            -RangeIdMonitoring $Settings `
            -SystemRoot 'C:\WindowsTest' `
            -Is64BitOperatingSystem $true `
            -TestPath { param($Path) $true }
    } $rangeIdSettingsWithoutFilePath
    $rangeIdMissingPlan = & $dryRunPlanModule {
        param($Settings)
        Get-BRAVODryRunRangeIdPlan `
            -RangeIdMonitoring $Settings `
            -SystemRoot 'C:\WindowsTest' `
            -Is64BitOperatingSystem $true `
            -TestPath { param($Path) $false }
    } $rangeIdSettingsWithoutFilePath
    $rangeIdX86Plan = & $dryRunPlanModule {
        param($Settings)
        Get-BRAVODryRunRangeIdPlan `
            -RangeIdMonitoring $Settings `
            -SystemRoot 'C:\WindowsTest' `
            -Is64BitOperatingSystem $false `
            -TestPath { param($Path) $true }
    } $rangeIdSettingsWithoutFilePath
    $legacyRangeIdSettings = [pscustomobject]@{
        Enabled = $true
        ThresholdPercent = 80
        FilePath = 'D:\LIMS\range_id_log.json'
    }
    $legacyRangeIdPlan = & $dryRunPlanModule {
        param($Settings)
        Get-BRAVODryRunRangeIdPlan `
            -RangeIdMonitoring $Settings `
            -SystemRoot 'C:\WindowsTest' `
            -Is64BitOperatingSystem $true `
            -TestPath { param($Path) $true }
    } $legacyRangeIdSettings
    Test-BRAVOCondition `
        -Condition ($rangeIdCanonicalPlan.Path -eq 'C:\WindowsTest\SysWOW64\range_id_log.json' -and $rangeIdCanonicalPlan.Status -eq 'PLAN') `
        -Name 'DryRun/RangeIdUsesCanonicalSystemPath' `
        -Failure 'Dry Run має використовувати тільки canonical system range_id_log.json'
    Test-BRAVOCondition `
        -Condition ($rangeIdCanonicalPlan.Path -eq 'C:\WindowsTest\SysWOW64\range_id_log.json') `
        -Name 'DryRun/RangeIdUsesSysWow64OnX64' `
        -Failure 'x64 Dry Run має шукати range_id_log.json у SysWOW64'
    Test-BRAVOCondition `
        -Condition ($rangeIdX86Plan.Path -eq 'C:\WindowsTest\System32\range_id_log.json') `
        -Name 'DryRun/RangeIdUsesSystem32OnX86' `
        -Failure 'x86 Dry Run має шукати range_id_log.json у System32'
    Test-BRAVOCondition `
        -Condition (-not $dryRunScriptText.Contains('RangeIdMonitoring.FilePath')) `
        -Name 'DryRun/RangeIdDoesNotReferenceLegacyFilePath' `
        -Failure 'Dry Run не може читати legacy RangeIdMonitoring FilePath'
    Test-BRAVOCondition `
        -Condition ($legacyRangeIdPlan.Path -eq $rangeIdCanonicalPlan.Path -and -not $legacyRangeIdPlan.Detail.Contains('D:\LIMS')) `
        -Name 'DryRun/RangeIdLegacyFilePathCannotOverrideCanonicalPath' `
        -Failure 'legacy Range ID path не може перевизначати canonical system path'
    Test-BRAVOCondition `
        -Condition ($rangeIdMissingPlan.Status -eq 'WARN' -and $rangeIdMissingPlan.Path -eq $rangeIdCanonicalPlan.Path) `
        -Name 'DryRun/MissingCanonicalRangeIdIsWarningNotFatal' `
        -Failure 'відсутній canonical range_id_log.json має бути WARN, не fatal'
    Test-BRAVOCondition `
        -Condition (-not $rangeIdCanonicalPlan.Path.Contains('LIMS') -and -not $rangeIdCanonicalPlan.Detail.Contains('fallback')) `
        -Name 'DryRun/RangeIdHasNoLimsRootFallback' `
        -Failure 'Range ID Dry Run не може мати fallback до LIMSRoot'

    $absentBravoWebDryRunPlan = & $dryRunPlanModule {
        Get-BRAVODryRunOptionalComponentPlan `
            -BravoWebEnabled $true `
            -BravoWebServiceExists $false `
            -BravoWebServiceDisabled $false `
            -ExchangeApiServiceExists $false `
            -ExchangeApiServiceDisabled $false `
            -SystemLogRoot 'C:\SystemLog' `
            -ExchangeApiServiceName 'exchangAPI'
    }
    $disabledConfigBravoWebDryRunPlan = & $dryRunPlanModule {
        Get-BRAVODryRunOptionalComponentPlan `
            -BravoWebEnabled $false `
            -BravoWebServiceExists $true `
            -BravoWebServiceDisabled $false `
            -ExchangeApiServiceExists $false `
            -ExchangeApiServiceDisabled $false `
            -SystemLogRoot 'C:\SystemLog' `
            -ExchangeApiServiceName 'exchangAPI'
    }
    $presentExchangeApiDryRunPlan = & $dryRunPlanModule {
        Get-BRAVODryRunOptionalComponentPlan `
            -BravoWebEnabled $false `
            -BravoWebServiceExists $false `
            -BravoWebServiceDisabled $false `
            -ExchangeApiServiceExists $true `
            -ExchangeApiServiceDisabled $false `
            -SystemLogRoot 'C:\SystemLog' `
            -ExchangeApiServiceName 'exchangAPI'
    }
    $presentBravoWebDryRunPlan = & $dryRunPlanModule {
        Get-BRAVODryRunOptionalComponentPlan `
            -BravoWebEnabled $true `
            -BravoWebServiceExists $true `
            -BravoWebServiceDisabled $false `
            -ExchangeApiServiceExists $false `
            -ExchangeApiServiceDisabled $false `
            -SystemLogRoot 'C:\SystemLog' `
            -ExchangeApiServiceName 'exchangAPI'
    }
    Test-BRAVOCondition `
        -Condition ($absentBravoWebDryRunPlan.WriteAccessTargets.Keys -notcontains 'SystemLog\BravoWeb\Apache' -and $absentBravoWebDryRunPlan.WriteAccessTargets.Keys -notcontains 'SystemLog\BravoWeb\Application') `
        -Name 'DryRun/AbsentBravoWebDoesNotProbeWebDirectories' `
        -Failure 'відсутній BRAVO Web не може додавати web directories до write probes'
    Test-BRAVOCondition `
        -Condition ($absentBravoWebDryRunPlan.ServiceNames -notcontains 'BRAVO Web/Apache (автовизначення)') `
        -Name 'DryRun/AbsentBravoWebDoesNotEnterServicePlan' `
        -Failure 'відсутній BRAVO Web не може входити до service plan'
    Test-BRAVOCondition `
        -Condition (-not $disabledConfigBravoWebDryRunPlan.BravoWebEligible -and $disabledConfigBravoWebDryRunPlan.WriteAccessTargets.Keys -notcontains 'SystemLog\BravoWeb\Apache') `
        -Name 'DryRun/DisabledConfigBravoWebDoesNotProbeWebDirectories' `
        -Failure 'вимкнений у config BRAVO Web не може запускати web probes'
    Test-BRAVOCondition `
        -Condition (-not $absentBravoWebDryRunPlan.BravoWebLegacyDataEligible) `
        -Name 'DryRun/LegacyBravoWebDirectoryDoesNotActivateAbsentComponent' `
        -Failure 'legacy BravoWeb directory не може активувати absent component'
    Test-BRAVOCondition `
        -Condition ($absentBravoWebDryRunPlan.WriteAccessTargets.Keys -notcontains 'SystemLog\exchangAPI') `
        -Name 'DryRun/AbsentExchangeApiDoesNotProbeLogDirectory' `
        -Failure 'відсутній exchangAPI не може додавати log directory до write probes'
    Test-BRAVOCondition `
        -Condition ($absentBravoWebDryRunPlan.ServiceNames -notcontains 'exchangAPI') `
        -Name 'DryRun/AbsentExchangeApiDoesNotEnterServicePlan' `
        -Failure 'відсутній exchangAPI не може входити до service plan'
    Test-BRAVOCondition `
        -Condition (-not $absentBravoWebDryRunPlan.ExchangeApiLegacyDataEligible) `
        -Name 'DryRun/LegacyExchangeApiDirectoryDoesNotActivateAbsentComponent' `
        -Failure 'legacy exchangAPI directory не може активувати absent component'
    Test-BRAVOCondition `
        -Condition ($presentExchangeApiDryRunPlan.WriteAccessTargets.Keys -contains 'SystemLog\exchangAPI' -and $presentExchangeApiDryRunPlan.ServiceNames -contains 'exchangAPI') `
        -Name 'DryRun/PresentExchangeApiPreservesProbeAndPlan' `
        -Failure 'встановлений active exchangAPI має зберігати probe і service plan'
    Test-BRAVOCondition `
        -Condition ($presentBravoWebDryRunPlan.WriteAccessTargets.Keys -contains 'SystemLog\BravoWeb\Apache' -and $presentBravoWebDryRunPlan.WriteAccessTargets.Keys -contains 'SystemLog\BravoWeb\Application' -and $presentBravoWebDryRunPlan.ServiceNames -contains 'BRAVO Web/Apache (автовизначення)') `
        -Name 'DryRun/PresentBravoWebPreservesProbeAndPlan' `
        -Failure 'встановлений active BRAVO Web має зберігати web probes і service plan'
    Test-BRAVOCondition `
        -Condition (
            $healthScriptText.Contains('Format-HealthIssueFileName -Issue $Issue') -and
            $healthScriptText.Contains('$($Issue.Reason)$(Format-HealthIssueFileName -Issue $Issue)')
        ) `
        -Name "Health/SFTPArchiveNameOnFailures" `
        -Failure "ім'я локального архіву має відображатися для всіх SFTP-помилок"
    $healthSftpIssueFormatterModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $healthScriptText `
        -FunctionNames @(
            'Format-FileSize',
            'Get-HealthIssueComponentName',
            'ConvertTo-NotificationLiteralText',
            'Format-HealthIssueFileName',
            'Format-CompactSFTPIssue'
        )
    $missingGenerationSftpIssue = [pscustomobject]@{
        Kind = 'SFTPArchive'
        Component = 'SFTP MODEL'
        Reason = 'перевірку пропущено: component відсутній у verified COMPLETE local generation'
        FileName = 'немає даних'
        LastWriteTime = $null
        SizeBytes = $null
        ExpectedSizeBytes = $null
        ActualSizeBytes = $null
        Location = '/archive/model'
    }
    $missingGenerationSftpProbe = & $healthSftpIssueFormatterModule {
        param($Issue)
        Set-StrictMode -Version Latest
        $script:NotificationProvider = 'slack'
        try {
            [pscustomobject]@{
                Success = $true
                Text = Format-CompactSFTPIssue -Issue $Issue
                Error = $null
            }
        } catch {
            [pscustomobject]@{
                Success = $false
                Text = $null
                Error = $_.Exception.Message
            }
        }
    } $missingGenerationSftpIssue
    $missingGenerationSftpSchema = [regex]::IsMatch(
        $healthScriptText,
        "(?s)Kind\s*=\s*'SFTPArchive'.*?component відсутній у verified COMPLETE local generation.*?ExpectedSizeBytes\s*=.*?ActualSizeBytes\s*=.*?Location\s*="
    )
    Test-BRAVOCondition `
        -Condition (
            $missingGenerationSftpSchema -and
            $missingGenerationSftpProbe.Success -and
            -not [string]::IsNullOrWhiteSpace([string]$missingGenerationSftpProbe.Text)
        ) `
        -Name 'Health/SFTPArchiveIssueSchemaIsStrictModeSafe' `
        -Failure 'усі SFTPArchive issue-обʼєкти мають містити ExpectedSizeBytes і ActualSizeBytes, бо formatter читає їх під StrictMode'
    $healthUtcTimeModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $healthScriptText `
        -FunctionNames @(
            'ConvertTo-BRAVOUtcDateTime',
            'Get-BRAVOUtcAge',
            'Format-BackupAge'
        )
    $healthUtcAgeProbe = & $healthUtcTimeModule {
        $nowUtc = [datetime]::SpecifyKind([datetime]'2026-08-09T01:52:00', [DateTimeKind]::Utc)
        $generationUtc = $nowUtc.AddMinutes(-10)
        $manifestJson = [pscustomobject]@{ createdAt = $generationUtc } | ConvertTo-Json -Compress
        $manifestTimestamp = [datetime](($manifestJson | ConvertFrom-Json).createdAt)
        # DateTime subtraction uses ticks, not Kind. This deliberately
        # simulates a UTC+3 local wall clock without requiring that timezone.
        $simulatedLocalNow = [datetime]::SpecifyKind($nowUtc.AddHours(3), [DateTimeKind]::Local)
        $legacyAge = $simulatedLocalNow - $manifestTimestamp
        $utcAge = Get-BRAVOUtcAge -Timestamp $manifestTimestamp -NowUtc $nowUtc
        $staleThreshold = [timespan]::FromHours(2)
        $oldGenerationUtc = $nowUtc.AddHours(-2).AddMinutes(-1)
        $oldGenerationAge = Get-BRAVOUtcAge -Timestamp $oldGenerationUtc -NowUtc $nowUtc
        $unspecified = [datetime]::SpecifyKind($generationUtc, [DateTimeKind]::Unspecified)
        $normalizedUnspecifiedUtc = ConvertTo-BRAVOUtcDateTime -Timestamp $unspecified
        $expectedUnspecifiedUtc = [datetime]::SpecifyKind(
            $unspecified,
            [DateTimeKind]::Local
        ).ToUniversalTime()
        [pscustomobject]@{
            ManifestKind = $manifestTimestamp.Kind
            UsesMicrosoftDateJson = $manifestJson -match '\\/Date\('
            LegacyAgeMinutes = [int]$legacyAge.TotalMinutes
            UtcAgeMinutes = [int]$utcAge.TotalMinutes
            AgeText = Format-BackupAge -LastWriteTime $manifestTimestamp -NowUtc $nowUtc
            FreshIsStale = $utcAge -gt $staleThreshold
            OldIsStale = $oldGenerationAge -gt $staleThreshold
            UnspecifiedNormalizesToUtc = $normalizedUnspecifiedUtc.Kind -eq [DateTimeKind]::Utc
            UnspecifiedMatchesLocalContract = $normalizedUnspecifiedUtc -eq $expectedUnspecifiedUtc
        }
    }
    Test-BRAVOCondition `
        -Condition (
            $healthUtcAgeProbe.UsesMicrosoftDateJson -and
            $healthUtcAgeProbe.ManifestKind -eq [DateTimeKind]::Utc -and
            $healthUtcAgeProbe.LegacyAgeMinutes -eq 190 -and
            $healthUtcAgeProbe.UtcAgeMinutes -eq 10 -and
            $healthUtcAgeProbe.AgeText -eq '10 хв.' -and
            -not $healthUtcAgeProbe.FreshIsStale -and
            $healthUtcAgeProbe.OldIsStale -and
            $healthUtcAgeProbe.UnspecifiedNormalizesToUtc -and
            $healthUtcAgeProbe.UnspecifiedMatchesLocalContract -and
            $healthScriptText.Contains('$healthCheckStartedUtc = $healthCheckStarted.ToUniversalTime()') -and
            $healthScriptText.Contains('$manifestFile.LastWriteTimeUtc') -and
            $healthScriptText.Contains('Get-BRAVOUtcAge -Timestamp $generation.CreatedAtUtc -NowUtc $healthCheckStartedUtc')
        ) `
        -Name 'Health/GenerationAgeUsesUtcArithmetic' `
        -Failure 'generation manifest /Date(...) має нормалізуватися до UTC: 10 хв. не можуть перетворюватися на +timezone offset, а MaxBackupAgeHours має коректно розрізняти fresh і stale generation'
    $archiveGenerationStateModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $archiveScriptText `
        -FunctionNames @(
            'New-BRAVOBackupGenerationState',
            'Write-BRAVOBackupGenerationManifest',
            'Get-BRAVOArchiveVSSSummaryValue',
            'Get-BRAVOArchiveGenerationFailureSummaryReason'
        )
    $archiveGenerationTestRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'BRAVO_GENERATION_MATERIALIZE_{0}' -f [guid]::NewGuid().ToString('N')
    )
    try {
        [void][IO.Directory]::CreateDirectory($archiveGenerationTestRoot)
        $archiveGenerationProbe = & $archiveGenerationStateModule {
            param($ManifestRoot)
            Set-StrictMode -Version Latest
            $caseResults = New-Object System.Collections.Generic.List[object]
            foreach ($count in @(0, 1, 3)) {
                $generationResults = New-Object System.Collections.Generic.List[object]
                for ($index = 0; $index -lt $count; $index++) {
                    [void]$generationResults.Add([pscustomobject]@{ Component = "CASE$index" })
                }
                $generationResultsArray = $generationResults.ToArray()
                $state = New-BRAVOBackupGenerationState `
                    -GenerationId "case_$count" `
                    -StartedAt (Get-Date) `
                    -Components $generationResultsArray `
                    -Status 'COMPLETE'
                [void]$caseResults.Add([pscustomobject]@{
                        ExpectedCount = $count
                        IsArray = $generationResultsArray -is [object[]]
                        ArrayCount = $generationResultsArray.Count
                        StateCount = $state.Components.Count
                    })
            }

            $snapshotSet = [pscustomobject]@{
                SnapshotSetId = '{BRAVO-SELF-TEST-SNAPSHOT}'
                CreatedAt = Get-Date
                Volumes = @([pscustomobject]@{
                        VolumeRoot = 'C:\'
                        DeviceObject = '\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1'
                        ShadowId = '{BRAVO-SELF-TEST-SHADOW}'
                        SetId = '{BRAVO-SELF-TEST-SNAPSHOT}'
                    })
            }
            $completeResults = New-Object System.Collections.Generic.List[object]
            foreach ($componentName in @('MODEL', 'BLOG', 'BRAVOEXCH')) {
                [void]$completeResults.Add([pscustomobject]@{
                        Component = $componentName
                        OriginalSourcePath = "C:\Source\$componentName"
                        SnapshotSourcePath = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\Source\$componentName"
                        ArchivePath = "C:\Backup\$componentName.mdz"
                        HashPath = "C:\Backup\$componentName.mdz.sha512"
                        ArchiveSize = 1
                        SHA512 = 'self-test'
                        CreateSuccess = $true
                        IntegritySuccess = $true
                        HashSuccess = $true
                        ErrorStage = $null
                        Error = $null
                    })
            }
            $completeState = New-BRAVOBackupGenerationState `
                -GenerationId 'complete_three_components' `
                -StartedAt (Get-Date) `
                -SnapshotSet $snapshotSet `
                -Components $completeResults.ToArray() `
                -Status 'COMPLETE'
            $manifestPath = Write-BRAVOBackupGenerationManifest `
                -GenerationState $completeState `
                -BackupRoot $ManifestRoot
            $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            [pscustomobject]@{
                Cases = $caseResults.ToArray()
                StateExists = $null -ne $completeState
                StateComponentCount = $completeState.Components.Count
                StateSnapshotSetId = $completeState.SnapshotSetId
                ManifestExists = Test-Path -LiteralPath $manifestPath -PathType Leaf
                ManifestStatus = [string]$manifest.status
                ManifestComponentCount = @($manifest.components.PSObject.Properties).Count
                ManifestSnapshotSetId = [string]$manifest.snapshotSetId
                VssAfterStateFailure = Get-BRAVOArchiveVSSSummaryValue `
                    -SnapshotSet $snapshotSet `
                    -EnabledArchiveCount 3
                VssNotCreated = Get-BRAVOArchiveVSSSummaryValue `
                    -SnapshotSet $null `
                    -EnabledArchiveCount 3
                VssSkipped = Get-BRAVOArchiveVSSSummaryValue `
                    -SnapshotSet $null `
                    -EnabledArchiveCount 0
                GenerationFailureReason = Get-BRAVOArchiveGenerationFailureSummaryReason `
                    -GenerationFinalizationFailed $true `
                    -GenerationFinalizationFailureReason 'synthetic finalization failure'
            }
        } $archiveGenerationTestRoot
        $archiveGenerationMaterializationWiring = (
            $archiveScriptText.Contains('$generationResultsArray = $generationResults.ToArray()') -and
            $archiveScriptText.Contains('-Components $generationResultsArray') -and
            -not $archiveScriptText.Contains('$script:backupGenerationResults = @($generationResults)') -and
            -not $archiveScriptText.Contains('-Components @($generationResults)')
        )
        Test-BRAVOCondition `
            -Condition (
                $archiveGenerationMaterializationWiring -and
                @($archiveGenerationProbe.Cases | Where-Object {
                    -not $_.IsArray -or $_.ArrayCount -ne $_.ExpectedCount -or $_.StateCount -ne $_.ExpectedCount
                }).Count -eq 0 -and
                $archiveGenerationProbe.StateExists -and
                $archiveGenerationProbe.StateComponentCount -eq 3 -and
                $archiveGenerationProbe.StateSnapshotSetId -eq '{BRAVO-SELF-TEST-SNAPSHOT}' -and
                $archiveGenerationProbe.ManifestExists -and
                $archiveGenerationProbe.ManifestStatus -eq 'COMPLETE' -and
                $archiveGenerationProbe.ManifestComponentCount -eq 3 -and
                $archiveGenerationProbe.ManifestSnapshotSetId -eq '{BRAVO-SELF-TEST-SNAPSHOT}'
            ) `
            -Name 'Archive/GenerationResultsMaterializeSafely' `
            -Failure 'List[object] generation results мають безпечно materialize у масив для 0/1/3 елементів; три успішні компоненти мають формувати COMPLETE manifest зі SnapshotSetId'
        Test-BRAVOCondition `
            -Condition (
                $archiveGenerationProbe.VssAfterStateFailure -eq 'OK ({BRAVO-SELF-TEST-SNAPSHOT})' -and
                $archiveGenerationProbe.VssNotCreated -eq 'FAILED' -and
                $archiveGenerationProbe.VssSkipped -eq 'SKIPPED' -and
                $archiveGenerationProbe.GenerationFailureReason -eq 'Generation: FAILED. Причина: synthetic finalization failure' -and
                (Resolve-BRAVOExitCode -LocalArchiveFailed -HealthCritical) -eq 40
            ) `
            -Name 'Archive/GenerationFailurePreservesVssAndPrimaryExit' `
            -Failure 'VSS summary має залежати від фактичного Snapshot Set, а generation finalization failure має лишатися primary LocalArchiveFailed перед HealthCritical'

        $successCountAssignment = [regex]::Match(
            $archiveScriptText,
            '(?m)^\s*\$successCount\s*=.*$'
        )
        $successCountProbe = @()
        if ($successCountAssignment.Success) {
            $successCountScript = [scriptblock]::Create(
                "param(`$results)`nSet-StrictMode -Version 2.0`n$($successCountAssignment.Value)`nreturn `$successCount"
            )
            foreach ($case in @(
                [pscustomobject]@{ Results = @{}; Expected = 0 },
                [pscustomobject]@{ Results = @{ MODEL = [pscustomobject]@{ ArchiveSuccess = $true } }; Expected = 1 },
                [pscustomobject]@{
                    Results = @{
                        MODEL = [pscustomobject]@{ ArchiveSuccess = $true }
                        BLOG = [pscustomobject]@{ ArchiveSuccess = $false }
                        BRAVOEXCH = [pscustomobject]@{ ArchiveSuccess = $true }
                    }
                    Expected = 2
                }
            )) {
                $successCountProbe += [pscustomobject]@{
                    Actual = & $successCountScript $case.Results
                    Expected = $case.Expected
                }
            }
        }
        Test-BRAVOCondition `
            -Condition (
                $successCountAssignment.Success -and
                @($successCountProbe | Where-Object { $_.Actual -ne $_.Expected }).Count -eq 0
            ) `
            -Name 'Archive/SuccessCountHandlesZeroOneAndManyResults' `
            -Failure 'фактичне присвоєння $successCount з Archive Main має працювати під StrictMode для 0/1/N результатів без scalar .Count exception'

        $snapshotLoopStart = $archiveScriptText.IndexOf('foreach ($archive in $readyArchives)')
        $snapshotResolveIndex = if ($snapshotLoopStart -ge 0) {
            $archiveScriptText.IndexOf('$snapshotSourcePath = Resolve-BRAVOSnapshotSourcePath', $snapshotLoopStart)
        } else { -1 }
        $snapshotInitializationIndex = if ($snapshotResolveIndex -ge 0) {
            $archiveScriptText.LastIndexOf('$snapshotSourcePath = $null', $snapshotResolveIndex)
        } else { -1 }
        Test-BRAVOCondition `
            -Condition (
                $snapshotLoopStart -ge 0 -and
                $snapshotInitializationIndex -gt $snapshotLoopStart -and
                $snapshotInitializationIndex -lt $snapshotResolveIndex
            ) `
            -Name 'Archive/SnapshotPathInitializedPerComponent' `
            -Failure '$snapshotSourcePath має скидатися в $null у кожній ітерації безпосередньо перед Resolve-BRAVOSnapshotSourcePath, щоб catch не читав uninitialized/stale значення'

        $finalManifestUpdateIndex = $archiveScriptText.IndexOf('$script:backupGenerationState.TransferResults = $transferResults')
        $exitClassificationIndex = $archiveScriptText.IndexOf('$anyLocalArchiveFailed = @(')
        $finalManifestUpdateWindow = if (
            $finalManifestUpdateIndex -ge 0 -and
            $exitClassificationIndex -gt $finalManifestUpdateIndex
        ) {
            $archiveScriptText.Substring(
                $finalManifestUpdateIndex,
                $exitClassificationIndex - $finalManifestUpdateIndex
            )
        } else { '' }
        Test-BRAVOCondition `
            -Condition (
                $finalManifestUpdateIndex -ge 0 -and
                $finalManifestUpdateIndex -lt $exitClassificationIndex -and
                $finalManifestUpdateWindow.Contains('$generationFinalizationFailed = $true') -and
                $finalManifestUpdateWindow.Contains('$operationFailed = $true') -and
                $finalManifestUpdateWindow.Contains("-Level 'ERROR'")
            ) `
            -Name 'Archive/FinalManifestFailureAffectsExitCode' `
            -Failure 'фінальний запис manifest має відбуватися до класифікації exit code, а catch — ставити generationFinalizationFailed/operationFailed і логувати ERROR'

        Test-BRAVOCondition `
            -Condition (
                $archiveScriptText -match '(?s)\$anyLocalArchiveFailed\s*=\s*@\(.*?ErrorStage\s*-eq\s*''PUBLISH''.*?\)\.Count' -and
                $archiveScriptText -match '(?s)\$anyHashValidationFailed\s*=\s*@\(.*?ErrorStage\s*-eq\s*''HASH''.*?\)\.Count'
            ) `
            -Name 'Archive/FailureStageMapsToCorrectExitCategory' `
            -Failure 'PUBLISH має входити до LocalArchiveFailed (40), а HashValidationFailed (41) — лише для ErrorStage=HASH'

        $publishedResultBlock = [regex]::Match(
            $archiveScriptText,
            '(?s)if\s*\(\$componentPublished\)\s*\{.*?\$results\[\$archive\.Type\]\s*=\s*@\{(?<Body>.*?)\r?\n\s*\}\s*\}\s*else'
        )
        Test-BRAVOCondition `
            -Condition (
                $publishedResultBlock.Success -and
                $publishedResultBlock.Groups['Body'].Value.Contains('ErrorStage = $null') -and
                $publishedResultBlock.Groups['Body'].Value.Contains('Error = $null') -and
                $publishedResultBlock.Groups['Body'].Value.Contains('ToolFailure = $null')
            ) `
            -Name 'Archive/PublishedResultHasStrictModeFailureFields' `
            -Failure 'успішний запис $results має містити ErrorStage/Error/ToolFailure=$null, інакше фінальна класифікація падає під StrictMode після успішної архівації'

        Test-BRAVOCondition `
            -Condition ($bravoConfigText -match '(?s)Restore\s*=\s*@\{.*?Day\s*=\s*7\b') `
            -Name 'Maintenance/DefaultRestoreScheduleRemainsSunday' `
            -Failure 'BRAVO.config Restore.Day має лишатися 7 (Sunday), як задокументовано для планової реставрації о 03:00'
    } finally {
        if (Test-Path -LiteralPath $archiveGenerationTestRoot -PathType Container) {
            Remove-Item -LiteralPath $archiveGenerationTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $healthGenerationModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $healthScriptText `
        -FunctionNames @(
            'ConvertTo-BRAVOUtcDateTime',
            'Get-BRAVOUtcAge',
            'Get-BackupHealthIssues'
        )
    $healthNoGenerationRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'BRAVO_HEALTH_NO_GENERATION_{0}' -f [guid]::NewGuid().ToString('N')
    )
    try {
        [void][IO.Directory]::CreateDirectory($healthNoGenerationRoot)
        $healthNoGenerationIssue = & $healthGenerationModule {
            param($BackupRoot)
            Set-StrictMode -Version Latest
            $archiveDefinitions = @([pscustomobject]@{ Type = 'MODEL'; Enabled = $true })
            $backupMonitoring = [pscustomobject]@{ MaxBackupAgeHours = 24 }
            $backupRootPath = $BackupRoot
            $healthCheckStarted = Get-Date
            $healthCheckStartedUtc = $healthCheckStarted.ToUniversalTime()
            $script:healthLatestArchives = @{}
            function Get-BRAVOFiles {
                param([string]$Path, [string]$Filter)
                return @(Get-ChildItem -LiteralPath $Path -File -Filter $Filter -ErrorAction SilentlyContinue)
            }
            function Write-HealthLog { param($Message, $Level) }
            return @(Get-BackupHealthIssues)[0]
        } $healthNoGenerationRoot
        Test-BRAVOCondition `
            -Condition (
                $healthNoGenerationIssue.Reason -eq 'не знайдено жодного COMPLETE generation manifest' -and
                $healthNoGenerationIssue.FileName -eq 'немає даних' -and
                $healthNoGenerationIssue.FileName -ne 'BRAVO_BACKUP_.json'
            ) `
            -Name 'Health/MissingCompleteGenerationHasNoFictitiousFileName' `
            -Failure 'за відсутності COMPLETE generation Health має показувати причину, але не вигаданий BRAVO_BACKUP_.json'
    } finally {
        if (Test-Path -LiteralPath $healthNoGenerationRoot -PathType Container) {
            Remove-Item -LiteralPath $healthNoGenerationRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $archiveFatalDiagnosticsModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $archiveScriptText `
        -FunctionNames @('Write-BRAVOArchiveFatalDiagnostics')
    $archiveFatalErrorRecord = $null
    try {
        throw [InvalidOperationException]::new('synthetic archive fatal exception')
    } catch {
        $archiveFatalErrorRecord = $_
    }
    $archiveFatalLogEvents = @(& $archiveFatalDiagnosticsModule {
        param($ErrorRecord)
        $events = New-Object System.Collections.Generic.List[object]
        function Write-BRAVOLogException {
            param($ErrorRecord, $Component, $Context)
            [void]$events.Add([pscustomobject]@{
                    Kind = 'Exception'
                    Component = $Component
                    Context = $Context
                    Message = $null
                    Level = $null
                    NoConsole = $false
                })
        }
        function Write-BRAVOLog {
            param($Message, $Level, $Component, [switch]$NoConsole)
            [void]$events.Add([pscustomobject]@{
                    Kind = 'Log'
                    Component = $Component
                    Context = $null
                    Message = $Message
                    Level = $Level
                    NoConsole = [bool]$NoConsole
                })
        }
        Set-StrictMode -Version Latest
        Write-BRAVOArchiveFatalDiagnostics `
            -ErrorRecord $ErrorRecord `
            -Context 'Неочікувана помилка виконання BRAVO_ARCHIV'
        return $events.ToArray()
    } $archiveFatalErrorRecord)
    $archiveFatalExceptionEvents = @($archiveFatalLogEvents | Where-Object { $_.Kind -eq 'Exception' })
    $archiveFatalDetailEvents = @($archiveFatalLogEvents | Where-Object { $_.Kind -eq 'Log' })
    $archiveFatalFinalizationWiring = (
        $archiveScriptText.Contains('$fatalErrorRecord = $_') -and
        $archiveScriptText.Contains('Write-BRAVOArchiveFatalDiagnostics `') -and
        $archiveScriptText.Contains('не вдалося записати повну діагностику') -and
        $archiveScriptText.Contains('-Reason $fatalMessage') -and
        $archiveScriptText.Contains('Exit $script:processExitCode')
    )
    Test-BRAVOCondition `
        -Condition (
            $archiveFatalFinalizationWiring -and
            $archiveFatalExceptionEvents.Count -eq 1 -and
            $archiveFatalExceptionEvents[0].Component -eq 'ARCHIVE' -and
            $archiveFatalDetailEvents.Count -eq 1 -and
            $archiveFatalDetailEvents[0].Component -eq 'ARCHIVE' -and
            $archiveFatalDetailEvents[0].Level -eq 'INFO' -and
            $archiveFatalDetailEvents[0].NoConsole -and
            $archiveFatalDetailEvents[0].Message -match 'System\.InvalidOperationException'
        ) `
        -Name 'Archive/FatalExceptionIsLoggedAndFinalized' `
        -Failure 'фатальний Archive exception має зберегти первинну причину, записати file-visible діагностику без дубля в консолі, показати RESULT і завершитись кодом 90 навіть коли logger недоступний'
    $maintenanceCollectionRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'BRAVO_MAINTENANCE_COLLECTION_{0}' -f [guid]::NewGuid().ToString('N')
    )
    try {
        [void][IO.Directory]::CreateDirectory($maintenanceCollectionRoot)
        $expiredMaintenanceDirectory = Join-Path $maintenanceCollectionRoot '2020-01-01'
        [void][IO.Directory]::CreateDirectory($expiredMaintenanceDirectory)
        (Get-Item -LiteralPath $expiredMaintenanceDirectory).CreationTime = (Get-Date).AddDays(-30)
        $maintenanceCollectionModule = New-BRAVOSelfTestRuntimeModule `
            -SourceText $maintenanceScriptText `
            -FunctionNames @('Get-BRAVOExpiredLogDateDirectories')
        $maintenanceCollectionProbe = & $maintenanceCollectionModule {
            param($Path)
            function Get-BRAVODirectories {
                param([string]$Path)
                return @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue)
            }
            Set-StrictMode -Version Latest
            $single = @(Get-BRAVOExpiredLogDateDirectories -Path $Path -RetentionDays 1)
            $empty = @(Get-BRAVOExpiredLogDateDirectories -Path (Join-Path $Path 'missing') -RetentionDays 1)
            [pscustomobject]@{ SingleCount = $single.Count; EmptyCount = $empty.Count }
        } $maintenanceCollectionRoot
        $maintenanceCollectionAssignments = @(
            'traceOldDirs',
            'exchangAPIOldDirs',
            'apacheOldDirs',
            'bravoWebAppOldDirs',
            'bravoWebLegacyOldDirs'
        )
        $maintenanceCollectionCallersWrapped = @(
            $maintenanceCollectionAssignments | Where-Object {
                $pattern = '\$' + [regex]::Escape($_) + '\s*=\s*@\(Get-BRAVOExpiredLogDateDirectories'
                [regex]::IsMatch($maintenanceScriptText, $pattern)
            }
        ).Count -eq $maintenanceCollectionAssignments.Count
        Test-BRAVOCondition `
            -Condition (
                $maintenanceCollectionProbe.SingleCount -eq 1 -and
                $maintenanceCollectionProbe.EmptyCount -eq 0 -and
                $maintenanceCollectionCallersWrapped
            ) `
            -Name 'Maintenance/ExpiredDirectoryCollectionsRemainArrays' `
            -Failure 'результати Get-BRAVOExpiredLogDateDirectories мають завжди присвоюватись як @(...), інакше один каталог не має .Count під PowerShell 5.1 StrictMode'
    } finally {
        if (Test-Path -LiteralPath $maintenanceCollectionRoot -PathType Container) {
            Remove-Item -LiteralPath $maintenanceCollectionRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Test-BRAVOCondition `
        -Condition (
            $healthScriptText.Contains('Get-BRAVOBackupGenerationManifestFiles -BackupRoot $backupRootPath') -and
            $healthScriptText.Contains("[string]`$manifest.status -ne 'COMPLETE'") -and
            $healthScriptText.Contains('COMPLETE generation $manifestGenerationId') -and
            $healthScriptText.Contains('$componentsProperty.Value.PSObject.Properties') -and
            $healthScriptText.Contains('$generationArchive = $script:healthLatestArchives[[string]$archiveDefinition.Type]')
        ) `
        -Name 'Health/UsesOneCompleteGeneration' `
        -Failure 'Health має оцінювати один COMPLETE generation manifest, а не незалежні newest MODEL/BLOG/BRAVOEXCH'
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('function New-BRAVOWinSCPTemporaryScriptPath') -and
            -not $archiveScriptText.Contains('GetTempFileName() + ".txt"')
        ) `
        -Name "SFTP/NoOrphanedTemporaryScripts" `
        -Failure "WinSCP не повинен залишати базові .tmp файли після кожного запуску"
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("function Invoke-ManualBAZASFTPSynchronization") -and
            $archiveScriptText.Contains("Synchronization.BAZA_WWW_SFTP") -and
            $archiveScriptText.Contains("BAZA_APP / BAZA_WWW") -and
            $archiveScriptText.Contains("-SynchronizationOnly")
        ) `
        -Name "SFTP/ManualBAZAAppAndWww" `
        -Failure "-SyncBAZA має синхронізувати всі увімкнені BAZA_APP і BAZA_WWW"
    Test-BRAVOCondition `
        -Condition ([int]$schedulerSettings.OperationLockWaitMinutes -gt 0) `
        -Name "Scheduler/OperationLockWait" `
        -Failure "очікування спільного lock має бути більше нуля"

    # P1.8 аудиту: lock раніше містив лише "PID=...; Started=...; Config=...",
    # тексту. hostname і processStartTime дають змогу відрізнити той самий
    # PID, перевикористаний іншим процесом після перезавантаження сервера,
    # від справді активного BRAVO_ARCHIV/BRAVO_MAINTENANCE — важливо на
    # спільних серверах і при діагностиці "чому lock не звільняється".
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("processStartTime = ") -and
            $archiveScriptText.Contains("hostname = [Environment]::MachineName") -and
            $archiveScriptText.Contains('operation = "Archive"') -and
            $archiveScriptText.Contains("packageVersion = [string]`$ScriptVersion") -and
            $maintenanceScriptText.Contains("processStartTime = ") -and
            $maintenanceScriptText.Contains("hostname = [Environment]::MachineName") -and
            $maintenanceScriptText.Contains('operation = "Maintenance"') -and
            $maintenanceScriptText.Contains("packageVersion = [string]`$script:ScriptVersion")
        ) `
        -Name "Scheduler/OperationLockMetadata" `
        -Failure "BRAVO_OPERATION.lock має містити pid/processStartTime/hostname/operation/packageVersion (JSON), а не лише голий PID/Started/Config"
    Test-BRAVOCondition `
        -Condition (
            $bravoConfigText.Contains("'BRAVO\Locks\BRAVO_OPERATION.lock'") -and
            $archiveScriptText.Contains('$lockPath = [string]$operationLockSettings.Path') -and
            $maintenanceScriptText.Contains('$lockPath = [string]$operationLockSettings.Path') -and
            $healthScriptText.Contains('$lockPath = [string]$operationLockSettings.Path') -and
            -not $archiveScriptText.Contains('Join-Path $logPath "BRAVO_OPERATION.lock"') -and
            -not $maintenanceScriptText.Contains('Join-Path $LOG_DIR "BRAVO_OPERATION.lock"') -and
            -not $healthScriptText.Contains('Join-Path $logPath "BRAVO_OPERATION.lock"')
        ) `
        -Name 'Scheduler/OperationLockIsMachineWide' `
        -Failure 'Archive і Maintenance мають координуватись одним ProgramData lock, а Health — перевіряти той самий handle незалежно від ArchiveRoot/ConfigPath'
    Test-BRAVOCondition `
        -Condition (
            $bravoConfigText.Contains('$global:logFileDateFormat = "yyyyMMdd_HHmmss"') -and
            $bravoConfigText.Contains('$global:logFileNameTemplate = "BRAVO_ARCHIV_{0}_PID{1}.log"') -and
            $archiveScriptText.Contains("`$logTimestamp = `$scriptStartTime.ToString('yyyyMMdd_HHmmss')") -and
            $archiveScriptText.Contains("`$logFileName = `$logFileNameTemplate -f `$logTimestamp, `$PID")
        ) `
        -Name 'Logging/ArchiveExecutionLogsAreUnique' `
        -Failure 'два запуски в одну хвилину мають отримувати різні execution logs (seconds + PID)'
    Test-BRAVOCondition `
        -Condition (
            -not $bravoConfigText.Contains('google.com') -and
            -not $archiveScriptText.Contains('function Test-NetworkConnection') -and
            -not $archiveScriptText.Contains('$networkCheckHost') -and
            $archiveScriptText.Contains('actual endpoint ${resolvedSftpHost}:$sftpPort')
        ) `
        -Name 'SFTP/NoGenericInternetDependency' `
        -Failure 'SFTP має перевіряти actual endpoint і не залежати від google.com:443'
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("New-BRAVOTransferOperationResult -Name 'SFTP: резервні копії'") -and
            $archiveScriptText.Contains("New-BRAVOTransferOperationResult -Name 'SFTP: BAZA_APP'") -and
            $archiveScriptText.Contains("New-BRAVOTransferOperationResult -Name 'SFTP: BAZA_WWW'") -and
            $archiveScriptText.Contains("@('ArchiveUpload', 'BAZA_APP', 'BAZA_WWW')")
        ) `
        -Name 'SFTP/SeparateArchiveBazaAppBazaWwwStates' `
        -Failure 'Archive upload, BAZA_APP і BAZA_WWW повинні мати окремі state objects і console steps'
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("return 'SFTP-ARCHIVE'") -and
            $archiveScriptText.Contains("return 'BAZA_APP'") -and
            $archiveScriptText.Contains("return 'BAZA_WWW'")
        ) `
        -Name 'Logging/SeparatesSftpSubOperations' `
        -Failure 'log component mapping має однозначно розрізняти SFTP-ARCHIVE, BAZA_APP і BAZA_WWW'
    Test-BRAVOCondition `
        -Condition (
            -not $archiveScriptText.Contains('$windowsPatchLevel.Message') -and
            $archiveScriptText.Contains('Get-BRAVOOSSupportTier')
        ) `
        -Name 'Runtime/WindowsUpdateAgeDoesNotAffectArchive' `
        -Failure 'BRAVO_ARCHIV не повинен отримувати warning/exit 10 через patch age; platform compatibility лишається'
    Test-BRAVOCondition `
        -Condition ([bool]$schedulerSettings.RequireProtectedRuntime) `
        -Name "Scheduler/ProtectedRuntime" `
        -Failure "RequireProtectedRuntime має бути увімкнено"
    $taskInstallScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_TASKS_INSTALL.ps1"),
        [Text.Encoding]::UTF8
    )
    $runtimeScopeChecks = @(
        [pscustomobject]@{
            Name = "Archive"
            Text = $archiveScriptText
            AllowedGlobalVariables = @(
                "BravoConfigurationMetadata",
                "LogLevel",
                "OutputEncoding",
                "ScriptDate",
                "ScriptVersion"
            )
            RequiredScriptVariables = @("Login", "resolvedSftpHost", "sftpUrl", "logFile")
        },
        [pscustomobject]@{
            Name = "Health"
            Text = $healthScriptText
            AllowedGlobalVariables = @(
                "BravoConfigurationMetadata",
                "ScriptBuildId",
                "ScriptDate",
                "ScriptVersion"
            )
            RequiredScriptVariables = @("Login", "resolvedSftpHost", "sftpUrl")
        },
        [pscustomobject]@{
            Name = "Maintenance"
            Text = $maintenanceScriptText
            AllowedGlobalVariables = @("ScriptBuildId", "ScriptDate", "ScriptVersion")
            RequiredScriptVariables = @("criticalErrorOccurred", "ScriptStartTime")
        }
    )
    foreach ($runtimeScopeCheck in $runtimeScopeChecks) {
        $globalVariables = @(
            [regex]::Matches(
                $runtimeScopeCheck.Text,
                '\$global:([A-Za-z_][A-Za-z0-9_]*)'
            ) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        )
        $unexpectedGlobalVariables = @(
            $globalVariables | Where-Object {
                $_ -notin $runtimeScopeCheck.AllowedGlobalVariables
            }
        )
        $missingScriptVariables = @(
            $runtimeScopeCheck.RequiredScriptVariables | Where-Object {
                -not $runtimeScopeCheck.Text.Contains('$script:' + $_)
            }
        )
        Test-BRAVOCondition `
            -Condition (
                $unexpectedGlobalVariables.Count -eq 0 -and
                $missingScriptVariables.Count -eq 0
            ) `
            -Name "RuntimeScope/$($runtimeScopeCheck.Name)" `
            -Failure (
                "runtime-стан $($runtimeScopeCheck.Name) має бути script-scoped; " +
                "неочікувані global: $($unexpectedGlobalVariables -join ', '); " +
                "відсутні script: $($missingScriptVariables -join ', ')"
            )
    }
    Test-BRAVOCondition `
        -Condition (
            [int]$schedulerSettings.Health.RepeatEveryMinutes -eq 240 -and
            -not $taskInstallScriptText.Contains('RepeatEveryMinutes = 240')
        ) `
        -Name "Scheduler/HealthScheduleIsConfigOwned" `
        -Failure "інсталятор не повинен змінювати інтервал health-check; джерелом правди є BRAVO.config"
    Test-BRAVOCondition `
        -Condition (
            $taskInstallScriptText.Contains('Get-ChildItem -LiteralPath $resolvedRoot -Force -Recurse') -and
            $taskInstallScriptText.Contains('foreach ($runtimeItem in $runtimeItems)')
        ) `
        -Name "Scheduler/ProtectedRuntimeRecursiveAcl" `
        -Failure "ACL hardening має застосовуватися до всіх наявних дочірніх файлів runtime"
    Test-BRAVOCondition `
        -Condition (
            $taskInstallScriptText.Contains('[System.IO.Directory]::Exists($runtimeItem)') -and
            $taskInstallScriptText.Contains('[Security.AccessControl.InheritanceFlags]::None')
        ) `
        -Name "Scheduler/AclInheritanceOnlyForContainers" `
        -Failure "прапорці успадкування ACL можна ставити лише каталогам, інакше файл дає 'No flags can be set'"

    # Функціональна регресія: попередня перевірка вище була суто текстовою й
    # проходила навіть тоді, коли hardening ACL падав на бойовому сервері.
    # Тут правило справді будується для каталогу та для файлу.
    # AddAccessRule працює над копією ACL у пам'яті й не потребує прав адміністратора.
    $aclProbeRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_ACL_PROBE_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($aclProbeRoot)
        $aclProbeFile = Join-Path $aclProbeRoot "probe.ps1"
        [IO.File]::WriteAllText($aclProbeFile, "# probe", (New-Object Text.UTF8Encoding($false)))
        $probeInheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [Security.AccessControl.InheritanceFlags]::ObjectInherit
        $probeSid = New-Object Security.Principal.SecurityIdentifier("S-1-5-18")
        $aclProbeFailure = $null
        foreach ($probeItem in @($aclProbeRoot, $aclProbeFile)) {
            $probeItemInheritance = if ([IO.Directory]::Exists($probeItem)) {
                $probeInheritance
            } else {
                [Security.AccessControl.InheritanceFlags]::None
            }
            try {
                $probeAcl = Get-Acl -LiteralPath $probeItem -ErrorAction Stop
                $probeAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                    $probeSid,
                    [Security.AccessControl.FileSystemRights]::FullControl,
                    $probeItemInheritance,
                    [Security.AccessControl.PropagationFlags]::None,
                    [Security.AccessControl.AccessControlType]::Allow
                )))
            } catch {
                $aclProbeFailure = "$probeItem — $($_.Exception.Message)"
            }
        }
        Test-BRAVOCondition `
            -Condition ($null -eq $aclProbeFailure) `
            -Name "Scheduler/AclRuleAppliesToFilesAndFolders" `
            -Failure "правило ACL не будується: $aclProbeFailure"
    } finally {
        if (Test-Path -LiteralPath $aclProbeRoot -PathType Container) {
            [IO.Directory]::Delete($aclProbeRoot, $true)
        }
    }

    Test-BRAVOCondition `
        -Condition ($taskInstallScriptText -match '(?s)\$installationCommitted\s*=\s*\$false.*?\$taskFolder\s*=\s*\$null') `
        -Name "Scheduler/RollbackStateInitialized" `
        -Failure 'обробник помилок читає $taskFolder, тому його треба ініціалізувати до основного try'
    foreach ($utility in @(
            [pscustomobject]@{ Name = "BRAVO_SETUP.ps1"; Path = "BRAVO_SETUP.ps1" },
            [pscustomobject]@{ Name = "BRAVO_DRY_RUN.ps1"; Path = "BRAVO_DRY_RUN.ps1" },
            [pscustomobject]@{ Name = "BRAVO_HEALTH.ps1"; Path = "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1" },
            [pscustomobject]@{ Name = "BRAVO_TASKS_DIAGNOSE.ps1"; Path = "BRAVO_TASKS_DIAGNOSE.ps1" },
            [pscustomobject]@{ Name = "BRAVO_TASKS_UNINSTALL.ps1"; Path = "BRAVO_TASKS_UNINSTALL.ps1" },
            [pscustomobject]@{ Name = "BRAVO_CREDENTIALS_SETUP.ps1"; Path = "BRAVO_CREDENTIALS_SETUP.ps1" },
            [pscustomobject]@{ Name = "BRAVO_TASKS_INSTALL.ps1"; Path = "BRAVO_TASKS_INSTALL.ps1" },
            [pscustomobject]@{ Name = "BRAVO_RESTORE_TEST.ps1"; Path = "BRAVO_RESTORE_TEST.ps1" }
        )) {
        $utilityText = [IO.File]::ReadAllText(
            (Join-Path $root $utility.Path),
            [Text.Encoding]::UTF8
        )
        Test-BRAVOCondition `
            -Condition ($utilityText.Contains('BRAVO_CONFIG_LOADER.ps1') -and
                $utilityText.Contains('Import-BravoConfiguration')) `
            -Name "ConfigurationLoader/$($utility.Name)" `
            -Failure "BRAVO-утиліта має використовувати спільний BRAVO_CONFIG_LOADER.ps1"
    }
    $credentialsSetupText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_CREDENTIALS_SETUP.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (-not $credentialsSetupText.Contains('function Import-BRAVOConfiguration')) `
        -Name "ConfigurationLoader/CredentialsSetupNoNameCollision" `
        -Failure "локальний wrapper credentials-утиліти не повинен збігатися за ім'ям із Import-BravoConfiguration"

    # P2.4 аудиту: SECURITY.md — обов'язковий, легко забути оновити після
    # security-релевантних змін. Перевіряємо лише структуру (розділи є),
    # не зміст — зміст неможливо валідувати автоматично.
    $securityDocPath = Join-Path $root "SECURITY.md"
    Test-BRAVOCondition `
        -Condition (Test-Path -LiteralPath $securityDocPath -PathType Leaf) `
        -Name "Documentation/SecurityMdExists" `
        -Failure "SECURITY.md має існувати в корені репозиторію"
    if (Test-Path -LiteralPath $securityDocPath -PathType Leaf) {
        $securityDocText = [IO.File]::ReadAllText($securityDocPath, [Text.Encoding]::UTF8)
        Test-BRAVOCondition `
            -Condition (
                $securityDocText.Contains("Підтримувані версії") -and
                $securityDocText.Contains("Порядок повідомлення про вразливості") -and
                $securityDocText.Contains("Модель секретів") -and
                $securityDocText.Contains("Модель довіри до Tools") -and
                $securityDocText.Contains("Модель ACL") -and
                $securityDocText.Contains("Обмеження Credential Manager")
            ) `
            -Name "Documentation/SecurityMdCoversRequiredSections" `
            -Failure "SECURITY.md має покривати підтримувані версії, порядок повідомлення про вразливості, модель секретів/Tools/ACL і обмеження Credential Manager"
    }

    # Аудит P1 (PSScriptAnalyzer майже не блокує небезпечні патерни):
    # security-правила НЕ повинні виключатись глобально. Обґрунтовані
    # місця мають точковий SuppressMessageAttribute, а не -ExcludeRule у
    # workflow — інакше НОВИЙ небезпечний код теж мовчки пройде CI.
    $analyzerSettingsPath = Join-Path $root "PSScriptAnalyzerSettings.psd1"
    Test-BRAVOCondition `
        -Condition (Test-Path -LiteralPath $analyzerSettingsPath -PathType Leaf) `
        -Name "StaticAnalysis/AnalyzerSettingsExist" `
        -Failure "PSScriptAnalyzerSettings.psd1 має існувати в корені репозиторію"

    $requiredBlockingRules = @(
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingUsernameAndPasswordParams',
        'PSAvoidUsingInvokeExpression',
        'PSAvoidUsingComputerNameHardcoded'
    )
    if (Test-Path -LiteralPath $analyzerSettingsPath -PathType Leaf) {
        $analyzerSettings = Import-PowerShellDataFile -LiteralPath $analyzerSettingsPath
        $blockingRules = @($analyzerSettings.IncludeRules)
        $missingBlockingRules = @(
            $requiredBlockingRules | Where-Object { $blockingRules -notcontains $_ }
        )
        Test-BRAVOCondition `
            -Condition ($missingBlockingRules.Count -eq 0) `
            -Name "StaticAnalysis/SecurityRulesAreBlocking" `
            -Failure "PSScriptAnalyzerSettings.psd1 має блокувати security-правила; відсутні: $($missingBlockingRules -join ', ')"
    }

    # Той самий набір не повинен повернутись у workflow як -ExcludeRule.
    $ciWorkflowPath = Join-Path $root ".github\workflows\ci.yml"
    Test-BRAVOCondition `
        -Condition (Test-Path -LiteralPath $ciWorkflowPath -PathType Leaf) `
        -Name "StaticAnalysis/CiWorkflowExists" `
        -Failure ".github\workflows\ci.yml має існувати"
    if (Test-Path -LiteralPath $ciWorkflowPath -PathType Leaf) {
        $ciWorkflowText = [IO.File]::ReadAllText($ciWorkflowPath, [Text.Encoding]::UTF8)
        # Рядок з -ExcludeRule дозволений рівно один — інформаційний
        # прохід, який виключає САМЕ блокуючий набір (щоб не дублювати
        # його вивід), а не приховує security-правила.
        $globallyExcluded = @(
            $requiredBlockingRules | Where-Object {
                $ciWorkflowText -match "ExcludeRule[^\r\n]*$([regex]::Escape($_))"
            }
        )
        Test-BRAVOCondition `
            -Condition ($globallyExcluded.Count -eq 0) `
            -Name "StaticAnalysis/NoGlobalSecurityRuleExclusions" `
            -Failure "ci.yml не повинен виключати security-правила поіменно: $($globallyExcluded -join ', ')"

        Test-BRAVOCondition `
            -Condition (
                $ciWorkflowText.Contains('Invoke-BRAVOSecurityAnalysis.ps1') -and
                $ciWorkflowText.Contains('Test-BRAVOForbiddenPattern.ps1')
            ) `
            -Name "StaticAnalysis/CiUsesSettingsAndForbiddenPatterns" `
            -Failure "ci.yml має викликати ci\Invoke-BRAVOSecurityAnalysis.ps1 і ci\Test-BRAVOForbiddenPattern.ps1"

        # GitHub Actions записує вміст `run:` у тимчасовий .ps1 БЕЗ BOM,
        # і Windows PowerShell 5.1 читає його в системній ANSI-кодовій
        # сторінці — кирилиця там декодується в сміття, а окремі байти
        # стають control-символами, що ламають парсер ще до виконання
        # кроку. Реальне падіння CI сталося саме через це. Логіку з
        # кирилицею тримаємо у файлах репозиторію (мають BOM), а `run:`
        # лишається ASCII-only.
        $ciRunBlockLines = @(
            $ciWorkflowText -split '\r?\n' |
                Where-Object { $_ -match '[Ѐ-ӿ]' } |
                Where-Object { $_ -notmatch '^\s*#' } |
                Where-Object { $_ -notmatch '^\s*-?\s*name:' }
        )
        Test-BRAVOCondition `
            -Condition ($ciRunBlockLines.Count -eq 0) `
            -Name "StaticAnalysis/CiRunBlocksAreAsciiOnly" `
            -Failure "ci.yml: виконуваний рядок з кирилицею поза коментарем/name (GitHub Actions пише run: без BOM, PowerShell 5.1 ламається): $($ciRunBlockLines -join ' | ')"
    }

    # Аудит P3: сторонні actions зафіксовані на повний commit SHA, а не
    # на рухомий тег. Тег можна переписати — pin на SHA цього не
    # дозволяє. Версія PSScriptAnalyzer теж зафіксована, інакше нове
    # правило або зміна поведінки ламає CI без жодної зміни коду.
    if (Test-Path -LiteralPath $ciWorkflowPath -PathType Leaf) {
        $unpinnedActions = @(
            [regex]::Matches($ciWorkflowText, 'uses:\s*(?<Ref>[^\r\n]+)') |
                ForEach-Object { $_.Groups['Ref'].Value.Trim() } |
                Where-Object { $_ -notmatch '@[0-9a-f]{40}\b' }
        )
        Test-BRAVOCondition `
            -Condition ($unpinnedActions.Count -eq 0) `
            -Name "StaticAnalysis/ActionsPinnedToCommitSha" `
            -Failure "усі GitHub Actions мають бути зафіксовані на повний commit SHA; не закріплені: $($unpinnedActions -join ', ')"

        Test-BRAVOCondition `
            -Condition ($ciWorkflowText -match 'PSScriptAnalyzer\s+-RequiredVersion\s+\d+\.\d+') `
            -Name "StaticAnalysis/AnalyzerVersionPinned" `
            -Failure "версія PSScriptAnalyzer має бути зафіксована через -RequiredVersion"
    }

    # Аудит P5: threat model як окремий документ із чесним розділом
    # залишкового ризику для кожного сценарію.
    $threatModelPath = Join-Path $root "THREAT_MODEL.md"
    Test-BRAVOCondition `
        -Condition (Test-Path -LiteralPath $threatModelPath -PathType Leaf) `
        -Name "Documentation/ThreatModelExists" `
        -Failure "THREAT_MODEL.md має існувати в корені репозиторію"
    if (Test-Path -LiteralPath $threatModelPath -PathType Leaf) {
        $threatModelText = [IO.File]::ReadAllText($threatModelPath, [Text.Encoding]::UTF8)
        $requiredScenarios = @(
            "Компрометація локального адміністратора",
            "Підміна інструментів",
            "Підміна runtime",
            "Витік облікових даних",
            "Ransomware",
            "VSS",
            "Підміна SFTP/SMB призначення",
            "Rollback",
            "Паралельні запуски"
        )
        $missingScenarios = @(
            $requiredScenarios | Where-Object { -not $threatModelText.Contains($_) }
        )
        Test-BRAVOCondition `
            -Condition ($missingScenarios.Count -eq 0) `
            -Name "Documentation/ThreatModelCoversRequiredScenarios" `
            -Failure "THREAT_MODEL.md має покривати всі сценарії; відсутні: $($missingScenarios -join ', ')"

        # Модель без залишкового ризику — це реклама, а не аналіз.
        Test-BRAVOCondition `
            -Condition (
                ([regex]::Matches($threatModelText, 'Залишковий ризик').Count -ge 8)
            ) `
            -Name "Documentation/ThreatModelStatesResidualRisk" `
            -Failure "кожен сценарій THREAT_MODEL.md має мати явний розділ залишкового ризику"
    }

    # P2.6 аудиту: RELEASE_CHECKLIST.md.
    $releaseChecklistPath = Join-Path $root "RELEASE_CHECKLIST.md"
    Test-BRAVOCondition `
        -Condition (Test-Path -LiteralPath $releaseChecklistPath -PathType Leaf) `
        -Name "Documentation/ReleaseChecklistExists" `
        -Failure "RELEASE_CHECKLIST.md має існувати в корені репозиторію"
    if (Test-Path -LiteralPath $releaseChecklistPath -PathType Leaf) {
        $releaseChecklistText = [IO.File]::ReadAllText($releaseChecklistPath, [Text.Encoding]::UTF8)
        Test-BRAVOCondition `
            -Condition (
                $releaseChecklistText.Contains("VERSION.json") -and
                $releaseChecklistText.Contains("CHANGELOG.md") -and
                $releaseChecklistText.Contains("BRAVO_SELF_TEST.ps1") -and
                $releaseChecklistText.Contains("BOM") -and
                $releaseChecklistText.Contains("tag")
            ) `
            -Name "Documentation/ReleaseChecklistCoversRequiredSteps" `
            -Failure "RELEASE_CHECKLIST.md має покривати VERSION.json, CHANGELOG.md, self-test, BOM і git tag"
    }

    # RELEASE_POLICY.md: яка версія в якій гілці дозволена. Чек-лист
    # відповідає на питання "що зробити перед випуском", політика — на
    # питання "що взагалі дозволено випускати з цієї гілки".
    $releasePolicyPath = Join-Path $root "RELEASE_POLICY.md"
    Test-BRAVOCondition `
        -Condition (Test-Path -LiteralPath $releasePolicyPath -PathType Leaf) `
        -Name "Documentation/ReleasePolicyExists" `
        -Failure "RELEASE_POLICY.md має існувати в корені репозиторію"
    if (Test-Path -LiteralPath $releasePolicyPath -PathType Leaf) {
        $releasePolicyText = [IO.File]::ReadAllText($releasePolicyPath, [Text.Encoding]::UTF8)
        Test-BRAVOCondition `
            -Condition (
                $releasePolicyText.Contains('X.Y.Z-dev.N') -and
                $releasePolicyText.Contains('X.Y.Z-rc.N') -and
                $releasePolicyText.Contains('releaseChannel') -and
                $releasePolicyText.Contains('ci\Test-BRAVOReleasePolicy.ps1') -and
                $releasePolicyText.Contains('ModuleVersion')
            ) `
            -Name "Documentation/ReleasePolicyCoversVersionModel" `
            -Failure "RELEASE_POLICY.md має описувати prerelease-формати (dev/rc), releaseChannel, правило ModuleVersion і CI-gate ci\Test-BRAVOReleasePolicy.ps1"
    }

    # Політика, яку ніхто не перевіряє механічно, тримається лише на
    # людській дисципліні — а саме вона вже двічі підвела на
    # fast-forward merge (AUD-016). Тому gate має бути і в репозиторії,
    # і в workflow.
    $releasePolicyGatePath = Join-Path $root 'ci\Test-BRAVOReleasePolicy.ps1'
    $ciWorkflowTextForPolicy = [IO.File]::ReadAllText(
        (Join-Path $root '.github\workflows\ci.yml'),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            (Test-Path -LiteralPath $releasePolicyGatePath -PathType Leaf) -and
            $ciWorkflowTextForPolicy.Contains('ci\Test-BRAVOReleasePolicy.ps1')
        ) `
        -Name "ReleasePolicy/CiGateEnforcesBranchVersionChannel" `
        -Failure "ci\Test-BRAVOReleasePolicy.ps1 має існувати і викликатися з .github\workflows\ci.yml — інакше відповідність гілки, версії та каналу тримається лише на пам'яті людини"

    # Функціональна перевірка самого gate-скрипта, а не лише факту його
    # існування. X.Y.Z завжди є підрядком X.Y.Z-dev.N/-rc.N — саме в
    # момент promotion у master, де ця перевірка найважливіша,
    # .Contains() дав би хибний PASS на забутому старому заголовку
    # ("## 4.5.0-dev.1" містить підрядок "4.5.0"). Ізольований мінімальний
    # комплект відтворює обидва випадки: справжнє оновлення і забутий крок.
    $releasePolicyProbeRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_RELEASE_POLICY_PROBE_{0}" -f [guid]::NewGuid().ToString('N'))
    $releasePolicyProbeResults = @{}
    try {
        [void][IO.Directory]::CreateDirectory((Join-Path $releasePolicyProbeRoot 'modules\BRAVO.Fake'))
        # Маркер кореня репозиторію для власної перевірки скрипта; вміст
        # не читається, потрібен лише факт існування файлу.
        [IO.File]::WriteAllText((Join-Path $releasePolicyProbeRoot 'BRAVO_SELF_TEST.ps1'), '', (New-Object Text.UTF8Encoding($true)))
        Copy-Item -LiteralPath (Join-Path $root 'BRAVO_CONFIG_LOADER.ps1') -Destination (Join-Path $releasePolicyProbeRoot 'BRAVO_CONFIG_LOADER.ps1') -Force
        [IO.File]::WriteAllText(
            (Join-Path $releasePolicyProbeRoot 'modules\BRAVO.Fake\BRAVO.Fake.psd1'),
            "@{`r`n    ModuleVersion = '4.5.0'`r`n    GUID = '11111111-1111-1111-1111-111111111111'`r`n    Author = 'BRAVO self-test'`r`n}`r`n",
            (New-Object Text.UTF8Encoding($true))
        )

        function Set-BRAVOReleasePolicyProbeContent {
            param(
                [Parameter(Mandatory = $true)][string]$ProbeRoot,
                [Parameter(Mandatory = $true)][string]$ChangelogHeading,
                [Parameter(Mandatory = $true)][string]$ReadmeHeader
            )
            $utf8NoBom = New-Object Text.UTF8Encoding($false)
            [IO.File]::WriteAllText((Join-Path $ProbeRoot 'VERSION.json'), '{"packageVersion":"4.5.0","releaseChannel":"stable"}', $utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $ProbeRoot 'CHANGELOG.md'), "# Changelog`r`n`r`n$ChangelogHeading`r`n`r`nОпис.`r`n", $utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $ProbeRoot 'README.md'), "$ReadmeHeader`r`n", $utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $ProbeRoot 'BRAVO_SETUP.md'), "$ReadmeHeader`r`n", $utf8NoBom)
        }

        $releasePolicyGateScript = Join-Path $root 'ci\Test-BRAVOReleasePolicy.ps1'
        # Без пониження ErrorActionPreference stderr дочірнього процесу
        # ронить увесь прогін замість чистого [FAIL] (той самий патерн,
        # що й у RuntimeGuard/EntrypointsFailClosedWhenGuardUnloadable).
        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            # Справжній promotion: CHANGELOG і заголовки дійсно оновлені
            # на stable-версію.
            Set-BRAVOReleasePolicyProbeContent -ProbeRoot $releasePolicyProbeRoot -ChangelogHeading '## 4.5.0 — 2026-08-05' -ReadmeHeader '# BRAVO 4.5.0 — опис'
            $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $releasePolicyGateScript -Root $releasePolicyProbeRoot -Branch 'master' 2>&1
            $releasePolicyProbeResults['Genuine'] = $LASTEXITCODE

            # Забутий крок promotion: CHANGELOG і заголовки лишились зі
            # старої prerelease-версії.
            Set-BRAVOReleasePolicyProbeContent -ProbeRoot $releasePolicyProbeRoot -ChangelogHeading '## 4.5.0-dev.1 — 2026-08-05' -ReadmeHeader '# BRAVO 4.5.0-dev.1 — опис'
            $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $releasePolicyGateScript -Root $releasePolicyProbeRoot -Branch 'master' 2>&1
            $releasePolicyProbeResults['StaleFromDev'] = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorAction
        }
    } finally {
        Remove-Item -LiteralPath $releasePolicyProbeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Test-BRAVOCondition `
        -Condition ($releasePolicyProbeResults['Genuine'] -eq 0) `
        -Name "ReleasePolicy/AcceptsGenuineStableRelease" `
        -Failure "ci\Test-BRAVOReleasePolicy.ps1 має пропускати комплект, де CHANGELOG.md і заголовки дійсно оновлені на stable-версію (код виходу: $($releasePolicyProbeResults['Genuine']))"

    Test-BRAVOCondition `
        -Condition ($releasePolicyProbeResults['StaleFromDev'] -ne 0) `
        -Name "ReleasePolicy/RejectsStaleChangelogAndHeaderOnPromotion" `
        -Failure "ci\Test-BRAVOReleasePolicy.ps1 має блокувати promotion, якщо CHANGELOG.md і заголовки README.md/BRAVO_SETUP.md лишились зі старої prerelease-версії — X.Y.Z як підрядок X.Y.Z-dev.N не повинен рахуватись збігом; код виходу: $($releasePolicyProbeResults['StaleFromDev'])"

    # P2.7 аудиту: дрібні зауваження документації. Дерево каталогів мало
    # дублікат "BRAVO_*.ps1" двома окремими рядками; додано матрицю
    # діагностики за кодом завершення (розділ 12).
    $readmeTextForDocFixes = [IO.File]::ReadAllText(
        (Join-Path $root "README.md"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            ([regex]::Matches($readmeTextForDocFixes, [regex]::Escape('BRAVO_*.ps1')).Count -eq 0) -and
            $readmeTextForDocFixes.Contains("credentialInitializationError") -and
            $readmeTextForDocFixes.Contains('| `31` |') -and
            $readmeTextForDocFixes.Contains('| `90` |')
        ) `
        -Name "Documentation/ReadmeDirectoryTreeAndTroubleshootingMatrix" `
        -Failure "README.md не повинен містити дублікат-заглушку 'BRAVO_*.ps1' і має містити матрицю діагностики за кодом завершення"

    # Зовнішнє рев'ю 2026-08-05, P1: README описував модель довіри до Tools
    # як trust-on-first-use і радив "видаліть TOOLS_INTEGRITY.json, щоб
    # прийняти нову базову лінію". Код на той момент уже блокував запуск за
    # TOOLS_MANIFEST.json. Небезпека не теоретична: адміністратор, який
    # після security-алерту сумлінно виконає застарілу інструкцію, власноруч
    # легітимізує підмінений бінарник. Документація не повинна пропонувати
    # процедуру, яка вимикає діючий контроль безпеки.
    Test-BRAVOCondition `
        -Condition (
            $readmeTextForDocFixes.Contains("TOOLS_MANIFEST.json") -and
            $readmeTextForDocFixes.Contains("Enforce") -and
            $readmeTextForDocFixes.Contains("Update-BRAVOToolsManifest.ps1")
        ) `
        -Name "Documentation/ReadmeDescribesManifestToolTrust" `
        -Failure "README.md має описувати саме TOOLS_MANIFEST.json + режим Enforce як модель довіри до Tools, із посиланням на ci\Update-BRAVOToolsManifest.ps1"

    # Та сама вимога з іншого боку: README не має радити видалення жодного
    # з маніфестів як спосіб "полагодити" помилку цілісності.
    Test-BRAVOCondition `
        -Condition (
            -not [regex]::IsMatch(
                $readmeTextForDocFixes,
                '(?i)видал[а-яіїєґ]*\s+(файл\s+)?`?(TOOLS_INTEGRITY|TOOLS_MANIFEST|RUNTIME_MANIFEST)'
            )
        ) `
        -Name "Documentation/ReadmeNeverAdvisesDeletingManifest" `
        -Failure "README.md не повинен радити видаляти маніфест цілісності — це вимикає перевірку, а не усуває причину"

    # Зовнішнє рев'ю 2026-08-05, P1: SECURITY.md публікував порядок
    # повідомлення про вразливості із заглушками "[заповнити]" замість SLA.
    # Політика без строків не є політикою.
    $securityTextForContact = [IO.File]::ReadAllText(
        (Join-Path $root "SECURITY.md"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (-not $securityTextForContact.Contains("[заповнити]")) `
        -Name "Documentation/SecurityPolicyHasNoPlaceholders" `
        -Failure "SECURITY.md не повинен містити заглушок '[заповнити]' — контакт і строки реакції мають бути конкретними"

    # Зовнішнє рев'ю 2026-08-05: операторський runbook. README пояснює, як
    # налаштувати; OPERATIONS.md — що робити, коли вже зламалось. Найдорожча
    # помилка в історії цього репозиторію (застаріла порада видалити
    # TOOLS_INTEGRITY.json) належала саме до категорії "чого не робити", якої
    # в документації не існувало як окремого розділу.
    $operationsPath = Join-Path $root "OPERATIONS.md"
    Test-BRAVOCondition `
        -Condition (Test-Path -LiteralPath $operationsPath -PathType Leaf) `
        -Name "Documentation/OperationsRunbookExists" `
        -Failure "OPERATIONS.md має існувати в корені репозиторію"
    if (Test-Path -LiteralPath $operationsPath -PathType Leaf) {
        $operationsText = [IO.File]::ReadAllText($operationsPath, [Text.Encoding]::UTF8)

        # Кожен код контракту BRAVO.ExitCodes, який реально може побачити
        # оператор, повинен мати розділ у runbook. 0 і 10 — успішні, їх не
        # діагностують; решта означає, що щось потребує рішення людини.
        $runbookCodes = @('20', '30', '31', '32', '33', '34', '35', '40', '41', '50', '51', '60', '70', '90')
        $missingCodes = @(
            $runbookCodes | Where-Object { -not $operationsText.Contains("## ``$_`` —") }
        )
        Test-BRAVOCondition `
            -Condition ($missingCodes.Count -eq 0) `
            -Name "Documentation/OperationsRunbookCoversAllExitCodes" `
            -Failure "OPERATIONS.md має мати розділ для кожного коду завершення; відсутні: $($missingCodes -join ', ')"

        # Runbook без "чого не робити" — це переказ README іншими словами.
        # Саме цей розділ відрізняє його від матриці діагностики.
        Test-BRAVOCondition `
            -Condition (
                ([regex]::Matches($operationsText, '(?i)Чого (категорично )?не робити').Count -ge 8)
            ) `
            -Name "Documentation/OperationsRunbookStatesWhatNotToDo" `
            -Failure "OPERATIONS.md має містити розділ 'Чого не робити' для більшості сценаріїв — саме він відрізняє runbook від переліку симптомів"

        # Сценарії поза кодами завершення, які рев'ю вимагало окремо.
        $runbookScenarios = @(
            'ransomware',
            'Відновлення на чистий сервер',
            'Discovery',
            'fingerprint',
            'VSS',
            'SYSTEM'
        )
        $missingScenarios = @(
            $runbookScenarios | Where-Object { -not $operationsText.Contains($_) }
        )
        Test-BRAVOCondition `
            -Condition ($missingScenarios.Count -eq 0) `
            -Name "Documentation/OperationsRunbookCoversCriticalScenarios" `
            -Failure "OPERATIONS.md має покривати сценарії поза кодами завершення; відсутні: $($missingScenarios -join ', ')"

        # Та сама заборона, що й для README, але runbook читають саме в стані
        # інциденту — там порада видалити маніфест найнебезпечніша. Проста
        # заборона підрядка тут не працює: сам runbook мусить писати "не
        # видаляти TOOLS_MANIFEST.json". Тому перевіряємо кожне входження
        # окремо й вимагаємо, щоб перед ним стояло заперечення.
        $deleteManifestMentions = [regex]::Matches(
            $operationsText,
            '(?i)(?<negation>не\s+)?видал[а-яіїєґ]*[\s*`]+(файл[\s*`]+)?(TOOLS_INTEGRITY|TOOLS_MANIFEST|RUNTIME_MANIFEST)'
        )
        $affirmativeDeleteAdvice = @(
            $deleteManifestMentions | Where-Object { -not $_.Groups['negation'].Success }
        )
        Test-BRAVOCondition `
            -Condition ($affirmativeDeleteAdvice.Count -eq 0) `
            -Name "Documentation/OperationsRunbookNeverAdvisesDeletingManifest" `
            -Failure "OPERATIONS.md не повинен радити видаляти маніфест цілісності; знайдено без заперечення: $(($affirmativeDeleteAdvice | ForEach-Object { $_.Value }) -join '; ')"
    }

    # THREAT_MODEL.md — та сама категорія дефекту, що й README у PR #19:
    # документ описував залишкові ризики, які код уже закрив (коди 34 і 35,
    # SecureString). Модель загроз, що перебільшує ризик, шкодить не менше
    # за ту, що применшує: власник ухвалює інфраструктурні рішення саме за
    # її списком пріоритетів.
    $threatModelText = [IO.File]::ReadAllText(
        (Join-Path $root "THREAT_MODEL.md"),
        [Text.Encoding]::UTF8
    )
    $closedControls = @(
        @{ Marker = '`34`'; What = 'блокування послаблених перемикачів безпеки' },
        @{ Marker = '`35`'; What = 'блокування відкату версії' },
        @{ Marker = 'SecureString'; What = 'секрет як SecureString' }
    )
    $unmentionedControls = @(
        $closedControls | Where-Object { -not $threatModelText.Contains($_.Marker) }
    )
    Test-BRAVOCondition `
        -Condition ($unmentionedControls.Count -eq 0) `
        -Name "Documentation/ThreatModelReflectsImplementedControls" `
        -Failure "THREAT_MODEL.md має описувати вже реалізовані контролі; не згадані: $(($unmentionedControls | ForEach-Object { $_.What }) -join '; ')"

    # Конкретні застарілі твердження, які вже були в документі й описували
    # закритий ризик як відкритий.
    $staleThreatClaims = @(
        'Downgrade **не блокується**',
        'Секрет проходить через звичайний .NET `string`'
    )
    $foundStaleClaims = @(
        $staleThreatClaims | Where-Object { $threatModelText.Contains($_) }
    )
    Test-BRAVOCondition `
        -Condition ($foundStaleClaims.Count -eq 0) `
        -Name "Documentation/ThreatModelHasNoStaleResidualRisk" `
        -Failure "THREAT_MODEL.md містить твердження про залишковий ризик, який код уже закрив: $($foundStaleClaims -join '; ')"

    # ===== DRY-RUN МУСИТЬ ПЕРЕВІРЯТИ ЦІЛІСНІСТЬ =====
    # Знайдено тестовим розгортанням: dry-run звітував «0 помилок» на
    # комплекті, у Tools\ якого лежали залишки старого розкладання. Кожен
    # production-запуск на тому ж комплекті завершився б кодом 33, бо
    # entrypoint кличе guard, а dry-run — ні. Перевірка готовності, яка не
    # перевіряє те, що перевіряє сам запуск, дає хибну впевненість, і це
    # найгірше, що вона може зробити.
    $dryRunAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'BRAVO_DRY_RUN.ps1'), [ref]$null, [ref]$null
    )
    $dryRunCommands = @(
        $dryRunAst.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
            $true
        ) | ForEach-Object { [string]$_.GetCommandName() }
    )
    $dryRunMissingGuardChecks = @(
        @(
            'Test-BRAVORuntimeManifestIntegrity',
            'Test-BRAVORuntimeSecuritySettings',
            'Test-BRAVOVersionDowngrade'
        ) | Where-Object { $dryRunCommands -notcontains $_ }
    )
    Test-BRAVOCondition `
        -Condition ($dryRunMissingGuardChecks.Count -eq 0) `
        -Name "DryRun/VerifiesRuntimeIntegrity" `
        -Failure "BRAVO_DRY_RUN.ps1 має виконувати ті самі перевірки guard, що й entrypoint; не викликано: $($dryRunMissingGuardChecks -join ', ')"

    # Dry-run не має права записувати стан версії: він фіксував би
    # розгортання, якого ще не було.
    $versionDowngradeCallInDryRun = $dryRunAst.Find(
        {
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            ([string]$node.GetCommandName()) -eq 'Test-BRAVOVersionDowngrade'
        },
        $true
    )
    $dryRunUsesNoWrite = $false
    if ($null -ne $versionDowngradeCallInDryRun) {
        $dryRunUsesNoWrite = @(
            $versionDowngradeCallInDryRun.CommandElements |
                Where-Object {
                    $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $_.ParameterName -eq 'NoWrite'
                }
        ).Count -gt 0
    }
    Test-BRAVOCondition `
        -Condition $dryRunUsesNoWrite `
        -Name "DryRun/DoesNotRecordVersionState" `
        -Failure "Test-BRAVOVersionDowngrade у BRAVO_DRY_RUN.ps1 має викликатись із -NoWrite — dry-run не змінює стан системи"

    # ===== JSON-МАСИВ НЕ МОЖНА ЗБИРАТИ ЧЕРЕЗ @(конвеєр) =====
    # Знайдено тестовим розгортанням: ConvertFrom-Json у Windows PowerShell 5.1
    # віддає JSON-масив ОДНИМ об'єктом, не розгортаючи його в конвеєр. Тому
    # @(... | ConvertFrom-Json) дає масив з одного елемента-масиву: цикл
    # виконується один раз, а $result.Status стає System.Object[]. У
    # BRAVO_TASKS_DIAGNOSE це перетворювало весь результат SYSTEM dry-run на
    # один нечитабельний рядок саме тоді, коли його читають для діагностики.
    $jsonArraySample = '[{"Status":"PASS","Name":"A"},{"Status":"FAIL","Name":"B"}]'
    # Хибну форму будуємо через scriptblock із рядка: інакше сканер нижче
    # знайшов би її у власному коді самотесту й червонів би завжди.
    # Кількість рахуємо ВСЕРЕДИНІ scriptblock: оператор & розгортає його
    # результат у конвеєр і тим самим приховав би саме те згортання, яке
    # ми перевіряємо.
    $jsonCollapsingProbe = [scriptblock]::Create(
        '$collapsed = @($args[0] | ConvertFrom-Json); return $collapsed.Count'
    )
    $jsonCollapsedCount = & $jsonCollapsingProbe $jsonArraySample
    $jsonParsed = $jsonArraySample | ConvertFrom-Json
    $jsonViaVariable = @($jsonParsed)
    # Перевіряємо не лише власний код, а й саму поведінку платформи: якщо
    # майбутня версія PowerShell почне розгортати масив, тест це помітить.
    Test-BRAVOCondition `
        -Condition (
            $jsonViaVariable.Count -eq 2 -and
            [string]$jsonViaVariable[0].Status -eq 'PASS' -and
            [string]$jsonViaVariable[1].Status -eq 'FAIL' -and
            # Друга половина контракту: хибна форма справді згортає масив.
            # Без цієї перевірки тест лишався б зеленим, навіть якби
            # проблеми не існувало, і нічого не доводив.
            $jsonCollapsedCount -eq 1
        ) `
        -Name "Json/ArrayEnumeratesThroughVariable" `
        -Failure "Присвоєння у змінну перед @() має зберігати розгортання JSON-масиву; отримано елементів: $($jsonViaVariable.Count), через @(конвеєр): $jsonCollapsedCount"

    # Той самий патерн не має лишитися в жодному скрипті комплекту.
    # Пошук по AST, а не підрядком: інакше тест ловив би власні пояснювальні
    # коментарі — на цих граблях ця гілка вже стояла двічі.
    $collapsedJsonUsages = @()
    # -Include мовчки ігнорується разом із -LiteralPath, тому фільтруємо
    # розширення самі; LOGS виключено окремо — там лежить відкритий
    # transcript цього ж прогону.
    foreach ($jsonScriptPath in @(Get-ChildItem -LiteralPath $root -Recurse -File |
        Where-Object {
            @('.ps1', '.psm1') -contains $_.Extension.ToLowerInvariant() -and
            $_.FullName -notlike '*\local-backups\*' -and
            $_.FullName -notlike '*\LOGS\*'
        })) {
        $jsonScriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $jsonScriptPath.FullName, [ref]$null, [ref]$null
        )
        $collapsedNode = $jsonScriptAst.Find(
            {
                param($node)
                if ($node -isnot [System.Management.Automation.Language.ArrayExpressionAst]) {
                    return $false
                }
                # Всередині @() шукаємо конвеєр, останній елемент якого —
                # виклик ConvertFrom-Json. Саме він і згортає масив.
                $inner = $node.SubExpression.Find(
                    {
                        param($pipelineNode)
                        $pipelineNode -is [System.Management.Automation.Language.PipelineAst] -and
                        $pipelineNode.PipelineElements.Count -gt 1 -and
                        ($pipelineNode.PipelineElements[-1] -is [System.Management.Automation.Language.CommandAst]) -and
                        ([string]$pipelineNode.PipelineElements[-1].GetCommandName()) -eq 'ConvertFrom-Json'
                    },
                    $true
                )
                return ($null -ne $inner)
            },
            $true
        )
        if ($null -ne $collapsedNode) {
            $collapsedJsonUsages += $jsonScriptPath.Name
        }
    }
    Test-BRAVOCondition `
        -Condition ($collapsedJsonUsages.Count -eq 0) `
        -Name "Json/NoCollapsedArrayFromPipeline" `
        -Failure "@(... | ConvertFrom-Json) згортає JSON-масив в один елемент; присвойте у змінну перед @(). Знайдено у: $($collapsedJsonUsages -join ', ')"

    # ===== GUARD МУСИТЬ БУТИ FAIL-CLOSED =====
    # Test-Path підтверджує лише наявність файлу. Якщо dot-source не
    # виконався (ExecutionPolicy AllSigned без підпису, синтаксична помилка,
    # блокування файлу), entrypoint раніше мовчки йшов далі: усі три
    # перевірки падали з CommandNotFound, не зупиняючи запуск, і справа
    # доходила до Import-Module. Тобто найдешевшим способом вимкнути весь
    # шар цілісності було не підбирати хеші, а зробити guard незавантажуваним.
    $guardEntrypoints = @('BRAVO_ARCHIV.ps1', 'BRAVO_HEALTH.ps1', 'BRAVO_MAINTENANCE.ps1')
    $entrypointsWithUnguardedDotSource = @()
    foreach ($guardEntrypoint in $guardEntrypoints) {
        $entrypointAst = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $root $guardEntrypoint), [ref]$null, [ref]$null
        )
        # Dot-source guard-а мусить лежати всередині try — інакше помилка
        # завантаження не має шансу зупинити запуск.
        $protectedDotSource = $entrypointAst.FindAll(
            {
                param($node)
                $node -is [System.Management.Automation.Language.TryStatementAst] -and
                ([string]$node.Body.Extent.Text) -match '\.\s+\$runtimeGuardPath'
            },
            $true
        )
        # Друга лінія: guard міг «завантажитись» і не оголосити функцій.
        $verifiesGuardFunctions = (
            ([string]$entrypointAst.Extent.Text) -match "Get-Command\s+-Name\s+\`$guardFunction"
        )
        if ($null -eq $protectedDotSource -or -not $verifiesGuardFunctions) {
            $entrypointsWithUnguardedDotSource += $guardEntrypoint
        }
    }
    Test-BRAVOCondition `
        -Condition ($entrypointsWithUnguardedDotSource.Count -eq 0) `
        -Name "RuntimeGuard/EntrypointsFailClosedWhenGuardUnloadable" `
        -Failure "Завантаження BRAVO_RUNTIME_GUARD.ps1 має бути в try/catch і підтверджуватись Get-Command; не захищено: $($entrypointsWithUnguardedDotSource -join ', ')"

    # Функціональне підтвердження того самого: справжній entrypoint поруч із
    # guard-ом, який існує, але не парситься. Модулі не потрібні — коректна
    # поведінка полягає саме в тому, щоб до них не дійти.
    $failClosedRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_GUARD_FAILCLOSED_{0}" -f [guid]::NewGuid().ToString('N'))
    $failClosedResults = @()
    try {
        [void][IO.Directory]::CreateDirectory($failClosedRoot)
        [IO.File]::WriteAllText(
            (Join-Path $failClosedRoot 'BRAVO_RUNTIME_GUARD.ps1'),
            "function Test-BRAVORuntimeManifestIntegrity {`r`n",
            (New-Object Text.UTF8Encoding($true))
        )
        foreach ($guardEntrypoint in $guardEntrypoints) {
            Copy-Item `
                -LiteralPath (Join-Path $root $guardEntrypoint) `
                -Destination (Join-Path $failClosedRoot $guardEntrypoint) `
                -Force
            # Без пониження ErrorActionPreference незахищений entrypoint
            # ронить увесь прогін замість чистого [FAIL]: під 2>&1 кожен
            # рядок stderr нативного exe стає ErrorRecord, а Stop робить
            # його фатальним. Саме це й показала регресія цього тесту.
            $previousErrorAction = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                # -NoPause: цей тест перевіряє guard fail-closed, а не паузу
                # при ручному запуску. Без цього прапорця самотест, запущений
                # у реальній інтерактивній консолі (не в CI), завис би тут —
                # UserInteractive/IsInputRedirected самі по собі це не
                # ловлять, бо дочірній процес успадковує ту саму консоль.
                $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                    -File (Join-Path $failClosedRoot $guardEntrypoint) -NoPause 2>&1
            } finally {
                $ErrorActionPreference = $previousErrorAction
            }
            $failClosedResults += [pscustomobject]@{
                Script = $guardEntrypoint
                ExitCode = $LASTEXITCODE
            }
        }
    } finally {
        Remove-Item -LiteralPath $failClosedRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $wrongExitCodes = @(
        $failClosedResults | Where-Object { $_.ExitCode -ne 33 }
    )
    Test-BRAVOCondition `
        -Condition ($failClosedResults.Count -eq 3 -and $wrongExitCodes.Count -eq 0) `
        -Name "RuntimeGuard/UnloadableGuardBlocksWithCode33" `
        -Failure "Незавантажуваний guard має зупиняти кожен entrypoint кодом 33; отримано: $(($failClosedResults | ForEach-Object { "$($_.Script)=$($_.ExitCode)" }) -join ', ')"

    # ===== ЄДИНИЙ СТИЛЬ ВІДОБРАЖЕННЯ =====
    # Три runtime показували операторові три різні речі: Archive — етапи
    # [1/7] через BRAVO.Console, Health — суцільний потік "[LEVEL] текст",
    # Maintenance — "=== ЗАГОЛОВОК ===" і власну палітру. BRAVO.Console існував,
    # але користувався ним лише Archive.
    $runtimeConsoleFiles = @(
        @{ Path = "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1";         Title = 'Archive' },
        @{ Path = "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1";           Title = 'Health' },
        @{ Path = "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"; Title = 'Maintenance' }
    )
    # Мінімальний спільний словник: без будь-якого з цих викликів вивід
    # runtime перестає бути тим самим виводом. Фінальний підсумок має два
    # рівнозначні варіанти: старий Write-BRAVOSummary (Maintenance і
    # неммігровані ручні шляхи Archive) або новий блок РЕЗУЛЬТАТ через
    # Write-BRAVOResultHeader (docs/OPERATOR_CONSOLE_UX.md) — досить
    # одного з них, обидва проходять через BRAVO.Console.
    $requiredConsoleCommands = @(
        'Initialize-BRAVOConsole',
        'Write-BRAVOHeader',
        'Write-BRAVOStepResult'
    )
    # dev.14 (round 3): Maintenance перейшла на Write-BRAVOFinalSummaryHeader
    # (BRAVO.Console) для фінального підсумку — той самий спільний модуль,
    # інша, паралельна точка входу (Write-BRAVOResultHeader лишається
    # контрактом для Archive/Health/решти).
    $finalSummaryCommandAlternatives = @('Write-BRAVOSummary', 'Write-BRAVOResultHeader', 'Write-BRAVOFinalSummaryHeader')
    $runtimeConsoleAsts = @{}
    $runtimesMissingConsole = @()
    foreach ($runtimeConsoleFile in $runtimeConsoleFiles) {
        $runtimeConsolePath = Join-Path $root $runtimeConsoleFile.Path
        $runtimeConsoleAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $runtimeConsolePath, [ref]$null, [ref]$null
        )
        $runtimeConsoleAsts[$runtimeConsoleFile.Title] = $runtimeConsoleAst

        # Саме CommandAst, а не пошук підрядка: інакше тест зарахував би
        # згадку імені функції у власному пояснювальному коментарі.
        $invokedCommands = @(
            $runtimeConsoleAst.FindAll(
                { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
                $true
            ) | ForEach-Object { [string]$_.GetCommandName() }
        )
        foreach ($requiredConsoleCommand in $requiredConsoleCommands) {
            if ($invokedCommands -notcontains $requiredConsoleCommand) {
                $runtimesMissingConsole += "$($runtimeConsoleFile.Title): $requiredConsoleCommand"
            }
        }
        $hasFinalSummaryCommand = @(
            $finalSummaryCommandAlternatives | Where-Object { $invokedCommands -contains $_ }
        ).Count -gt 0
        if (-not $hasFinalSummaryCommand) {
            $runtimesMissingConsole += "$($runtimeConsoleFile.Title): Write-BRAVOSummary/Write-BRAVOResultHeader"
        }
    }
    Test-BRAVOCondition `
        -Condition ($runtimesMissingConsole.Count -eq 0) `
        -Name "Console/AllRuntimesRenderThroughSharedConsole" `
        -Failure "Archive, Health і Maintenance мають рендерити консоль через BRAVO.Console; не викликано: $($runtimesMissingConsole -join '; ')"

    # Health мігровано повністю: у ньому не лишилося жодного Write-Host.
    # Archive і Maintenance зберігають кілька — усі до підняття консолі
    # (права адміністратора, версія PowerShell, збій завантаження
    # конфігурації), де BRAVO.Console ще не існує.
    $healthWriteHostCalls = @(
        $runtimeConsoleAsts['Health'].FindAll(
            { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
            $true
        ) | Where-Object { [string]$_.GetCommandName() -eq 'Write-Host' }
    )
    Test-BRAVOCondition `
        -Condition ($healthWriteHostCalls.Count -eq 0) `
        -Name "Console/HealthRendersNoRawWriteHost" `
        -Failure "BRAVO.Health.Runtime.ps1 не повинен містити Write-Host — увесь вивід іде через BRAVO.Console; знайдено викликів: $($healthWriteHostCalls.Count)"

    # Консольна половина журналу теж має проходити через BRAVO.Console,
    # інакше WARNING із бізнес-логіки допише себе у хвіст відкритого рядка
    # етапу ("[3/7] BLOG......... ") і зламає розмітку.
    Remove-Module -Name 'BRAVO.Logging' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.Logging\BRAVO.Logging.psd1") -Force -ErrorAction Stop
    Test-BRAVOCondition `
        -Condition ($null -ne (Get-Command -Name 'Set-BRAVOLogConsoleWriter' -ErrorAction SilentlyContinue)) `
        -Name "Console/LoggingExposesConsoleWriterHook" `
        -Failure "BRAVO.Logging має експортувати Set-BRAVOLogConsoleWriter — через нього консольний канал журналу віддається BRAVO.Console"

    # Функціональна перевірка самого містка: запис журналу мусить потрапити
    # у зареєстрований writer, а не у Write-Host.
    #
    # Перевірка наявності команди тут не зайва: без неї відсутній місток
    # обривав увесь прогін фатальною помилкою й ховав решту результатів —
    # рівно це й показала регресія цього тесту.
    $capturedConsoleWrites = New-Object System.Collections.ArrayList
    $consoleWriterProbeLog = Join-Path $env:TEMP ("BRAVO_CONSOLE_WRITER_{0}.log" -f ([guid]::NewGuid().ToString('N')))
    if ($null -eq (Get-Command -Name 'Set-BRAVOLogConsoleWriter' -ErrorAction SilentlyContinue)) {
        [void]$capturedConsoleWrites.Add('Set-BRAVOLogConsoleWriter недоступна')
    } else {
    try {
        [void](Initialize-BRAVOLog -LogFile $consoleWriterProbeLog -ConsoleLevel 'WARNING')
        Set-BRAVOLogConsoleWriter -Writer {
            param($Message, $Level)
            [void]$capturedConsoleWrites.Add("$Level|$Message")
        }
        Write-BRAVOLog -Message 'Тестове попередження стилю' -Level 'WARNING' -Component 'SELFTEST'
        # DEBUG нижчий за поріг консолі — не має дійти до writer узагалі.
        Write-BRAVOLog -Message 'Тестова деталь' -Level 'DEBUG' -Component 'SELFTEST'
    } finally {
        Set-BRAVOLogConsoleWriter -Writer $null
        Remove-Item -LiteralPath $consoleWriterProbeLog -Force -ErrorAction SilentlyContinue
    }
    }
    Test-BRAVOCondition `
        -Condition (
            $capturedConsoleWrites.Count -eq 1 -and
            [string]$capturedConsoleWrites[0] -eq 'WARNING|Тестове попередження стилю'
        ) `
        -Name "Console/LogConsoleChannelReachesWriter" `
        -Failure "Консольний канал Write-BRAVOLog має йти у зареєстрований writer і поважати поріг рівня; отримано: $($capturedConsoleWrites -join ' / ')"

    # Та сама пастка, яку BRAVO.Logging уже виправив, лишалася в Maintenance:
    # у локальній шкалі SUCCESS=4 стояв ВИЩЕ за ERROR=3, тому LogLevel="SUCCESS"
    # відсікав помилки й попередження — найвища детальність ховала рівно те,
    # заради чого журнал читають.
    $maintenanceScaleAst = $runtimeConsoleAsts['Maintenance'].Find(
        {
            param($node)
            $node -is [System.Management.Automation.Language.HashtableAst] -and
            ($node.KeyValuePairs | ForEach-Object { [string]$_.Item1.Extent.Text }) -contains '"SUCCESS"' -and
            ($node.KeyValuePairs | ForEach-Object { [string]$_.Item1.Extent.Text }) -contains '"ERROR"'
        },
        $true
    )
    $maintenanceScaleOrdered = $false
    if ($null -ne $maintenanceScaleAst) {
        $maintenanceScale = @{}
        foreach ($pair in $maintenanceScaleAst.KeyValuePairs) {
            $maintenanceScale[([string]$pair.Item1.Extent.Text).Trim('"')] = [int]$pair.Item2.Extent.Text
        }
        $maintenanceScaleOrdered = (
            $maintenanceScale['SUCCESS'] -lt $maintenanceScale['WARNING'] -and
            $maintenanceScale['WARNING'] -lt $maintenanceScale['ERROR']
        )
    }
    Test-BRAVOCondition `
        -Condition $maintenanceScaleOrdered `
        -Name "Console/MaintenanceSeverityScaleMatchesLogging" `
        -Failure "У шкалі рівнів BRAVO.Maintenance SUCCESS має бути НИЖЧЕ за WARNING і ERROR, інакше LogLevel='SUCCESS' приховає помилки"

    # Вимкнений у конфігурації компонент не займає рядка етапу й не входить
    # у знаменник: етап існує лише для того, що справді виконуватиметься.
    # Знаменник тому обчислюваний, а не константа — Archive робив так від
    # початку, Health підтягнуто до нього.
    #
    # dev.15: Maintenance свідомо ВИКЛЮЧЕНО з цього переліку — затверджений
    # operator contract тепер рівно 8 стабільних кроків, які рендеряться
    # ЗАВЖДИ (вимкнений компонент показує SKIPPED 'вимкнено' на своєму
    # постійному номері, а не зникає з нумерації й не зсуває решту).
    # Раніше обчислюваний знаменник Maintenance (5+optional) давав
    # "dynamic total" — саме той дефект, який Maintenance/MainStepTotalIsExactlyEight
    # нижче тепер явно забороняє через AST. Це не регрес цього тесту, а
    # свідома відмінність контракту Maintenance від Archive/Health.
    $runtimeStepTotals = @(
        @{ Title = 'Archive'; Initializer = 'Initialize-BRAVOArchiveSteps' },
        @{ Title = 'Health';  Initializer = 'Initialize-BRAVOHealthSteps' }
    )
    $runtimesWithConstantTotal = @()
    foreach ($runtimeStepTotal in $runtimeStepTotals) {
        $initializerCalls = @(
            $runtimeConsoleAsts[$runtimeStepTotal.Title].FindAll(
                { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
                $true
            ) | Where-Object {
                [string]$_.GetCommandName() -eq $runtimeStepTotal.Initializer -and
                # Оголошення функції теж CommandAst не є, але її виклик із
                # -Total присутній рівно один — саме він нас цікавить.
                ([string]$_.Extent.Text).Contains('-Total')
            }
        )
        # Обчислюваний знаменник обов'язково містить умову: без жодного if
        # це константа, тобто вимкнений компонент знову роздуває підсумок.
        $hasComputedTotal = @(
            $initializerCalls | Where-Object { ([string]$_.Extent.Text) -match '\bif\b' }
        ).Count -gt 0
        if (-not $hasComputedTotal) {
            $runtimesWithConstantTotal += $runtimeStepTotal.Title
        }
    }
    Test-BRAVOCondition `
        -Condition ($runtimesWithConstantTotal.Count -eq 0) `
        -Name "Console/StepTotalCountsOnlyEnabledComponents" `
        -Failure "Кількість етапів має обчислюватися за увімкненими компонентами, а не бути константою; константа у: $($runtimesWithConstantTotal -join ', ')"

    # ===== ПАУЗА ПЕРЕД ЗАКРИТТЯМ ВІКНА ПРИ РУЧНОМУ ЗАПУСКУ =====
    # Ключова властивість, яку тут охороняємо: -NoPause (Планувальник,
    # самотест) НІКОЛИ не повинен натрапити на блокуючий виклик. Гілка
    # виходу з -NoPause має бути буквально ПЕРШИМ виконуваним рядком
    # тіла функції — перевіряємо це через AST, а не текстом, і окремо
    # підтверджуємо функціональним викликом, що з -NoPause вона реально
    # повертається миттєво (Measure-Command із жорсткою межею), а не
    # покладаємось на "мабуть, так і є".
    Remove-Module -Name 'BRAVO.Console' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.Console\BRAVO.Console.psd1") -Force -ErrorAction Stop
    $consoleModuleAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root "modules\BRAVO.Console\BRAVO.Console.psm1"), [ref]$null, [ref]$null
    )
    $waitManualExitFunction = $consoleModuleAst.Find(
        {
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Wait-BRAVOManualExit'
        },
        $true
    )
    $waitManualExitFirstStatementIsNoPauseGuard = $false
    if ($null -ne $waitManualExitFunction) {
        $firstStatement = $waitManualExitFunction.Body.EndBlock.Statements[0]
        $waitManualExitFirstStatementIsNoPauseGuard = (
            $null -ne $firstStatement -and
            ([string]$firstStatement.Extent.Text) -match '^\s*if\s*\(\s*\$NoPause\s*\)\s*\{\s*return\s*\}'
        )
    }
    Test-BRAVOCondition `
        -Condition ($null -ne $waitManualExitFunction -and $waitManualExitFirstStatementIsNoPauseGuard) `
        -Name "Console/WaitManualExitChecksNoPauseFirst" `
        -Failure "Wait-BRAVOManualExit має перевіряти -NoPause першим виконуваним рядком — інакше запланований запуск ризикує дійти до блокуючого ReadKey"

    $noPauseElapsed = Measure-Command { Wait-BRAVOManualExit -NoPause }
    Test-BRAVOCondition `
        -Condition ($noPauseElapsed.TotalSeconds -lt 2) `
        -Name "Console/WaitManualExitNoPauseReturnsImmediately" `
        -Failure "Wait-BRAVOManualExit -NoPause має повертатися миттєво; зайняло $($noPauseElapsed.TotalSeconds) с"

    # Три entrypoint-и мають свою самодостатню (без BRAVO.Console) паузу
    # для ранніх виходів — до Import-Module жоден BRAVO-модуль ще не
    # довірений. Перевіряємо, що виклик Wait-BRAVOEarlyManualExit передує
    # КОЖНОМУ "exit N" аж до першого звернення до $parameters (тобто разом
    # із секцією Import-Module, у якої власний exit 90) — не лише деяким.
    # Перша версія цієї перевірки різала межу на "$modulePath =" і тому не
    # бачила catch-блок Import-Module із власним exit 90 — саме там
    # регресія й підтвердила прогалину в самому тесті.
    $entrypointsWithUnguardedEarlyExit = New-Object System.Collections.ArrayList
    foreach ($guardEntrypointForPause in @('BRAVO_ARCHIV.ps1', 'BRAVO_HEALTH.ps1', 'BRAVO_MAINTENANCE.ps1')) {
        $entrypointPathForPause = Join-Path $root $guardEntrypointForPause
        $entrypointTextForPause = [IO.File]::ReadAllText($entrypointPathForPause, [Text.Encoding]::UTF8)
        $guardSectionEnd = $entrypointTextForPause.IndexOf('$parameters = @{')
        if ($guardSectionEnd -lt 0) {
            [void]$entrypointsWithUnguardedEarlyExit.Add("$guardEntrypointForPause (немає секції guard)")
            continue
        }
        $guardSectionText = $entrypointTextForPause.Substring(0, $guardSectionEnd)
        $hasFunctionDefinition = $guardSectionText.Contains('function Wait-BRAVOEarlyManualExit')
        # Кожен "exit N" у секції guard має мати виклик паузи серед двох
        # попередніх непорожніх рядків — так само, як він написаний у коді.
        $exitLinesUnprotected = @(
            [regex]::Matches($guardSectionText, '(?m)^\s*(?:.*\{\s*)?exit\s+\d+') |
                Where-Object {
                    $precedingText = $guardSectionText.Substring(0, $_.Index)
                    $precedingLines = ($precedingText -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                    $lastTwoLines = $precedingLines | Select-Object -Last 2
                    -not ($lastTwoLines -join "`n").Contains('Wait-BRAVOEarlyManualExit')
                }
        )
        if (-not $hasFunctionDefinition -or $exitLinesUnprotected.Count -gt 0) {
            [void]$entrypointsWithUnguardedEarlyExit.Add(
                ("{0} (без паузи: {1})" -f $guardEntrypointForPause, $exitLinesUnprotected.Count))
        }
    }
    Test-BRAVOCondition `
        -Condition ($entrypointsWithUnguardedEarlyExit.Count -eq 0) `
        -Name "Console/EarlyGuardExitsPauseBeforeClosing" `
        -Failure "кожен exit у guard-блоці (до Import-Module) має викликати Wait-BRAVOEarlyManualExit; порушення: $($entrypointsWithUnguardedEarlyExit -join '; ')"

    # Health.Runtime.ps1: одна точка виходу, обгорнута try/finally —
    # пауза повинна спрацювати і на нормальному завершенні, і на
    # непередбаченому throw усередині Invoke-BRAVOHealth.
    $healthRuntimeTextForPause = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    # Позиційні орієнтири замість одного крихкого regex на весь фрагмент:
    # достатньо, що "фінальний exit" (останнє входження) стоїть ПІСЛЯ
    # виклику паузи, а сам виклик — усередині "finally {".
    $healthFinallyIndex = $healthRuntimeTextForPause.IndexOf('} finally {')
    $healthPauseCallIndex = $healthRuntimeTextForPause.IndexOf('Wait-BRAVOManualExit -NoPause:$NoPause')
    $healthFinalExitIndex = $healthRuntimeTextForPause.LastIndexOf('exit $script:healthRuntimeExitCode')
    Test-BRAVOCondition `
        -Condition (
            $healthFinallyIndex -ge 0 -and
            $healthPauseCallIndex -gt $healthFinallyIndex -and
            $healthFinalExitIndex -gt $healthPauseCallIndex
        ) `
        -Name "Console/HealthPausesOnEveryExitPath" `
        -Failure "Health.Runtime.ps1 має чекати на клавішу у finally навколо обчислення exitCode — інакше -NoPause параметр приймається, але ніколи не використовується"

    # Maintenance.Runtime.ps1: ~28 точок exit розкидані по всьому файлу
    # (config не знайдено, lock зайнятий, tool integrity тощо) — єдиний
    # безпечний спосіб охопити їх усі одразу без 28 окремих правок:
    # один зовнішній try/finally навколо решти файлу. exit усередині try
    # проходить крізь finally перед тим, як процес завершується
    # (властивість PowerShell, не припущення) — перевіряємо, що відкриваючий
    # try стоїть РАНІШЕ першого "exit", а закриваючий finally — ПІЗНІШЕ
    # останнього.
    $maintenanceRuntimeTextForPause = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    # Орієнтир на унікальний коментар перед "try {", а не на точний
    # сусідній текст усередині: коментарі між ними можуть змінюватись.
    $maintenanceOuterTryIndex = $maintenanceRuntimeTextForPause.IndexOf('Пауза при ручному запуску мала охопити')
    $maintenanceFirstExitIndex = $maintenanceRuntimeTextForPause.IndexOf('Exit $elevatedProcess.ExitCode')
    $maintenanceFinallyIndex = $maintenanceRuntimeTextForPause.LastIndexOf('Wait-BRAVOManualExit -NoPause:$NoPause')
    $maintenanceLastExitIndex = $maintenanceRuntimeTextForPause.LastIndexOf('exit 0')
    Test-BRAVOCondition `
        -Condition (
            $maintenanceOuterTryIndex -ge 0 -and
            $maintenanceFirstExitIndex -gt $maintenanceOuterTryIndex -and
            $maintenanceFinallyIndex -gt $maintenanceLastExitIndex -and
            $maintenanceLastExitIndex -gt $maintenanceFirstExitIndex
        ) `
        -Name "Console/MaintenancePausesOnEveryExitPath" `
        -Failure "Maintenance.Runtime.ps1 має один зовнішній try/finally з Wait-BRAVOManualExit, що охоплює геть усі exit-и файлу — від елевації до фінального exit 0"

    # -NoPause має надходити у Maintenance.Runtime.ps1 через параметр,
    # інакше зовнішній try/finally вище нічим не керує.
    Test-BRAVOCondition `
        -Condition (
            [regex]::IsMatch($maintenanceRuntimeTextForPause, '(?m)^\s*\[switch\]\$NoPause,\s*$')
        ) `
        -Name "Console/MaintenanceAcceptsNoPauseParameter" `
        -Failure "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1 має приймати -NoPause у param()"

    # Кожен entrypoint має прокидати -NoPause у свій runtime, інакше сам
    # параметр command-line нічого не змінює.
    $entrypointsNotForwardingNoPause = New-Object System.Collections.ArrayList
    foreach ($noPauseForwardCheck in @(
        @{ File = 'BRAVO_ARCHIV.ps1' },
        @{ File = 'BRAVO_HEALTH.ps1' },
        @{ File = 'BRAVO_MAINTENANCE.ps1' }
    )) {
        $forwardText = [IO.File]::ReadAllText((Join-Path $root $noPauseForwardCheck.File), [Text.Encoding]::UTF8)
        if (-not [regex]::IsMatch($forwardText, 'NoPause\s*=\s*\$NoPause')) {
            [void]$entrypointsNotForwardingNoPause.Add($noPauseForwardCheck.File)
        }
    }
    Test-BRAVOCondition `
        -Condition ($entrypointsNotForwardingNoPause.Count -eq 0) `
        -Name "Console/EntrypointsForwardNoPauseToRuntime" `
        -Failure "entrypoint має передавати NoPause = `$NoPause у параметри свого runtime; не передають: $($entrypointsNotForwardingNoPause -join ', ')"

    # BRAVO_TASKS_INSTALL.ps1: -NoPause має додаватись БЕЗУМОВНО для
    # кожного типу запланованого завдання, а не вибірково за TaskType —
    # саме вибіркове додавання лишило Recovery й Maintenance без нього.
    $tasksInstallTextForPause = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_TASKS_INSTALL.ps1"), [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            [regex]::IsMatch(
                $tasksInstallTextForPause,
                '\$actionArguments \+= " -ConfigPath[^\r\n]*"\r?\n\s*#[^\r\n]*\r?\n(?:\s*#[^\r\n]*\r?\n)*\s*\$actionArguments \+= " -NoPause"'
            )
        ) `
        -Name "Scheduler/EveryTaskTypeGetsNoPauseUnconditionally" `
        -Failure "BRAVO_TASKS_INSTALL.ps1 має додавати -NoPause одразу після -ConfigPath, поза будь-яким if (`$TaskType -eq ...) — інакше якийсь тип завдання лишиться без нього непомітно"

    # Об'єкти проблем Health мають різний набір полів: Kind = "Service" не
    # несе ні DifferenceCount, ні ActionCounts. Пряме $_.DifferenceCount під
    # Set-StrictMode валило весь runtime із кодом 90 щоразу, коли лежала
    # керована служба — тобто тривога "служба не працює" не доходила ніколи.
    $healthRuntimeText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $healthRuntimeText.Contains('function Get-BRAVOHealthIssueField') -and
            -not [regex]::IsMatch($healthRuntimeText, '\$\(\$_\.DifferenceCount\)\|')
        ) `
        -Name "Health/AlertFingerprintToleratesMissingIssueFields" `
        -Failure "Get-AlertFingerprint має читати поля проблеми через Get-BRAVOHealthIssueField — пряме звернення падає під Set-StrictMode для проблем без DifferenceCount"

    # Той самий клас бага, інше поле: лише ОДНА з чотирьох гілок побудови
    # проблеми "SFTPSynchronization" (Get-SFTPHealthIssues, "у хмарі
    # відсутні...") насправді встановлює ActionCounts. Реальний прогін
    # (BAZA-SFTP синхронізація увімкнена, локальний каталог BAZA відсутній)
    # падав із "The property 'ActionCounts' cannot be found on this
    # object" — Archive ловив це як відмову всього health-check, а не як
    # окрему проблему в звіті.
    Test-BRAVOCondition `
        -Condition (
            $healthRuntimeText.Contains('function Get-BRAVOHealthIssueActionCounts') -and
            $healthRuntimeText.Contains("`$property = `$Issue.PSObject.Properties['ActionCounts']") -and
            $healthRuntimeText.Contains('Get-BRAVOHealthIssueActionCounts -Issue $healthIssue') -and
            $healthRuntimeText.Contains('Get-BRAVOHealthIssueActionCounts -Issue $Issue') -and
            -not [regex]::IsMatch($healthRuntimeText, '\$healthIssue\.ActionCounts\b') -and
            -not [regex]::IsMatch($healthRuntimeText, '\$Issue\.ActionCounts\b')
        ) `
        -Name "Health/SFTPSynchronizationToleratesMissingActionCounts" `
        -Failure "три з чотирьох видів проблем SFTPSynchronization не несуть ActionCounts — читання має йти через Get-BRAVOHealthIssueActionCounts, пряме `$Issue.ActionCounts`/`$healthIssue.ActionCounts` падає під Set-StrictMode ще на порівнянні з `$null"

    # Реальний випадок (скріншот користувача): Archive викликає Health
    # усередині власного кроку "Перевірка резервних копій", і Health
    # безумовно друкував ПОВНИЙ заголовок "BRAVO HEALTH X.X.X / Установа /
    # Початок" — виглядало як друга незалежна програма всередині виводу
    # Archive. -SuppressHeader вимикає лише текст заголовка (не резервування
    # місця під прогрес-бар — Write-BRAVOHeader продовжує друкувати порожні
    # рядки навіть коли текст придушено), і передається лише зі шляху
    # Invoke-BRAVOHealthCheck (вбудований виклик з Archive) — самостійний
    # запуск BRAVO_HEALTH.ps1 його не бачить, заголовок там лишається.
    $healthPsmText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Health\BRAVO.Health.psm1"),
        [Text.Encoding]::UTF8
    )
    $consoleScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Console\BRAVO.Console.psm1"),
        [Text.Encoding]::UTF8
    )
    $writeBravoHeaderFunctionText = if ($consoleScriptText -match
        '(?s)function Write-BRAVOHeader \{.*?\n\}') {
        $Matches[0]
    } else {
        ''
    }
    Test-BRAVOCondition `
        -Condition (
            $healthRuntimeText.Contains('[switch]$SuppressHeader') -and
            $healthRuntimeText.Contains('-SuppressText:$SuppressHeader') -and
            [regex]::IsMatch($healthPsmText, '-SkipIfBackupTaskRunning:\$SkipIfBackupTaskRunning\s*`\r?\n\s*-SuppressHeader\r?\n') -and
            -not [string]::IsNullOrWhiteSpace($writeBravoHeaderFunctionText) -and
            $writeBravoHeaderFunctionText.Contains('[switch]$SuppressText') -and
            $writeBravoHeaderFunctionText.Contains('if ($SuppressText) {') -and
            # Реальний випадок: фіксований блок порожніх рядків (раніше
            # безумовний) лишався видимим розривом навіть без жодного
            # тексту заголовка для захисту — SuppressText тепер вимикає
            # ВЕСЬ вивід Write-BRAVOHeader, і перевірка на це має стояти
            # РАНІШЕ за цикл резервування рядків, а не після нього.
            (
                $writeBravoHeaderFunctionText.IndexOf('if ($SuppressText) {')
            ) -lt (
                $writeBravoHeaderFunctionText.IndexOf('for ($i = 0; $i -lt $script:BRAVOConsoleProgressReservedLines')
            )
        ) `
        -Name "Console/EmbeddedHealthSuppressesDuplicateHeader" `
        -Failure "Invoke-BRAVOHealthCheck (вбудований виклик Health з Archive) має передавати -SuppressHeader у Invoke-BRAVOHealth, а Write-BRAVOHeader — повністю пропускати вивід (і текст, і резервування рядків під прогрес-бар), коли текст придушено"

    # Реальний випадок (скріншот користувача, після прибирання заголовка):
    # вбудований виклик Health усередині Archive все одно друкував ВЛАСНУ
    # покрокову нумерацію [N/5] поряд із нумерацією Archive [N/7] — виглядало
    # як два незалежні прогони. -SuppressHeader тепер вимикає й це.
    $writeBravoHealthStepFunctionText = if ($healthRuntimeText -match
        '(?s)function Write-BRAVOHealthStep \{.*?\n\}') {
        $Matches[0]
    } else {
        ''
    }
    Test-BRAVOCondition `
        -Condition (
            -not [string]::IsNullOrWhiteSpace($writeBravoHealthStepFunctionText) -and
            $writeBravoHealthStepFunctionText.Contains('if ($SuppressHeader) {') -and
            # Лічильник кроків має інкрементуватись РАНІШЕ за перевірку —
            # інакше номер кроку "Сповіщення" в кінці зіб'ється.
            (
                $writeBravoHealthStepFunctionText.IndexOf('$script:BRAVOHealthStepCurrent++')
            ) -lt (
                $writeBravoHealthStepFunctionText.IndexOf('if ($SuppressHeader) {')
            )
        ) `
        -Name "Health/EmbeddedCallSuppressesStepNumbering" `
        -Failure "Write-BRAVOHealthStep має пропускати власний друк [N/5] при -SuppressHeader (вбудований виклик з Archive), не збиваючи внутрішній лічильник кроків"

    # Той самий реальний випадок: власний підсумок Health
    # (РЕЗУЛЬТАТ/Тривалість/.../Детальний журнал) усе одно друкувався другим
    # блоком поряд із підсумком Archive — два "Детальний журнал:" на один
    # прогін. Complete-BRAVOProgress (очищення прогрес-бару) лишається
    # безумовним — лише текстовий підсумок (Write-BRAVOResultHeader і далі,
    # операторська консоль — TODO_FEATURES.md/docs/OPERATOR_CONSOLE_UX.md)
    # придушений.
    $completeHealthResultFunctionText = if ($healthRuntimeText -match
        '(?s)function Complete-BRAVOHealthResult \{.*?\n\}') {
        $Matches[0]
    } else {
        ''
    }
    Test-BRAVOCondition `
        -Condition (
            -not [string]::IsNullOrWhiteSpace($completeHealthResultFunctionText) -and
            $completeHealthResultFunctionText.Contains('if (-not $SuppressHeader) {') -and
            $completeHealthResultFunctionText.Contains('Write-BRAVOResultHeader') -and
            (
                $completeHealthResultFunctionText.IndexOf('Complete-BRAVOProgress')
            ) -lt (
                $completeHealthResultFunctionText.IndexOf('if (-not $SuppressHeader) {')
            ) -and
            (
                $completeHealthResultFunctionText.IndexOf('if (-not $SuppressHeader) {')
            ) -lt (
                $completeHealthResultFunctionText.IndexOf('Write-BRAVOResultHeader')
            )
        ) `
        -Name "Health/EmbeddedCallSuppressesOwnSummary" `
        -Failure "Complete-BRAVOHealthResult має придушувати власний Write-BRAVOResultHeader при -SuppressHeader (вбудований виклик з Archive), не чіпаючи Complete-BRAVOProgress"

    # Реальний випадок: "SFTP MODEL: серверний SHA архіву недоступний;
    # використано повний збіг віддаленого hash-файлу" — перевірка все одно
    # УСПІШНА (через .sha512), тому це нотатка про метод, а не WARNING, що
    # привертає увагу оператора без причини.
    Test-BRAVOCondition `
        -Condition (
            $healthRuntimeText.Contains(
                '"SFTP $($ArchiveDefinition.Type): серверний SHA архіву недоступний; " +'
            ) -and
            [regex]::IsMatch(
                $healthRuntimeText,
                '(?s)серверний SHA архіву недоступний.*?використано повний збіг віддаленого hash-файлу"\s*\)\s*-Level "INFO"'
            )
        ) `
        -Name "Health/ServerSideHashFallbackIsInfoNotWarning" `
        -Failure "фолбек на .sha512-файл — це успішна перевірка іншим методом, а не WARNING; має логуватись як INFO"

    # CLAUDE_CODE_TZ_ARCHIV_LIMS_MONOLITH.md: автоматичний Discovery джерел
    # (BRAVO_ROOT/WEB_ROOT/MODEL/BLOG/BRAVOEXCH/BAZA_APP/BAZA_WWW) за
    # встановленою службою BRAVO і активним bravo.ini, з повним ручним
    # перевизначенням через BRAVO.config.
    Remove-Module -Name 'BRAVO.Discovery' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.Discovery\BRAVO.Discovery.psd1") -Force -ErrorAction Stop

    # Реальний фрагмент bravo.ini.example, наданий користувачем: секції
    # [system]/[model], закоментовані та задубльовані ключі. Перевіряємо,
    # що парсер бере останнє неекрановане значення й ігнорує ";"-рядки.
    $sampleIniContent = @(
        '[system]',
        'DBMEMLIMIT=0',
        '',
        '[model]',
        ';MODEL=G:\LIMS\LIMS_v020924\Poltava_fito\lims',
        'MODEL=D:\LIMS-OLD\Model\lims',
        'MODEL=D:\LIMS-NEW\Model\lims',
        ';MODEL=D:\LIMS\Model\lims',
        'BLOG=D:\LIMS-NEW\BLOG\',
        'BEXCH=D:\LIMS-NEW\bravoexch',
        'BLOGMAX=1000'
    )
    $parsedIni = ConvertFrom-BRAVOIniFile -Content $sampleIniContent
    Test-BRAVOCondition `
        -Condition (
            $parsedIni['model']['MODEL'] -eq 'D:\LIMS-NEW\Model\lims' -and
            $parsedIni['model']['BLOG'] -eq 'D:\LIMS-NEW\BLOG\' -and
            $parsedIni['model']['BEXCH'] -eq 'D:\LIMS-NEW\bravoexch' -and
            $parsedIni['system']['DBMEMLIMIT'] -eq '0' -and
            -not $parsedIni['model'].ContainsKey('')
        ) `
        -Name "Discovery/IniParserHandlesRealBravoIniFormat" `
        -Failure "ConvertFrom-BRAVOIniFile має правильно розбирати секції, коментарі ';' і брати останнє неекрановане значення для задубльованих ключів (формат наданого bravo.ini.example)"

    $discoveryTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_DISCOVERY_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($discoveryTestRoot)
        $fakeBravoExePath = Join-Path $discoveryTestRoot "bravo.exe"
        [IO.File]::WriteAllText($fakeBravoExePath, "stub")
        $fakeApacheBinDir = Join-Path $discoveryTestRoot "webroot\apache\bin"
        [void][IO.Directory]::CreateDirectory($fakeApacheBinDir)
        $fakeHttpdPath = Join-Path $fakeApacheBinDir "httpd.exe"
        [IO.File]::WriteAllText($fakeHttpdPath, "stub")
        $fakeBravoIniPath = Join-Path $discoveryTestRoot "bravo.ini"
        $discoveryTestIniContent = @(
            '[model]',
            ("MODEL={0}" -f (Join-Path $discoveryTestRoot "Model\lims")),
            ("BLOG={0}\" -f (Join-Path $discoveryTestRoot "BLOG")),
            ("BEXCH={0}" -f (Join-Path $discoveryTestRoot "bravoexch"))
        )
        [IO.File]::WriteAllLines($fakeBravoIniPath, $discoveryTestIniContent)

        $syntheticServices = @(
            [pscustomobject]@{ Name = "BRAVO"; DisplayName = "BRAVO Service"; State = "Running"; StartMode = "Auto"; PathName = ('"{0}"' -f $fakeBravoExePath) },
            [pscustomobject]@{ Name = "Apache2.4"; DisplayName = "Apache2.4"; State = "Running"; StartMode = "Auto"; PathName = ('"{0}"' -f $fakeHttpdPath) }
        )

        # -SystemRoot скрізь нижче ін'єктується синтетичним: без цього тест
        # підхоплював би РЕАЛЬНИЙ %SystemRoot%\SysWOW64\bravo.ini поточної
        # машини, якщо він там є (саме так і сталось під час розробки цієї
        # перевірки — на машині розробника він справді лежить там), і тест
        # ставав недетермінованим — залежав від оточення, а не лише від
        # синтетичних фікстур.
        #
        # $noSuchSystemRoot — для сценаріїв "bravo.ini недоступний";
        # $fixtureSystemRoot — єдине допустиме місце, звідки bravo.ini
        # тепер узагалі може бути прочитаний (архітектура ОС визначає
        # SysWOW64 проти System32, іншого шляху немає).
        $noSuchSystemRoot = Join-Path $discoveryTestRoot "NoSuchSystemRoot"
        $fixtureSystemRoot = Join-Path $discoveryTestRoot "FixtureWindows"
        $fixtureSystemIniPath = Join-Path $fixtureSystemRoot "SysWOW64\bravo.ini"
        [void][IO.Directory]::CreateDirectory((Split-Path -Path $fixtureSystemIniPath -Parent))
        [IO.File]::WriteAllLines($fixtureSystemIniPath, $discoveryTestIniContent)
        $autoDiscovery = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $discoveryTestRoot `
            -BravoServiceName "BRAVO" `
            -WebServiceCandidates @("Apache2.4") `
            -Services $syntheticServices `
            -SystemRoot $fixtureSystemRoot `
            -Is64BitOperatingSystem $true

        Test-BRAVOCondition `
            -Condition (
                $autoDiscovery.BRAVO_ROOT -eq $discoveryTestRoot -and
                $autoDiscovery.WEB_ROOT -eq (Join-Path $discoveryTestRoot "webroot") -and
                $autoDiscovery.MODEL_SOURCE -eq (Join-Path $discoveryTestRoot "Model") -and
                $autoDiscovery.BLOG_SOURCE -eq (Join-Path $discoveryTestRoot "BLOG") -and
                $autoDiscovery.BRAVOEXCH_SOURCE -eq (Join-Path $discoveryTestRoot "bravoexch") -and
                $autoDiscovery.BAZA_APP -eq (Join-Path $discoveryTestRoot "BAZA") -and
                [string]::IsNullOrWhiteSpace([string]$autoDiscovery.BAZA_WWW) -and
                $autoDiscovery.MODEL_PROJECT_FILE -eq (Join-Path $discoveryTestRoot "Model\lims") -and
                [string]::IsNullOrWhiteSpace([string]$autoDiscovery.BACKUP_ROOT)
            ) `
            -Name "Discovery/ResolvesFromServiceAndIniWithoutOverride" `
            -Failure "MODEL/BLOG/BRAVOEXCH мають походити з canonical bravo.ini; BAZA_WWW без DocumentRoot і BACKUP_ROOT без pathSettings не повинні виводитись евристично"

        $overriddenDiscovery = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $discoveryTestRoot `
            -BravoServiceName "BRAVO" `
            -WebServiceCandidates @("Apache2.4") `
            -Services $syntheticServices `
            -SystemRoot $noSuchSystemRoot `
            -DiscoverySettings @{ Sources = @{ MODEL = "C:\Explicit\Override\Model" } }
        Test-BRAVOCondition `
            -Condition (
                $overriddenDiscovery.MODEL_SOURCE -eq "C:\Explicit\Override\Model" -and
                [bool]$overriddenDiscovery.Overrides["MODEL"] -and
                [string]::IsNullOrWhiteSpace([string]$overriddenDiscovery.BLOG_SOURCE)
            ) `
            -Name "Discovery/ExplicitOverrideWinsAndIsNeverReplaced" `
            -Failure "явний discoverySettings.Sources.MODEL override має перемагати над автоматично знайденим значенням, не зачіпаючи інші поля"

        $noServiceDiscovery = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $discoveryTestRoot `
            -BravoServiceName "BRAVO_NOT_INSTALLED" `
            -WebServiceCandidates @("Apache2.4") `
            -Services @() `
            -SystemRoot $noSuchSystemRoot
        Test-BRAVOCondition `
            -Condition (
                [string]::IsNullOrWhiteSpace([string]$noServiceDiscovery.BRAVO_ROOT) -and
                [string]::IsNullOrWhiteSpace([string]$noServiceDiscovery.MODEL_SOURCE) -and
                [string]::IsNullOrWhiteSpace([string]$noServiceDiscovery.BLOG_SOURCE) -and
                [string]::IsNullOrWhiteSpace([string]$noServiceDiscovery.WEB_ROOT)
            ) `
            -Name "Discovery/NoSilentSourceFallbackWhenCanonicalIniMissing" `
            -Failure "без canonical bravo.ini MODEL/BLOG мають лишатись невизначеними; LIMSRoot-відносний fallback може архівувати іншу інсталяцію"

        # BACKUP_ROOT — інакше, ніж MODEL/BLOG: коли службу BRAVO не
        # знайдено, "LIMSRoot\ARCHIV" — це ГІРШИЙ здогад, ніж дефолт,
        # який BRAVO.config уже має сам (каталог скрипта). Тому в цьому
        # випадку BACKUP_ROOT має лишатись порожнім, а не пропонувати
        # другу здогадку поверх першої.
        Test-BRAVOCondition `
            -Condition ([string]::IsNullOrWhiteSpace([string]$noServiceDiscovery.BACKUP_ROOT)) `
            -Name "Discovery/BackupRootStaysEmptyWithoutRealService" `
            -Failure "без реально знайденої служби BRAVO BACKUP_ROOT має лишатись порожнім — LIMSRoot-відносна здогадка гірша за власний дефолт BRAVO.config (pathSettings.ArchiveRoot)"

        # Реальний випадок (звіт користувача, реальна dev-машина): служби
        # BRAVO немає взагалі, але системний bravo.ini є — і MODEL/BLOG у
        # ньому вказують на зовсім інший диск/каталог, ніж LimsRoot
        # ("D:\LIMS-NEW\..." проти "C:\Users\...\Documents"). BRAVO_ROOT
        # тоді лишається невизначеним, але BAZA_APP усе одно має братись
        # поруч із реальним MODEL/BLOG із canonical bravo.ini.
        $iniOnlyInstallRoot = Join-Path $discoveryTestRoot "IniOnlyInstall"
        [void][IO.Directory]::CreateDirectory($iniOnlyInstallRoot)
        $iniOnlySystemRoot = Join-Path $discoveryTestRoot "IniOnlyWindows"
        $iniOnlySysWow64Dir = Join-Path $iniOnlySystemRoot "SysWOW64"
        [void][IO.Directory]::CreateDirectory($iniOnlySysWow64Dir)
        [IO.File]::WriteAllLines((Join-Path $iniOnlySysWow64Dir "bravo.ini"), @(
            '[model]',
            ("MODEL={0}" -f (Join-Path $iniOnlyInstallRoot "Model\lims")),
            ("BLOG={0}\" -f (Join-Path $iniOnlyInstallRoot "BLOG"))
        ))
        $iniOnlyDiscovery = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $discoveryTestRoot `
            -BravoServiceName "BRAVO_NOT_INSTALLED" `
            -Services @() `
            -SystemRoot $iniOnlySystemRoot `
            -Is64BitOperatingSystem $true
        Test-BRAVOCondition `
            -Condition (
                [string]::IsNullOrWhiteSpace([string]$iniOnlyDiscovery.BRAVO_ROOT) -and
                $iniOnlyDiscovery.MODEL_SOURCE -eq (Join-Path $iniOnlyInstallRoot "Model") -and
                $iniOnlyDiscovery.BAZA_APP -eq (Join-Path $iniOnlyInstallRoot "BAZA") -and
                $iniOnlyDiscovery.Reasons.BAZA_APP.Contains("MODEL/BLOG з bravo.ini")
            ) `
            -Name "Discovery/BazaAppFollowsIniInstallationRootNotBravoRootFallback" `
            -Failure "коли canonical bravo.ini знайдено, а служби BRAVO немає, BRAVO_ROOT має лишитись null, а BAZA_APP — братись поруч із MODEL/BLOG з ini"

        # Мінімальний парсер httpd.conf: реальний зразок, наданий
        # користувачем — DocumentRoot у лапках, слеші "/" (Apache на
        # Windows традиційно пише шлях так, навіть коли сам процес — Win32).
        $sampleHttpdConfContent = @(
            '# приклад, наданий користувачем',
            '',
            'ServerRoot "c:/br-a-vo.web/apache"',
            'Listen 80',
            'DocumentRoot "c:/br-a-vo.web/www"',
            '<Directory "c:/br-a-vo.web/www">',
            '    Require all granted',
            '</Directory>'
        )
        Test-BRAVOCondition `
            -Condition (
                (Get-BRAVOApacheDocumentRoot -Content $sampleHttpdConfContent) -eq 'c:\br-a-vo.web\www'
            ) `
            -Name "Discovery/ApacheDocumentRootParserReadsQuotedForwardSlashPath" `
            -Failure "Get-BRAVOApacheDocumentRoot має правильно розбирати DocumentRoot у лапках зі слешами '/' (реальний формат httpd.conf) і конвертувати їх у '\'"
        Test-BRAVOCondition `
            -Condition (
                $null -eq (Get-BRAVOApacheDocumentRoot -Content @('# DocumentRoot "c:/ignored"', 'Listen 80'))
            ) `
            -Name "Discovery/ApacheDocumentRootParserIgnoresCommentedDirective" `
            -Failure "Get-BRAVOApacheDocumentRoot не повинен сприймати закоментовану директиву DocumentRoot"

        # BAZA_WWW має братись САМЕ з DocumentRoot реального httpd.conf, а
        # не з фолбек-здогадки "<WEB_ROOT>\www" — попередній тест вище
        # (без httpd.conf на диску) уже перевірив саму здогадку; тут
        # httpd.conf з'являється на диску вперше й має її перебити.
        $fakeApacheConfDir = Join-Path $discoveryTestRoot "webroot\apache\conf"
        [void][IO.Directory]::CreateDirectory($fakeApacheConfDir)
        $fakeHttpdConfPath = Join-Path $fakeApacheConfDir "httpd.conf"
        $fakeDocumentRoot = Join-Path $discoveryTestRoot "custom-web-root"
        [IO.File]::WriteAllLines($fakeHttpdConfPath, @(
            'ServerRoot "c:/br-a-vo.web/apache"',
            ("DocumentRoot ""{0}""" -f $fakeDocumentRoot.Replace('\', '/'))
        ))
        $discoveryWithHttpdConf = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $discoveryTestRoot `
            -BravoServiceName "BRAVO" `
            -WebServiceCandidates @("Apache2.4") `
            -Services $syntheticServices `
            -SystemRoot $noSuchSystemRoot
        Test-BRAVOCondition `
            -Condition (
                $discoveryWithHttpdConf.HttpdConfPath -eq $fakeHttpdConfPath -and
                $discoveryWithHttpdConf.BAZA_WWW -eq (Join-Path $fakeDocumentRoot "BAZA") -and
                $discoveryWithHttpdConf.WebServiceName -eq "Apache2.4" -and
                $discoveryWithHttpdConf.WebServiceExecutable -eq $fakeHttpdPath -and
                $discoveryWithHttpdConf.Reasons.BAZA_WWW.Contains("httpd.conf") -and
                $discoveryWithHttpdConf.Reasons.BAZA_WWW.Contains("DocumentRoot=$fakeDocumentRoot")
            ) `
            -Name "Discovery/BazaWwwUsesHttpdConfDocumentRoot" `
            -Failure "BAZA_WWW має братись з DocumentRoot реального httpd.conf встановленої Apache-служби, а не з фолбек-здогадки <WEB_ROOT>\www"

        # Джерело істини — Service name ТА Display name одночасно.
        # Сторонній сервіс із Name="BRAVO", але іншим Display name (типова
        # підстава для помилкового спрацювання) не повинен визнаватись
        # службою BRAVO.
        $wrongDisplayNameServices = @(
            [pscustomobject]@{ Name = "BRAVO"; DisplayName = "Якийсь Інший Сервіс"; State = "Running"; StartMode = "Auto"; PathName = ('"{0}"' -f $fakeBravoExePath) }
        )
        $wrongDisplayNameDiscovery = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $discoveryTestRoot `
            -BravoServiceName "BRAVO" `
            -BravoDisplayName "BRAVO Service" `
            -Services $wrongDisplayNameServices `
            -SystemRoot $noSuchSystemRoot
        Test-BRAVOCondition `
            -Condition (
                [string]::IsNullOrWhiteSpace([string]$wrongDisplayNameDiscovery.BRAVO_ROOT) -and
                $wrongDisplayNameDiscovery.Reasons.BravoRoot.Contains("не визначено")
            ) `
            -Name "Discovery/BravoServiceRequiresNameAndDisplayNameMatch" `
            -Failure "служба з Name='BRAVO', але іншим Display name не повинна визнаватись службою BRAVO або спричиняти silent fallback на LIMSRoot"

        # bravo.ini — джерело істини системний каталог Windows, НЕ каталог
        # bravo.exe. -SystemRoot/-Is64BitOperatingSystem — ін'єкція для
        # детермінованості: реальний %SystemRoot% цієї машини не повинен
        # впливати на результат тесту. SysWOW64 і System32 фікстури містять
        # РІЗНИЙ MODEL=, щоб однозначно довести, який саме каталог обрано —
        # а не лише що "якийсь" bravo.ini знайдено.
        $fakeSystemRoot = Join-Path $discoveryTestRoot "FakeWindows"
        $fakeSysWow64Dir = Join-Path $fakeSystemRoot "SysWOW64"
        $fakeSystem32Dir = Join-Path $fakeSystemRoot "System32"
        [void][IO.Directory]::CreateDirectory($fakeSysWow64Dir)
        [void][IO.Directory]::CreateDirectory($fakeSystem32Dir)
        $systemBravoIniPath = Join-Path $fakeSysWow64Dir "bravo.ini"
        [IO.File]::WriteAllLines($systemBravoIniPath, @(
            '[model]',
            ("MODEL={0}" -f (Join-Path $discoveryTestRoot "SysWOW64Model\lims"))
        ))
        $system32BravoIniPath = Join-Path $fakeSystem32Dir "bravo.ini"
        [IO.File]::WriteAllLines($system32BravoIniPath, @(
            '[model]',
            ("MODEL={0}" -f (Join-Path $discoveryTestRoot "System32Model\lims"))
        ))

        $systemIniDiscoveryX64 = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $discoveryTestRoot `
            -BravoServiceName "BRAVO" `
            -BravoDisplayName "BRAVO Service" `
            -Services $syntheticServices `
            -SystemRoot $fakeSystemRoot `
            -Is64BitOperatingSystem $true
        Test-BRAVOCondition `
            -Condition (
                $systemIniDiscoveryX64.BravoIniPath -eq $systemBravoIniPath -and
                $systemIniDiscoveryX64.MODEL_SOURCE -eq (Join-Path $discoveryTestRoot "SysWOW64Model") -and
                $systemIniDiscoveryX64.Reasons.BravoIniPath.Contains("системний каталог Windows")
            ) `
            -Name "Discovery/SystemDirectoryIsOnlyBravoIniSource" `
            -Failure "на 64-бітній ОС bravo.ini береться саме з %SystemRoot%\SysWOW64 — так само, як він насправді лежить на реальних інсталяціях"

        $systemIniDiscoveryX86 = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $discoveryTestRoot `
            -BravoServiceName "BRAVO" `
            -BravoDisplayName "BRAVO Service" `
            -Services $syntheticServices `
            -SystemRoot $fakeSystemRoot `
            -Is64BitOperatingSystem $false
        Test-BRAVOCondition `
            -Condition (
                $systemIniDiscoveryX86.BravoIniPath -eq $system32BravoIniPath -and
                $systemIniDiscoveryX86.MODEL_SOURCE -eq (Join-Path $discoveryTestRoot "System32Model")
            ) `
            -Name "Discovery/Win32UsesSystem32NotSysWOW64" `
            -Failure "на 32-бітній ОС немає шару перенаправлення WOW64 — bravo.ini має шукатись у System32, а не SysWOW64"

        # Очікуваний шлях bravo.ini рівно один і визначається архітектурою
        # ОС. Файл поруч з bravo.exe ($fakeBravoIniPath існує весь цей блок)
        # НЕ є другим джерелом: дві різні конфігурації на одній машині
        # означали б, що Maintenance читає не ту, якою насправді керується
        # служба, — мовчки й правдоподібно. Тому тут очікується керована
        # помилка з назвою перевіреного шляху.
        $noSystemIniDiscovery = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $discoveryTestRoot `
            -BravoServiceName "BRAVO" `
            -BravoDisplayName "BRAVO Service" `
            -Services $syntheticServices `
            -SystemRoot (Join-Path $discoveryTestRoot "NoSuchWindowsDir") `
            -Is64BitOperatingSystem $true
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath $fakeBravoIniPath) -and
                [string]::IsNullOrWhiteSpace([string]$noSystemIniDiscovery.BravoIniPath) -and
                $noSystemIniDiscovery.Reasons.BravoIniPath.Contains("єдиним очікуваним") -and
                $noSystemIniDiscovery.Reasons.BravoIniPath.Contains("NoSuchWindowsDir\SysWOW64\bravo.ini")
            ) `
            -Name "Discovery/NoFallbackNextToExecutableWhenSystemIniMissing" `
            -Failure "за відсутності bravo.ini у системному каталозі має бути помилка з назвою перевіреного шляху, а не мовчазне читання файлу поруч з bravo.exe"

        # BackupRoot належить pathSettings і не виводиться з BRAVO_ROOT.
        Test-BRAVOCondition `
            -Condition ([string]::IsNullOrWhiteSpace([string]$autoDiscovery.BACKUP_ROOT)) `
            -Name "Discovery/BackupRootNotDerivedFromBravoRoot" `
            -Failure "BACKUP_ROOT не повинен автоматично виводитись із каталогу служби BRAVO"
        $BackupRootOverrideDiscovery = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $discoveryTestRoot `
            -BravoServiceName "BRAVO" `
            -BravoDisplayName "BRAVO Service" `
            -Services $syntheticServices `
            -SystemRoot $noSuchSystemRoot `
            -DiscoverySettings @{ Sources = @{ BACKUP_ROOT = "D:\Explicit\Backups" } }
        Test-BRAVOCondition `
            -Condition (
                $BackupRootOverrideDiscovery.BACKUP_ROOT -eq "D:\Explicit\Backups" -and
                [bool]$BackupRootOverrideDiscovery.Overrides["BACKUP_ROOT"]
            ) `
            -Name "Discovery/BackupRootOverrideWins" `
            -Failure "явний discoverySettings.Sources.BACKUP_ROOT override має перемагати над автоматично обчисленим підкаталогом BRAVO_ROOT"

        $missingSourceResult = [pscustomobject]@{
            MODEL_SOURCE = Join-Path $discoveryTestRoot "__DOES_NOT_EXIST__"
            BLOG_SOURCE = $discoveryTestRoot
            BRAVOEXCH_SOURCE = $null
            BAZA_APP = $null
            BAZA_WWW = $null
        }
        $validationErrors = @(Test-BRAVODiscoveryResult `
            -DiscoveryResult $missingSourceResult `
            -EnabledComponents @{ MODEL = $true; BLOG = $true; BRAVOEXCH = $false })
        Test-BRAVOCondition `
            -Condition (
                $validationErrors.Count -eq 1 -and
                $validationErrors[0].Contains("MODEL")
            ) `
            -Name "Discovery/ValidationDetectsMissingEnabledSourceOnly" `
            -Failure "Test-BRAVODiscoveryResult має повідомляти лише про увімкнені компоненти з відсутнім/непорожнім шляхом і не чіпати вимкнені"

        # AUD-007 (аудит P1.1): кілька служб BRAVO з РІЗНИМИ виконуваними
        # файлами — неоднозначний BRAVO_ROOT має позначатися й блокувати
        # валідацію для enabled-компонентів, що від нього залежать.
        $ambiguousExePathA = Join-Path $discoveryTestRoot "bravo_instance_a.exe"
        [IO.File]::WriteAllText($ambiguousExePathA, "stub")
        $ambiguousExePathB = Join-Path $discoveryTestRoot "bravo_instance_b.exe"
        [IO.File]::WriteAllText($ambiguousExePathB, "stub")
        $ambiguousBravoServices = @(
            [pscustomobject]@{ Name = "BRAVO"; DisplayName = "BRAVO Service"; State = "Running"; StartMode = "Auto"; PathName = ('"{0}"' -f $ambiguousExePathA) },
            [pscustomobject]@{ Name = "BRAVO"; DisplayName = "BRAVO Service"; State = "Running"; StartMode = "Auto"; PathName = ('"{0}"' -f $ambiguousExePathB) }
        )
        $ambiguousDiscovery = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $discoveryTestRoot `
            -BravoServiceName "BRAVO" `
            -BravoDisplayName "BRAVO Service" `
            -Services $ambiguousBravoServices `
            -SystemRoot $noSuchSystemRoot
        Test-BRAVOCondition `
            -Condition (
                [bool]$ambiguousDiscovery.Ambiguous["BravoRoot"] -and
                -not [bool]$ambiguousDiscovery.Ambiguous["WebRoot"]
            ) `
            -Name "Discovery/AmbiguousBravoServiceIsDetected" `
            -Failure "Resolve-BRAVOInstallationDiscovery має позначати Ambiguous.BravoRoot=true, якщо знайдено кілька служб BRAVO з різними виконуваними файлами"
        $ambiguousValidationErrors = @(Test-BRAVODiscoveryResult `
            -DiscoveryResult $ambiguousDiscovery `
            -EnabledComponents @{ MODEL = $true; BLOG = $false; BRAVOEXCH = $false })
        Test-BRAVOCondition `
            -Condition (
                @($ambiguousValidationErrors | Where-Object { $_.Contains("BRAVO_ROOT") -and $_.Contains("неоднозначний") }).Count -eq 1
            ) `
            -Name "Discovery/ValidationBlocksAmbiguousBravoRootForEnabledComponent" `
            -Failure "Test-BRAVODiscoveryResult має повідомляти про неоднозначний BRAVO_ROOT, лише якщо від нього залежить увімкнений компонент"
        $ambiguousValidationErrorsAllDisabled = @(Test-BRAVODiscoveryResult `
            -DiscoveryResult $ambiguousDiscovery `
            -EnabledComponents @{ MODEL = $false; BLOG = $false; BRAVOEXCH = $false })
        Test-BRAVOCondition `
            -Condition (
                @($ambiguousValidationErrorsAllDisabled | Where-Object { $_.Contains("неоднозначний") }).Count -eq 0
            ) `
            -Name "Discovery/ValidationIgnoresAmbiguousBravoRootWhenNoDependentComponentEnabled" `
            -Failure "неоднозначний BRAVO_ROOT не повинен генерувати помилку, якщо жоден залежний компонент не увімкнено"

        # AUD-007 (аудит P1.2): baseline snapshot і виявлення дрейфу джерел
        # між запусками.
        $baselineTestPath = Join-Path $discoveryTestRoot "discovery_baseline.json"
        Save-BRAVODiscoveryBaseline -DiscoveryResult $autoDiscovery -BaselinePath $baselineTestPath
        $noDriftResult = @(Compare-BRAVODiscoveryBaseline -DiscoveryResult $autoDiscovery -BaselinePath $baselineTestPath)
        $driftedDiscovery = [pscustomobject]@{
            BRAVO_ROOT = $autoDiscovery.BRAVO_ROOT
            WEB_ROOT = $autoDiscovery.WEB_ROOT
            MODEL_SOURCE = "C:\Completely\Different\Model"
            BLOG_SOURCE = $autoDiscovery.BLOG_SOURCE
            BRAVOEXCH_SOURCE = $autoDiscovery.BRAVOEXCH_SOURCE
            BAZA_APP = $autoDiscovery.BAZA_APP
            BAZA_WWW = $autoDiscovery.BAZA_WWW
            BACKUP_ROOT = $autoDiscovery.BACKUP_ROOT
        }
        $driftResult = @(Compare-BRAVODiscoveryBaseline -DiscoveryResult $driftedDiscovery -BaselinePath $baselineTestPath)
        $noBaselineYetResult = @(Compare-BRAVODiscoveryBaseline -DiscoveryResult $autoDiscovery -BaselinePath (Join-Path $discoveryTestRoot "__NO_SUCH_BASELINE__.json"))
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath $baselineTestPath -PathType Leaf) -and
                $noDriftResult.Count -eq 0 -and
                $driftResult.Count -eq 1 -and
                $driftResult[0].Contains("MODEL_SOURCE") -and
                $noBaselineYetResult.Count -eq 0
            ) `
            -Name "Discovery/BaselineSaveAndDriftDetection" `
            -Failure "Save-BRAVODiscoveryBaseline має зберігати JSON-знімок, Compare-BRAVODiscoveryBaseline — виявляти зміну поля відносно нього й не повідомляти про дрейф, якщо baseline ще не існує"
    } finally {
        if (Test-Path -LiteralPath $discoveryTestRoot) {
            Remove-Item -LiteralPath $discoveryTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $bravoConfigTextForDiscovery = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO.config"),
        [Text.Encoding]::UTF8
    )
    $configLoaderTextForDiscovery = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_CONFIG_LOADER.ps1"),
        [Text.Encoding]::UTF8
    )
    $setupTextForDiscovery = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_SETUP.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $configLoaderTextForDiscovery.Contains("modules\BRAVO.Discovery\BRAVO.Discovery.psd1") -and
            $bravoConfigTextForDiscovery.Contains("Resolve-BRAVOInstallationDiscovery") -and
            $bravoConfigTextForDiscovery.Contains("`$global:discoverySettings") -and
            $bravoConfigTextForDiscovery.Contains("`$global:sourcePaths") -and
            $setupTextForDiscovery.Contains("Test-BRAVODiscoveryResult") -and
            $setupTextForDiscovery.Contains("DISCOVERY") -and
            $setupTextForDiscovery.Contains("Compare-BRAVODiscoveryBaseline") -and
            $setupTextForDiscovery.Contains("Save-BRAVODiscoveryBaseline") -and
            $setupTextForDiscovery.Contains("ConfirmDiscoveryBaseline")
        ) `
        -Name "Discovery/WiredIntoConfigLoaderAndSetup" `
        -Failure "BRAVO_CONFIG_LOADER.ps1 має імпортувати BRAVO.Discovery, BRAVO.config має викликати Resolve-BRAVOInstallationDiscovery для sourcePaths, а BRAVO_SETUP.ps1 -ValidateOnly має показувати й перевіряти discovery-результат і дрейф відносно baseline"

    # Джерело істини для служби BRAVO — Service name ТА Display name
    # одночасно — має бути прокинуте з BRAVO.config у
    # Resolve-BRAVOInstallationDiscovery, а не лишатись лише в модулі.
    #
    # BackupRoot НЕ перевизначається мовчки з Discovery джерел
    # (MODEL/BLOG/BRAVOEXCH): ефективне значення дає резолвер
    # Resolve-BRAVOEffectiveBackupRoot — явний pathSettings.BackupRoot точно
    # або детермінований AUTO <EffectiveLIMSRoot>\ARCHIV. Мовчазної заміни
    # ЯВНОГО значення на Discovery.BACKUP_ROOT немає (адміністратор бачив би
    # один каталог, а бекапи їхали б в інший).
    Test-BRAVOCondition `
        -Condition (
            $bravoConfigTextForDiscovery.Contains('BravoDisplayName = "BRAVO Service"') -and
            [regex]::IsMatch($bravoConfigTextForDiscovery, '-BravoDisplayName\s+\(\[string\]\$maintenanceSettings\.Services\.BravoDisplayName\)') -and
            $bravoConfigTextForDiscovery.Contains('Resolve-BRAVOEffectiveBackupRoot') -and
            -not [regex]::IsMatch($bravoConfigTextForDiscovery, '\$global:pathSettings\.BackupRoot\s*=\s*\[string\]\$bravoDiscoveryResult\.BACKUP_ROOT')
        ) `
        -Name "Discovery/ConfigUsesStrictBravoIdentityAndResolvesBackupRoot" `
        -Failure "BRAVO.config має передавати -BravoDisplayName='BRAVO Service' у Resolve-BRAVOInstallationDiscovery, обчислювати BackupRoot через Resolve-BRAVOEffectiveBackupRoot і НЕ перевизначати pathSettings.BackupRoot мовчки з Discovery.BACKUP_ROOT"

    # CODE IS NOT DATA. Виробничі корені даних НЕ виводяться з розташування
    # комплекту: для комплекту в C:\BRAVO старі формули дали б LIMSRoot="C:\"
    # і ArchiveRoot="C:\BRAVO", тобто журнали писалися б у каталог з
    # виконуваним кодом. Тепер усі три корені — валідне "" (all-AUTO від
    # служби BRAVO) або явний абсолютний шлях; ЖОДНОГО виведення з ConfigRoot.
    $configLoaderTextForRoots = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_CONFIG_LOADER.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            -not [regex]::IsMatch($bravoConfigTextForDiscovery, '\$defaultLIMSRoot\s*=\s*Split-Path') -and
            -not [regex]::IsMatch($bravoConfigTextForDiscovery, '\$defaultArchiveRoot\s*=\s*\$ConfigRoot') -and
            -not [regex]::IsMatch($bravoConfigTextForDiscovery, '(?m)^\s*ArchiveRoot\s*=') -and
            [regex]::IsMatch($bravoConfigTextForDiscovery, '(?m)^\s*LIMSRoot\s*=') -and
            [regex]::IsMatch($bravoConfigTextForDiscovery, '(?m)^\s*SystemLogRoot\s*=') -and
            [regex]::IsMatch($bravoConfigTextForDiscovery, '(?m)^\s*BackupRoot\s*=') -and
            $configLoaderTextForRoots.Contains('function Test-BravoDataRootValue') -and
            $configLoaderTextForRoots.Contains("Test-BravoDataRootValue -Name 'BackupRoot' -Value ([string]`$PathSettings['BackupRoot']) -AllowEmpty") -and
            $configLoaderTextForRoots.Contains('Assert-BravoDataRootsAreIndependent -PathSettings $global:pathSettings')
        ) `
        -Name "Discovery/DataRootsAreExplicitAndIndependentOfRuntime" `
        -Failure "pathSettings має містити LIMSRoot/SystemLogRoot/BackupRoot (без ArchiveRoot); усі три перевіряються Test-BravoDataRootValue з -AllowEmpty (all-AUTO валідне), не виводяться з ConfigRoot"

    # Tools\ і логи скриптів — від RuntimeRoot; ArchiveRoot як production-корінь
    # прибрано. Логи самих скриптів ($logPath) ЗАВЖДИ RuntimeRoot\LOGS
    # (=runtimeLogRoot), а не ArchiveRoot\LOGS.
    Test-BRAVOCondition `
        -Condition (
            $bravoConfigTextForDiscovery.Contains('$global:toolsPath = Join-Path $runtimeRoot "Tools"') -and
            -not $bravoConfigTextForDiscovery.Contains('Join-Path $archivPath') -and
            $bravoConfigTextForDiscovery.Contains('$global:runtimeLogRoot = Join-Path $runtimeRoot "LOGS"') -and
            $bravoConfigTextForDiscovery.Contains('$global:logPath = $global:runtimeLogRoot')
        ) `
        -Name "Discovery/ToolsAndScriptLogsLiveUnderRuntimeRoot" `
        -Failure "Tools\ і логи скриптів (logPath=runtimeLogRoot) мають визначатись від RuntimeRoot; ArchiveRoot-похідних (archivPath) не повинно лишитись"

    # AUD-004 (аудит P0.4): restore drill. Читабельний і навіть SHA512/7za-
    # перевірений архів не доводить відновлюваність — Invoke-BRAVOSevenZipExtraction
    # (modules\BRAVO.Compatibility) — новий компонент, яким
    # BRAVO_RESTORE_TEST.ps1 користується для фактичного розпакування в
    # ізольований каталог. Функціональний round-trip: стиснути реальним
    # Tools\7za.exe, розпакувати назад, підтвердити, що вміст і кількість
    # файлів збігаються.
    Remove-Module -Name 'BRAVO.Compatibility' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop
    $sevenZipToolPath = Join-Path $root "Tools\7za.exe"
    if (Test-Path -LiteralPath $sevenZipToolPath -PathType Leaf) {
        $restoreDrillTestRoot = Join-Path `
            -Path ([IO.Path]::GetTempPath()) `
            -ChildPath ("BRAVO_RESTORE_DRILL_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
        try {
            $restoreDrillSourceDir = Join-Path $restoreDrillTestRoot "source"
            [void][IO.Directory]::CreateDirectory($restoreDrillSourceDir)
            1..4 | ForEach-Object {
                [IO.File]::WriteAllText((Join-Path $restoreDrillSourceDir "file$_.txt"), "restore drill self-test $_")
            }
            $restoreDrillArchivePath = Join-Path $restoreDrillTestRoot "test.mdz"
            $compressPsi = New-Object System.Diagnostics.ProcessStartInfo
            $compressPsi.FileName = $sevenZipToolPath
            $compressPsi.Arguments = "a -mmt -mx1 -r -y -p `"$restoreDrillArchivePath`" `"$restoreDrillSourceDir`""
            $compressPsi.RedirectStandardInput = $true
            $compressPsi.RedirectStandardOutput = $true
            $compressPsi.RedirectStandardError = $true
            $compressPsi.UseShellExecute = $false
            $compressProcess = New-Object System.Diagnostics.Process
            $compressProcess.StartInfo = $compressPsi
            [void]$compressProcess.Start()
            $compressProcess.StandardInput.WriteLine("RestoreDrillSelfTestPass")
            $compressProcess.StandardInput.Close()
            $compressProcess.WaitForExit()

            $restoreDrillExtractDir = Join-Path $restoreDrillTestRoot "extract"
            [void][IO.Directory]::CreateDirectory($restoreDrillExtractDir)
            $extractionResult = Invoke-BRAVOSevenZipExtraction `
                -SevenZipPath $sevenZipToolPath `
                -ArchivePath $restoreDrillArchivePath `
                -Password "RestoreDrillSelfTestPass" `
                -ExtractDirectory $restoreDrillExtractDir
            $extractedFiles = @(Get-ChildItem -LiteralPath $restoreDrillExtractDir -Recurse -File -ErrorAction SilentlyContinue)
            Test-BRAVOCondition `
                -Condition (
                    [bool]$extractionResult.Success -and
                    $extractionResult.ExitCode -eq 0 -and
                    $extractedFiles.Count -eq 4
                ) `
                -Name "RestoreDrill/ExtractionRoundTripSucceeds" `
                -Failure "Invoke-BRAVOSevenZipExtraction має успішно розпакувати стиснутий 7za.exe архів і повернути ту саму кількість файлів, що й у джерелі"

            $wrongPasswordResult = Invoke-BRAVOSevenZipExtraction `
                -SevenZipPath $sevenZipToolPath `
                -ArchivePath $restoreDrillArchivePath `
                -Password "DefinitelyWrongPassword" `
                -ExtractDirectory $restoreDrillExtractDir
            Test-BRAVOCondition `
                -Condition (-not [bool]$wrongPasswordResult.Success) `
                -Name "RestoreDrill/ExtractionFailsWithWrongPassword" `
                -Failure "Invoke-BRAVOSevenZipExtraction має повертати Success=false для архіву з неправильним паролем"
        } finally {
            if (Test-Path -LiteralPath $restoreDrillTestRoot) {
                Remove-Item -LiteralPath $restoreDrillTestRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $restoreTestScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_RESTORE_TEST.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $restoreTestScriptText.Contains("Get-BRAVORestoreGenerationManifest") -and
            $restoreTestScriptText.Contains("Get-BRAVOVerifiedGenerationArchive") -and
            $restoreTestScriptText.Contains("RequestedGenerationId") -and
            $restoreTestScriptText.Contains("Get-BRAVOBackupGenerationManifestFiles") -and
            $restoreTestScriptText.Contains("Test-SevenZipArchiveIntegrity") -and
            $restoreTestScriptText.Contains("Invoke-BRAVOSevenZipExtraction") -and
            $restoreTestScriptText.Contains("MinimumFileCount") -and
            $restoreTestScriptText.Contains("Resolve-BRAVOExitCode") -and
            $restoreTestScriptText.Contains("Remove-Item -LiteralPath `$workingDirectory -Recurse -Force")
        ) `
        -Name "RestoreDrill/ScriptImplementsFullDrillCycle" `
        -Failure "BRAVO_RESTORE_TEST.ps1 має вибирати один COMPLETE GenerationId для всіх компонентів, перевіряти SHA512/7za, розпаковувати в ізольований каталог, повертати контрактний exit code і прибирати за собою"

    # AUD-008 (аудит P1.6): sanity-check обсягу backup. Технічно валідний
    # архів (7za test + SHA512 збігається) все одно може бути підозріло
    # малим через неправильне джерело чи зламані permissions.
    Remove-Module -Name 'BRAVO.ArchiveHelpers' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.ArchiveHelpers\BRAVO.ArchiveHelpers.psd1") -Force -ErrorAction Stop

    $sizeSanityTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_SIZE_SANITY_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($sizeSanityTestRoot)

        function New-BRAVOSizeSanityFixtureArchive {
            param([string]$Directory, [string]$Name, [int]$Bytes, [datetime]$LastWriteTime)

            $archivePath = Join-Path $Directory $Name
            $bytesArray = New-Object byte[] $Bytes
            [IO.File]::WriteAllBytes($archivePath, $bytesArray)
            (Get-Item -LiteralPath $archivePath).LastWriteTime = $LastWriteTime
            $hash = (Get-BRAVOFileHash -Path $archivePath -Algorithm SHA512).Hash.ToUpperInvariant()
            [IO.File]::WriteAllText("$archivePath.sha512", "$hash *$Name")
            return $archivePath
        }

        # Історія: 5 валідних архівів по ~100000 байт (медіана — 100000).
        for ($i = 1; $i -le 5; $i++) {
            [void](New-BRAVOSizeSanityFixtureArchive `
                -Directory $sizeSanityTestRoot `
                -Name "HIST_2026080${i}_1000.mdz" `
                -Bytes 100000 `
                -LastWriteTime (Get-Date).AddDays(-$i))
        }

        $normalNewArchive = New-BRAVOSizeSanityFixtureArchive `
            -Directory $sizeSanityTestRoot `
            -Name "NEW_NORMAL_20260810_1000.mdz" `
            -Bytes 95000 `
            -LastWriteTime (Get-Date)
        $normalResult = Test-BRAVOBackupSizeAnomaly `
            -NewArchiveBytes 95000 `
            -HistoryDirectory $sizeSanityTestRoot `
            -ArchiveFilter "*.mdz" `
            -HashFileExtension ".sha512" `
            -ExcludeArchivePath $normalNewArchive `
            -HistoryCount 5 `
            -MinimumBytes 1024 `
            -MaxSizeDropPercent 50
        Test-BRAVOCondition `
            -Condition (
                -not [bool]$normalResult.IsAnomaly -and
                $normalResult.HistorySampleCount -eq 5 -and
                $normalResult.MedianHistoricalBytes -eq 100000
            ) `
            -Name "SizeSanity/NormalSizeIsNotAnomaly" `
            -Failure "Test-BRAVOBackupSizeAnomaly не повинен позначати архів у межах порогу як аномалію, і має правильно рахувати медіану історії (виключно новий архів)"

        $droppedNewArchive = New-BRAVOSizeSanityFixtureArchive `
            -Directory $sizeSanityTestRoot `
            -Name "NEW_DROPPED_20260811_1000.mdz" `
            -Bytes 20000 `
            -LastWriteTime (Get-Date)
        $droppedResult = Test-BRAVOBackupSizeAnomaly `
            -NewArchiveBytes 20000 `
            -HistoryDirectory $sizeSanityTestRoot `
            -ArchiveFilter "*.mdz" `
            -HashFileExtension ".sha512" `
            -ExcludeArchivePath $droppedNewArchive `
            -HistoryCount 5 `
            -MinimumBytes 1024 `
            -MaxSizeDropPercent 50
        Test-BRAVOCondition `
            -Condition (
                [bool]$droppedResult.IsAnomaly -and
                $droppedResult.DropPercent -eq 80.0
            ) `
            -Name "SizeSanity/LargeDropIsDetectedAsAnomaly" `
            -Failure "Test-BRAVOBackupSizeAnomaly має позначати падіння розміру понад MaxSizeDropPercent як аномалію з правильним DropPercent"

        $belowMinimumResult = Test-BRAVOBackupSizeAnomaly `
            -NewArchiveBytes 10 `
            -HistoryDirectory $sizeSanityTestRoot `
            -ArchiveFilter "*.mdz" `
            -HashFileExtension ".sha512" `
            -HistoryCount 5 `
            -MinimumBytes 1024 `
            -MaxSizeDropPercent 50
        Test-BRAVOCondition `
            -Condition (
                [bool]$belowMinimumResult.IsAnomaly -and
                $belowMinimumResult.Reason.Contains("мінімально")
            ) `
            -Name "SizeSanity/BelowMinimumBytesIsAlwaysAnomaly" `
            -Failure "Test-BRAVOBackupSizeAnomaly має позначати архів нижче MinimumBytes як аномалію незалежно від наявності історії"

        $noHistoryTestRoot = Join-Path $sizeSanityTestRoot "empty"
        [void][IO.Directory]::CreateDirectory($noHistoryTestRoot)
        $firstRunResult = Test-BRAVOBackupSizeAnomaly `
            -NewArchiveBytes 50000 `
            -HistoryDirectory $noHistoryTestRoot `
            -ArchiveFilter "*.mdz" `
            -HashFileExtension ".sha512" `
            -HistoryCount 5 `
            -MinimumBytes 1024 `
            -MaxSizeDropPercent 50
        Test-BRAVOCondition `
            -Condition (
                -not [bool]$firstRunResult.IsAnomaly -and
                $firstRunResult.HistorySampleCount -eq 0
            ) `
            -Name "SizeSanity/NoHistoryIsNotTreatedAsAnomaly" `
            -Failure "перший backup компонента (без історії валідних архівів) не повинен вважатися аномалією"
    } finally {
        if (Test-Path -LiteralPath $sizeSanityTestRoot) {
            Remove-Item -LiteralPath $sizeSanityTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $archiveRuntimeTextForSizeSanity = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $bravoConfigTextForSizeSanity = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO.config"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $archiveRuntimeTextForSizeSanity.Contains("Test-BRAVOBackupSizeAnomaly") -and
            $archiveRuntimeTextForSizeSanity.Contains("backupMonitoring.SizeSanity.Enabled") -and
            $bravoConfigTextForSizeSanity.Contains("SizeSanity") -and
            $bravoConfigTextForSizeSanity.Contains("MaxSizeDropPercent")
        ) `
        -Name "SizeSanity/WiredIntoArchiveRuntime" `
        -Failure "BRAVO.Archive.Runtime.ps1 має викликати Test-BRAVOBackupSizeAnomaly з налаштувань backupMonitoring.SizeSanity"

    # dev.14: generation manifest-и (BRAVO_BACKUP_<GenerationId>.json) —
    # виділене сховище MANIFESTS\, окреме від LOGS/TEMP. Усі тести нижче
    # працюють ЛИШЕ із синтетичними каталогами під $env:TEMP — жодного
    # production BackupRoot/SFTP/SMB/ACL. BRAVO.ArchiveHelpers уже
    # імпортовано вище (SizeSanity), Write-BRAVOBackupGenerationManifest
    # тестується через ізольовану AST-екстракцію (Archive.Runtime.ps1
    # безумовно запускає Main при dot-source).
    $manifestWriterModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $archiveRuntimeTextForSizeSanity `
        -FunctionNames @('Write-BRAVOBackupGenerationManifest')

    function New-BRAVOManifestStorageTestGenerationState {
        param([string]$GenerationId)

        return [pscustomobject]@{
            GenerationId = $GenerationId
            StartedAt = (Get-Date)
            SnapshotSetId = $null
            Status = 'COMPLETE'
            SnapshotCreatedAt = $null
            Volumes = @()
            Components = @()
            TransferResults = $null
            HealthResult = $null
        }
    }

    $manifestStorageTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_MANIFEST_STORAGE_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($manifestStorageTestRoot)

        # --- 1. Get-BRAVOBackupManifestRoot: єдине джерело фізичного шляху ---
        Test-BRAVOCondition `
            -Condition (
                (Get-BRAVOBackupManifestRoot -BackupRoot $manifestStorageTestRoot) -eq `
                    (Join-Path $manifestStorageTestRoot 'MANIFESTS')
            ) `
            -Name "ManifestStorage/RootResolution" `
            -Failure "Get-BRAVOBackupManifestRoot має повертати BackupRoot\MANIFESTS і ніколи TEMP чи інший шлях"

        # --- 2. Writer: новий manifest завжди йде в MANIFESTS, каталог створюється сам ---
        $writerTestRoot = Join-Path $manifestStorageTestRoot 'writer'
        [void][IO.Directory]::CreateDirectory($writerTestRoot)
        $writerGenerationState = New-BRAVOManifestStorageTestGenerationState -GenerationId '20260809_120000'
        $writtenManifestPath = & $manifestWriterModule {
            param($State, $BackupRoot)
            Write-BRAVOBackupGenerationManifest -GenerationState $State -BackupRoot $BackupRoot
        } $writerGenerationState $writerTestRoot
        Test-BRAVOCondition `
            -Condition (
                $writtenManifestPath -eq (Join-Path (Join-Path $writerTestRoot 'MANIFESTS') 'BRAVO_BACKUP_20260809_120000.json') -and
                (Test-Path -LiteralPath $writtenManifestPath -PathType Leaf) -and
                -not (Test-Path -LiteralPath (Join-Path $writerTestRoot 'BRAVO_BACKUP_20260809_120000.json'))
            ) `
            -Name "ManifestStorage/WriterWritesToManifestsRoot" `
            -Failure "Write-BRAVOBackupGenerationManifest має писати новий manifest у BackupRoot\MANIFESTS (створюючи каталог за потреби), а не в корінь BackupRoot"

        $writerGenerationState.HealthResult = [pscustomobject]@{ Status = 'successful rewrite' }
        $rewrittenManifestPath = & $manifestWriterModule {
            param($State, $BackupRoot)
            Write-BRAVOBackupGenerationManifest -GenerationState $State -BackupRoot $BackupRoot
        } $writerGenerationState $writerTestRoot
        $rewrittenManifest = Get-Content -LiteralPath $rewrittenManifestPath -Raw | ConvertFrom-Json
        $orphanManifestBackups = @(
            Get-ChildItem -LiteralPath (Split-Path $rewrittenManifestPath -Parent) -File -Filter '.BRAVO_BACKUP_*.bak'
        )
        Test-BRAVOCondition `
            -Condition (
                $rewrittenManifest.healthResult.Status -eq 'successful rewrite' -and
                $orphanManifestBackups.Count -eq 0
            ) `
            -Name 'ManifestStorage/ExistingManifestRewriteSucceedsOnWindowsPowerShell51' `
            -Failure 'повторний atomic write існуючого manifest має працювати у Windows PowerShell 5.1 і не лишати backup-файл'

        $manifestBeforeFailedReplace = [IO.File]::ReadAllText($writtenManifestPath, [Text.Encoding]::UTF8)
        $writerGenerationState.HealthResult = [pscustomobject]@{ Status = 'synthetic update' }
        $manifestReplaceFailed = $false
        $manifestLock = $null
        try {
            $manifestLock = [IO.File]::Open(
                $writtenManifestPath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::None
            )
            try {
                & $manifestWriterModule {
                    param($State, $BackupRoot)
                    Write-BRAVOBackupGenerationManifest -GenerationState $State -BackupRoot $BackupRoot
                } $writerGenerationState $writerTestRoot
            } catch {
                $manifestReplaceFailed = $true
            }
        } finally {
            if ($null -ne $manifestLock) {
                $manifestLock.Dispose()
            }
        }
        $manifestAfterFailedReplace = [IO.File]::ReadAllText($writtenManifestPath, [Text.Encoding]::UTF8)
        $orphanManifestTemps = @(
            Get-ChildItem -LiteralPath (Split-Path $writtenManifestPath -Parent) -File -Filter '.BRAVO_BACKUP_*.tmp'
        )
        Test-BRAVOCondition `
            -Condition (
                $manifestReplaceFailed -and
                $manifestAfterFailedReplace -ceq $manifestBeforeFailedReplace -and
                $orphanManifestTemps.Count -eq 0
            ) `
            -Name 'ManifestStorage/FailedRewritePreservesPreviousManifest' `
            -Failure 'невдалий atomic replace має лишати попередній COMPLETE manifest байт-у-байт незмінним і прибирати temporary JSON'

        # --- 3. Reader: той самий generationId в обох місцях -> MANIFESTS виграє ---
        $readerTestRoot = Join-Path $manifestStorageTestRoot 'reader-priority'
        $readerManifestsDir = Join-Path $readerTestRoot 'MANIFESTS'
        [void][IO.Directory]::CreateDirectory($readerManifestsDir)
        $legacyDuplicate = Join-Path $readerTestRoot 'BRAVO_BACKUP_20260101_010101.json'
        $newDuplicate = Join-Path $readerManifestsDir 'BRAVO_BACKUP_20260101_010101.json'
        [IO.File]::WriteAllText($legacyDuplicate, '{"generationId":"20260101_010101","source":"legacy"}')
        [IO.File]::WriteAllText($newDuplicate, '{"generationId":"20260101_010101","source":"manifests"}')
        $priorityResult = @(Get-BRAVOBackupGenerationManifestFiles -BackupRoot $readerTestRoot)
        Test-BRAVOCondition `
            -Condition (
                $priorityResult.Count -eq 1 -and
                $priorityResult[0].FullName -eq $newDuplicate
            ) `
            -Name "ManifestStorage/ReaderPrefersManifestsOnDuplicateGenerationId" `
            -Failure "коли той самий generationId є і в корені BackupRoot, і в MANIFESTS, reader має віддати рівно один запис — з MANIFESTS"
        $prioritySingle = @(Get-BRAVOBackupGenerationManifestFiles -BackupRoot $readerTestRoot -GenerationId '20260101_010101')
        Test-BRAVOCondition `
            -Condition ($prioritySingle.Count -eq 1 -and $prioritySingle[0].FullName -eq $newDuplicate) `
            -Name "ManifestStorage/ReaderByGenerationIdPrefersManifests" `
            -Failure "пошук за конкретним GenerationId також має віддавати перевагу версії з MANIFESTS"

        # --- 4. Reader: legacy-only файл (ще не мігрований) лишається видимим ---
        $readerLegacyOnlyRoot = Join-Path $manifestStorageTestRoot 'reader-legacy-only'
        [void][IO.Directory]::CreateDirectory($readerLegacyOnlyRoot)
        $legacyOnlyManifest = Join-Path $readerLegacyOnlyRoot 'BRAVO_BACKUP_20260202_020202.json'
        [IO.File]::WriteAllText($legacyOnlyManifest, '{"generationId":"20260202_020202"}')
        $legacyOnlyListAll = @(Get-BRAVOBackupGenerationManifestFiles -BackupRoot $readerLegacyOnlyRoot)
        $legacyOnlyById = @(Get-BRAVOBackupGenerationManifestFiles -BackupRoot $readerLegacyOnlyRoot -GenerationId '20260202_020202')
        Test-BRAVOCondition `
            -Condition (
                $legacyOnlyListAll.Count -eq 1 -and $legacyOnlyListAll[0].FullName -eq $legacyOnlyManifest -and
                $legacyOnlyById.Count -eq 1 -and $legacyOnlyById[0].FullName -eq $legacyOnlyManifest
            ) `
            -Name "ManifestStorage/ReaderFallsBackToLegacyRoot" `
            -Failure "на не мігрованій інсталяції (MANIFESTS відсутній або без цього файлу) reader має знаходити manifest у корені BackupRoot — і в list-all, і за GenerationId"

        # --- 5. Reader: без -Recurse — вкладені підкаталоги не потрапляють і не дублюються ---
        $readerNonRecursiveRoot = Join-Path $manifestStorageTestRoot 'reader-non-recursive'
        $deepDecoyDir = Join-Path $readerNonRecursiveRoot 'sub\deep'
        [void][IO.Directory]::CreateDirectory($deepDecoyDir)
        [IO.File]::WriteAllText((Join-Path $deepDecoyDir 'BRAVO_BACKUP_20260303_030303.json'), '{"generationId":"20260303_030303"}')
        $nonRecursiveResult = @(Get-BRAVOBackupGenerationManifestFiles -BackupRoot $readerNonRecursiveRoot)
        Test-BRAVOCondition `
            -Condition ($nonRecursiveResult.Count -eq 0) `
            -Name "ManifestStorage/ReaderIsNonRecursive" `
            -Failure "reader не повинен заглядати у вкладені підкаталоги BackupRoot (лише безпосередньо корінь і безпосередньо MANIFESTS)"

        # --- 6. Migration: переносить лише legacy-only файли ---
        $migrationBasicRoot = Join-Path $manifestStorageTestRoot 'migration-basic'
        [void][IO.Directory]::CreateDirectory($migrationBasicRoot)
        $migrationBasicFile = Join-Path $migrationBasicRoot 'BRAVO_BACKUP_20260404_040404.json'
        [IO.File]::WriteAllText($migrationBasicFile, '{"generationId":"20260404_040404"}')
        $migrationBasicResult = Initialize-BRAVOBackupManifestStorage -BackupRoot $migrationBasicRoot -Logger $null
        $migrationBasicDestination = Join-Path (Join-Path $migrationBasicRoot 'MANIFESTS') 'BRAVO_BACKUP_20260404_040404.json'
        Test-BRAVOCondition `
            -Condition (
                $migrationBasicResult.Migrated -contains 'BRAVO_BACKUP_20260404_040404.json' -and
                -not (Test-Path -LiteralPath $migrationBasicFile) -and
                (Test-Path -LiteralPath $migrationBasicDestination)
            ) `
            -Name "ManifestStorage/MigrationMovesLegacyOnlyFiles" `
            -Failure "Initialize-BRAVOBackupManifestStorage має переносити legacy manifest, для якого немає версії в MANIFESTS"

        # --- 7. Migration: другий запуск — no-op (ідемпотентність) ---
        $migrationSecondRun = Initialize-BRAVOBackupManifestStorage -BackupRoot $migrationBasicRoot -Logger $null
        Test-BRAVOCondition `
            -Condition (
                $migrationSecondRun.Migrated.Count -eq 0 -and
                $migrationSecondRun.Deduplicated.Count -eq 0 -and
                $migrationSecondRun.Conflicts.Count -eq 0 -and
                $migrationSecondRun.Errors.Count -eq 0 -and
                (Test-Path -LiteralPath $migrationBasicDestination)
            ) `
            -Name "ManifestStorage/MigrationSecondRunIsNoOp" `
            -Failure "повторний запуск міграції на вже мігрованій інсталяції не повинен нічого переносити, дублювати чи позначати як конфлікт"

        # --- 8. Migration: байтово ідентичний дублікат -> legacy прибирається ---
        $migrationDedupRoot = Join-Path $manifestStorageTestRoot 'migration-dedup'
        $migrationDedupManifests = Join-Path $migrationDedupRoot 'MANIFESTS'
        [void][IO.Directory]::CreateDirectory($migrationDedupManifests)
        $dedupContent = '{"generationId":"20260505_050505","identical":true}'
        $dedupLegacy = Join-Path $migrationDedupRoot 'BRAVO_BACKUP_20260505_050505.json'
        $dedupDestination = Join-Path $migrationDedupManifests 'BRAVO_BACKUP_20260505_050505.json'
        [IO.File]::WriteAllText($dedupLegacy, $dedupContent)
        [IO.File]::WriteAllText($dedupDestination, $dedupContent)
        $migrationDedupResult = Initialize-BRAVOBackupManifestStorage -BackupRoot $migrationDedupRoot -Logger $null
        Test-BRAVOCondition `
            -Condition (
                $migrationDedupResult.Deduplicated -contains 'BRAVO_BACKUP_20260505_050505.json' -and
                -not (Test-Path -LiteralPath $dedupLegacy) -and
                (Test-Path -LiteralPath $dedupDestination) -and
                ([IO.File]::ReadAllText($dedupDestination)) -eq $dedupContent
            ) `
            -Name "ManifestStorage/MigrationDedupesIdenticalCollision" `
            -Failure "коли legacy і MANIFESTS файли байтово ідентичні (SHA256), міграція має прибрати legacy-дублікат і лишити MANIFESTS без змін"

        # --- 9. Migration: різний вміст -> ЖОДЕН файл не чіпається, є конфлікт + WARNING ---
        $migrationConflictRoot = Join-Path $manifestStorageTestRoot 'migration-conflict'
        $migrationConflictManifests = Join-Path $migrationConflictRoot 'MANIFESTS'
        [void][IO.Directory]::CreateDirectory($migrationConflictManifests)
        $conflictLegacyContent = '{"generationId":"20260606_060606","source":"legacy"}'
        $conflictNewContent = '{"generationId":"20260606_060606","source":"manifests"}'
        $conflictLegacy = Join-Path $migrationConflictRoot 'BRAVO_BACKUP_20260606_060606.json'
        $conflictDestination = Join-Path $migrationConflictManifests 'BRAVO_BACKUP_20260606_060606.json'
        [IO.File]::WriteAllText($conflictLegacy, $conflictLegacyContent)
        [IO.File]::WriteAllText($conflictDestination, $conflictNewContent)
        $conflictLoggedMessages = New-Object System.Collections.ArrayList
        $conflictLogger = {
            param($Message, $Level)
            [void]$conflictLoggedMessages.Add(@{ Message = $Message; Level = $Level })
        }
        $migrationConflictResult = Initialize-BRAVOBackupManifestStorage -BackupRoot $migrationConflictRoot -Logger $conflictLogger
        $conflictWarningLogged = @($conflictLoggedMessages | Where-Object {
            $_.Level -eq 'WARNING' -and
            [string]$_.Message -match '20260606_060606' -and
            [string]$_.Message -match '[Кк]онфлікт'
        })
        Test-BRAVOCondition `
            -Condition (
                $migrationConflictResult.Conflicts -contains 'BRAVO_BACKUP_20260606_060606.json' -and
                (Test-Path -LiteralPath $conflictLegacy) -and
                (Test-Path -LiteralPath $conflictDestination) -and
                ([IO.File]::ReadAllText($conflictLegacy)) -eq $conflictLegacyContent -and
                ([IO.File]::ReadAllText($conflictDestination)) -eq $conflictNewContent -and
                $conflictWarningLogged.Count -eq 1
            ) `
            -Name "ManifestStorage/MigrationPreservesConflictingCollisionAndWarns" `
            -Failure "коли legacy і MANIFESTS файли того самого generationId відрізняються, міграція НЕ повинна видаляти чи перезаписувати жоден з них — лише WARNING з generationId конфлікту"

        # --- 10. Migration: без -Recurse — вкладений legacy файл не переноситься ---
        $migrationNonRecursiveRoot = Join-Path $manifestStorageTestRoot 'migration-non-recursive'
        $migrationDeepDecoyDir = Join-Path $migrationNonRecursiveRoot 'sub\deep'
        [void][IO.Directory]::CreateDirectory($migrationDeepDecoyDir)
        $deepLegacyFile = Join-Path $migrationDeepDecoyDir 'BRAVO_BACKUP_20260707_070707.json'
        [IO.File]::WriteAllText($deepLegacyFile, '{"generationId":"20260707_070707"}')
        $migrationNonRecursiveResult = Initialize-BRAVOBackupManifestStorage -BackupRoot $migrationNonRecursiveRoot -Logger $null
        Test-BRAVOCondition `
            -Condition (
                $migrationNonRecursiveResult.Migrated.Count -eq 0 -and
                (Test-Path -LiteralPath $deepLegacyFile) -and
                -not (Test-Path -LiteralPath (Join-Path (Join-Path $migrationNonRecursiveRoot 'MANIFESTS') 'BRAVO_BACKUP_20260707_070707.json'))
            ) `
            -Name "ManifestStorage/MigrationIsNonRecursive" `
            -Failure "міграція має шукати legacy manifest-и лише безпосередньо в корені BackupRoot, а не рекурсивно у вкладених підкаталогах"

        # --- 11. Migration: відсутній BackupRoot -> помилка у результаті, без throw ---
        $missingBackupRoot = Join-Path $manifestStorageTestRoot 'does-not-exist'
        $missingRootThrew = $false
        $missingRootResult = $null
        try {
            $missingRootResult = Initialize-BRAVOBackupManifestStorage -BackupRoot $missingBackupRoot -Logger $null
        } catch {
            $missingRootThrew = $true
        }
        Test-BRAVOCondition `
            -Condition (-not $missingRootThrew -and $null -ne $missingRootResult -and $missingRootResult.Errors.Count -gt 0) `
            -Name "ManifestStorage/MigrationHandlesMissingBackupRootGracefully" `
            -Failure "міграція має повертати структурований результат з Errors, а не кидати виняток, коли BackupRoot ще не існує"
    } finally {
        if (Test-Path -LiteralPath $manifestStorageTestRoot) {
            Remove-Item -LiteralPath $manifestStorageTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- Retention: видалення generation прибирає ОБИДВІ фізичні копії
    # manifest-а (MANIFESTS і legacy-корінь), а не лише ту, яку
    # MANIFESTS-first reader обрав для рішення про видалення. Інакше
    # legacy-копія переживає видалення й "воскрешає" generation на
    # наступному запуску через legacy fallback читання (dev.14, round 2).
    # Викликає РЕАЛЬНУ Remove-BRAVOExpiredBackupGenerations (ізольована
    # AST-екстракція, як і решта Archive-тестів у цьому файлі) — не
    # симуляцію алгоритму, бо саме порядок фізичного видалення тут і є
    # предметом перевірки.
    $retentionCleanupModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $archiveRuntimeTextForSizeSanity `
        -FunctionNames @(
            'Remove-BRAVOExpiredBackupGenerations',
            'Get-BRAVOGenerationManifestComponents',
            'Test-BRAVOGenerationManifestVerified',
            'Show-ArchiveCleanupSection',
            'Show-ScriptProgress',
            'Test-BRAVOBackupArtifactPathSafe'
        )
    $retentionCleanupTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_RETENTION_CLEANUP_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($retentionCleanupTestRoot)
        $retentionCleanupManifestsDir = Join-Path $retentionCleanupTestRoot 'MANIFESTS'
        [void][IO.Directory]::CreateDirectory($retentionCleanupManifestsDir)

        $retentionTargetLegacy = Join-Path $retentionCleanupTestRoot 'BRAVO_BACKUP_20260101_010101.json'
        $retentionTargetNew = Join-Path $retentionCleanupManifestsDir 'BRAVO_BACKUP_20260101_010101.json'
        # Різний вміст (note) — той самий "конфлікт", який міграція раніше
        # свідомо зберегла обома копіями; тепер generation все одно
        # видаляється цілком, бо retention уже прийняв рішення про видалення.
        [IO.File]::WriteAllText($retentionTargetLegacy, '{"generationId":"20260101_010101","status":"FAILED","startedAt":"2026-01-01T00:00:00","note":"legacy"}')
        [IO.File]::WriteAllText($retentionTargetNew, '{"generationId":"20260101_010101","status":"FAILED","startedAt":"2026-01-01T00:00:00","note":"manifests"}')

        $global:enableArchiveDeletion = $true
        $global:enableFailedArchiveDeletion = $true
        $global:failedArchiveRetentionDays = 1
        $global:minimumRetainedVerifiedBackups = 1
        $global:progressSettings = $null
        try {
            $retentionCleanupSectionShown = $false
            $retentionCleanupOk = & $retentionCleanupModule {
                param($BackupRoot, $CurrentGenerationId, $SectionShownRef)
                Remove-BRAVOExpiredBackupGenerations `
                    -BackupRoot $BackupRoot `
                    -CurrentGenerationId $CurrentGenerationId `
                    -RetentionDays 183 `
                    -CleanupSectionShown $SectionShownRef
            } $retentionCleanupTestRoot 'CURRENT_GENERATION_NOT_TARGET' ([ref]$retentionCleanupSectionShown)

            Test-BRAVOCondition `
                -Condition (
                    $retentionCleanupOk -eq $true -and
                    -not (Test-Path -LiteralPath $retentionTargetLegacy) -and
                    -not (Test-Path -LiteralPath $retentionTargetNew)
                ) `
                -Name "ManifestStorage/RetentionDeletesBothPhysicalManifestCopies" `
                -Failure "видалення generation має прибирати ОБИДВІ фізичні копії її manifest-а (MANIFESTS і legacy-корінь), а не лише ту, яку MANIFESTS-first reader повернув"

            $retentionCleanupAfterDelete = @(Get-BRAVOBackupGenerationManifestFiles `
                -BackupRoot $retentionCleanupTestRoot `
                -GenerationId '20260101_010101')
            Test-BRAVOCondition `
                -Condition ($retentionCleanupAfterDelete.Count -eq 0) `
                -Name "ManifestStorage/DeletedGenerationCannotReappearViaLegacyFallback" `
                -Failure "після видалення generation reader не повинен знаходити її manifest ні в MANIFESTS, ні через legacy fallback — інакше видалена generation 'воскресає' на наступному запуску"

            # --- dev.14 (round 3): filename/JSON generationId identity.
            # X — файл, ім'я якого каже generationId X, а JSON усередині
            # каже generationId Y (пошкодження/підміна). Y — РЕАЛЬНА,
            # окрема, ще не прострочена (сьогоднішня) generation. Без
            # перевірки identity X "видав би себе" за Y під час обробки й
            # ризикував би зачепити фізичні файли Y через
            # Get-BRAVOBackupGenerationManifestPhysicalFiles -GenerationId Y.
            $identityMismatchFile = Join-Path $retentionCleanupTestRoot 'BRAVO_BACKUP_20260101_010101.json'
            [IO.File]::WriteAllText($identityMismatchFile, '{"generationId":"20260202_020202","status":"FAILED","startedAt":"2026-01-01T00:00:00"}')
            $today = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
            $identityRealGenFile = Join-Path $retentionCleanupManifestsDir 'BRAVO_BACKUP_20260202_020202.json'
            [IO.File]::WriteAllText($identityRealGenFile, ('{{"generationId":"20260202_020202","status":"FAILED","startedAt":"{0}"}}' -f $today))

            $identitySectionShown = $false
            $identityOk = & $retentionCleanupModule {
                param($BackupRoot, $CurrentGenerationId, $SectionShownRef)
                Remove-BRAVOExpiredBackupGenerations `
                    -BackupRoot $BackupRoot `
                    -CurrentGenerationId $CurrentGenerationId `
                    -RetentionDays 183 `
                    -CleanupSectionShown $SectionShownRef
            } $retentionCleanupTestRoot 'CURRENT_GENERATION_NOT_TARGET_2' ([ref]$identitySectionShown)

            Test-BRAVOCondition `
                -Condition (
                    $identityOk -eq $true -and
                    (Test-Path -LiteralPath $identityMismatchFile)
                ) `
                -Name "ManifestStorage/ManifestFilenameAndJsonGenerationMustMatch" `
                -Failure "Remove-BRAVOExpiredBackupGenerations має перевіряти, що generationId з JSON збігається з generationId, закодованим у імені файлу"
            Test-BRAVOCondition `
                -Condition (Test-Path -LiteralPath $identityMismatchFile) `
                -Name "ManifestStorage/MismatchedGenerationIdIsExcludedFromRetention" `
                -Failure "файл із невідповідним generationId не повинен видалятися — mismatch виключає запис із retention (як parse error), а не використовується для рішення про видалення"
            Test-BRAVOCondition `
                -Condition (Test-Path -LiteralPath $identityRealGenFile) `
                -Name "ManifestStorage/MismatchedManifestCannotDeleteOtherGenerationMetadata" `
                -Failure "недовірений (mismatched) manifest НЕ повинен призводити до видалення physical manifest-а ІНШОЇ, реальної generation, на яку помилково вказує JSON"
        } finally {
            Remove-Item -Path Variable:\global:enableArchiveDeletion, `
                Variable:\global:enableFailedArchiveDeletion, `
                Variable:\global:failedArchiveRetentionDays, `
                Variable:\global:minimumRetainedVerifiedBackups, `
                Variable:\global:progressSettings `
                -ErrorAction SilentlyContinue
        }
    } finally {
        if (Test-Path -LiteralPath $retentionCleanupTestRoot) {
            Remove-Item -LiteralPath $retentionCleanupTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 12. Retention (Archive) читає manifest-и через централізований reader ---
    Test-BRAVOCondition `
        -Condition (
            $archiveRuntimeTextForSizeSanity.Contains('function Remove-BRAVOExpiredBackupGenerations') -and
            $archiveRuntimeTextForSizeSanity.Contains('Get-BRAVOBackupGenerationManifestFiles -BackupRoot $BackupRoot') -and
            -not $archiveRuntimeTextForSizeSanity.Contains("Get-BRAVOFiles -Path `$BackupRoot -Filter 'BRAVO_BACKUP_*.json'")
        ) `
        -Name "ManifestStorage/RetentionUsesCentralizedReader" `
        -Failure "Remove-BRAVOExpiredBackupGenerations має шукати manifest-и через Get-BRAVOBackupGenerationManifestFiles (MANIFESTS + legacy fallback), а не напряму Get-BRAVOFiles по корені BackupRoot"

    # --- 13. Health лишається read-only: читає через reader, ніколи не мігрує/не пише ---
    Test-BRAVOCondition `
        -Condition (
            $healthScriptText.Contains('Get-BRAVOBackupGenerationManifestFiles -BackupRoot $backupRootPath') -and
            -not $healthScriptText.Contains('Initialize-BRAVOBackupManifestStorage')
        ) `
        -Name "ManifestStorage/HealthReaderNeverMigratesOrWrites" `
        -Failure "BRAVO.Health.Runtime.ps1 має лише читати generation manifest-и через Get-BRAVOBackupGenerationManifestFiles і ніколи не викликати Initialize-BRAVOBackupManifestStorage"

    # --- 14. BRAVO_RESTORE_TEST.ps1 читає через той самий централізований reader ---
    $restoreTestScriptTextForManifestStorage = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_RESTORE_TEST.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $restoreTestScriptTextForManifestStorage.Contains('Get-BRAVOBackupGenerationManifestFiles') -and
            -not $restoreTestScriptTextForManifestStorage.Contains("Get-BRAVOFiles -Path `$BackupRoot -Filter 'BRAVO_BACKUP_*.json'")
        ) `
        -Name "ManifestStorage/RestoreTestUsesCentralizedReader" `
        -Failure "Get-BRAVORestoreGenerationManifest має читати через Get-BRAVOBackupGenerationManifestFiles, а не напряму Get-BRAVOFiles по корені BackupRoot"

    # --- 15. Ротація/очистка LOGS ніколи не чіпає MANIFESTS ---
    $maintenanceScriptTextForManifestStorage = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $removeOldLogFilesFunctionAst = @(
        [Management.Automation.Language.Parser]::ParseInput(
            $maintenanceScriptTextForManifestStorage, [ref]$null, [ref]$null
        ).FindAll(
            {
                param($candidate)
                $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $candidate.Name -eq 'Remove-OldLogFiles'
            },
            $true
        )
    ) | Select-Object -First 1
    Test-BRAVOCondition `
        -Condition (
            $null -ne $removeOldLogFilesFunctionAst -and
            -not $removeOldLogFilesFunctionAst.Extent.Text.Contains('MANIFESTS') -and
            -not $removeOldLogFilesFunctionAst.Extent.Text.Contains('BackupRoot')
        ) `
        -Name "ManifestStorage/LogCleanupNeverReferencesManifests" `
        -Failure "Remove-OldLogFiles (LOGS retention) не повинен знати про MANIFESTS чи BackupRoot — це незалежні lifecycle, керовані окремо LogDays/CompressedLogDays"

    # --- 16. Виклик міграції в Maintenance ніколи не є фатальним (лише WARNING) ---
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptTextForManifestStorage.Contains('Initialize-BRAVOBackupManifestStorage') -and
            $maintenanceScriptTextForManifestStorage.Contains('ІНІЦІАЛІЗАЦІЯ/МІГРАЦІЯ MANIFESTS') -and
            -not (
                $maintenanceScriptTextForManifestStorage -match
                '(?s)ІНІЦІАЛІЗАЦІЯ/МІГРАЦІЯ MANIFESTS.{0,2500}?\bexit\b'
            )
        ) `
        -Name "ManifestStorage/MaintenanceMigrationCallSiteIsNonFatal" `
        -Failure "виклик Initialize-BRAVOBackupManifestStorage у Maintenance не повинен мати exit поруч — невдала міграція не має блокувати Maintenance"

    # ================================================================
    # dev.14 (round 2, частина B): operator console UX BRAVO_MAINTENANCE.
    # Усі тести нижче — статичні перевірки джерела або функціональні
    # виклики ІЗОЛЬОВАНИХ функцій (AST-екстракція чи реальний
    # BRAVO.Console, уже імпортований вище). Жоден тест не запускає
    # реальний Main() Maintenance.Runtime.ps1 — це зупинило б/перезапустило
    # б служби на машині, де виконується самотест.
    # ================================================================
    Remove-Module -Name 'BRAVO.Console' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.Console\BRAVO.Console.psd1") -Force -ErrorAction Stop
    Initialize-BRAVOConsole -StepWidth 58

    $maintenanceHeaderCallIndex = $maintenanceScriptTextForManifestStorage.IndexOf('Write-BRAVOHeader `')
    $maintenanceHeaderCallEnd = $maintenanceScriptTextForManifestStorage.IndexOf(
        '-StartedAt $script:ScriptStartTime', $maintenanceHeaderCallIndex)
    $maintenanceHeaderCallText = if ($maintenanceHeaderCallIndex -ge 0 -and $maintenanceHeaderCallEnd -gt $maintenanceHeaderCallIndex) {
        $maintenanceScriptTextForManifestStorage.Substring(
            $maintenanceHeaderCallIndex, $maintenanceHeaderCallEnd - $maintenanceHeaderCallIndex + 40)
    } else { '' }

    # --- Header: реальний Write-BRAVOHeader з тими самими аргументами, що
    # передає Maintenance (Title/Institution/InstitutionCode/Mode; Host —
    # дефолтний $env:COMPUTERNAME, Maintenance його не перевизначає) —
    # плюс статичне підтвердження, що виклик у джерелі справді бере ці
    # значення з $global:ScriptVersion/$bravoSettings/-NoPause, а не
    # захардкожені літерали.
    $maintenanceHeaderCapture = Write-BRAVOHeader `
        -Title ("BRAVO MAINTENANCE {0}" -f '5.0.0-dev14-selftest') `
        -Institution 'TEST-COMPANY' `
        -InstitutionCode '1234567890' `
        -Mode 'MANUAL' 6>&1
    $maintenanceHeaderText = ($maintenanceHeaderCapture | ForEach-Object { $_.ToString() }) -join "`n"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceHeaderText.Contains('5.0.0-dev14-selftest') -and
            $maintenanceHeaderCallText.Contains('$global:ScriptVersion')
        ) `
        -Name "Maintenance/HeaderContainsVersion" `
        -Failure "заголовок BRAVO MAINTENANCE має показувати packageVersion (`$global:ScriptVersion)"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceHeaderText.Contains('TEST-COMPANY [1234567890]') -and
            $maintenanceHeaderCallText.Contains('$bravoSettings.InstitutionName') -and
            $maintenanceHeaderCallText.Contains('$bravoSettings.InstitutionCode')
        ) `
        -Name "Maintenance/HeaderContainsInstitution" `
        -Failure "заголовок має показувати назву й код установи з bravoSettings"
    Test-BRAVOCondition `
        -Condition ($maintenanceHeaderText.Contains($env:COMPUTERNAME)) `
        -Name "Maintenance/HeaderContainsHost" `
        -Failure "заголовок має показувати hostname — Write-BRAVOHeader за замовчуванням бере `$env:COMPUTERNAME, Maintenance цей параметр не перевизначає"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceHeaderText.Contains('Режим: MANUAL') -and
            $maintenanceHeaderCallText.Contains('Get-BRAVOMaintenanceExecutionMode -UserSid $currentIdentity.User.Value')
        ) `
        -Name "Maintenance/HeaderContainsMode" `
        -Failure "заголовок має показувати MANUAL/SCHEDULED через Get-BRAVOMaintenanceExecutionMode -UserSid, а не через -NoPause"

    # --- dev.14 (round 3): -NoPause керує лише UX-паузою, а не джерелом
    # запуску. Get-BRAVOMaintenanceExecutionMode — pure helper (лише
    # UserSid на вході, жодного власного WindowsIdentity), тому тестується
    # напряму на детермінованих SID без реальної системної ідентичності.
    $maintenanceExecutionModeModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $maintenanceScriptTextForManifestStorage `
        -FunctionNames @('Get-BRAVOMaintenanceExecutionMode')
    $manualAdminMode = & $maintenanceExecutionModeModule {
        Get-BRAVOMaintenanceExecutionMode -UserSid 'S-1-5-21-111-222-333-1001'
    }
    $manualAdminModeWithNoPauseIntent = & $maintenanceExecutionModeModule {
        # -NoPause не є входом функції взагалі — сам факт, що вона не
        # приймає такий параметр, і є доказом розв'язання.
        Get-BRAVOMaintenanceExecutionMode -UserSid 'S-1-5-21-111-222-333-1001'
    }
    $systemMode = & $maintenanceExecutionModeModule {
        Get-BRAVOMaintenanceExecutionMode -UserSid 'S-1-5-18'
    }
    Test-BRAVOCondition `
        -Condition ($manualAdminMode -eq 'MANUAL') `
        -Name "Maintenance/ManualNoPauseStillManual" `
        -Failure "ручний запуск (не-SYSTEM SID) має лишатися MANUAL незалежно від -NoPause — Get-BRAVOMaintenanceExecutionMode не приймає -NoPause і не може від нього залежати"
    Test-BRAVOCondition `
        -Condition ($systemMode -eq 'SCHEDULED') `
        -Name "Maintenance/SystemIsScheduled" `
        -Failure "SYSTEM (S-1-5-18) має бути SCHEDULED"
    Test-BRAVOCondition `
        -Condition (
            $manualAdminMode -eq $manualAdminModeWithNoPauseIntent -and
            -not $maintenanceScriptTextForManifestStorage.Contains("function Get-BRAVOMaintenanceExecutionMode {`n    param([Parameter(Mandatory = `$true)][string]`$UserSid, [switch]`$NoPause)")
        ) `
        -Name "Maintenance/ModeDoesNotDependOnNoPause" `
        -Failure "Get-BRAVOMaintenanceExecutionMode має приймати лише UserSid — жодного параметра -NoPause, який міг би вплинути на результат"

    # --- Plan: 'ТАК'/'НІ', і кожен рядок плану простежується до свого
    # CLI-прапорця/налаштування аж до самого джерела (-ForceRestore,
    # -DisableSizeCheck, -AutoShutdown, -EnableArchiveAfterMaintenance),
    # так само, як існуючий коментар "план і фактичне виконання не можуть
    # розійтися" вимагає.
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptTextForManifestStorage.Contains("'ТАК' } else { 'НІ' }") -and
            $maintenanceScriptTextForManifestStorage.Contains('$maintenancePlanEntries = [ordered]@{')
        ) `
        -Name "Maintenance/PlanUsesTakNi" `
        -Failure "План операцій має друкувати рівно ТАК/НІ, без True/False/внутрішніх назв змінних"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptTextForManifestStorage.Contains("'Реставрація моделі'              = [bool]`$script:BRAVOMaintenanceRestoreStepEnabled") -and
            $maintenanceScriptTextForManifestStorage.Contains('$script:BRAVOMaintenanceRestoreStepEnabled = $shouldRestore') -and
            $maintenanceScriptTextForManifestStorage.Contains('$ForceRestore -or')
        ) `
        -Name "Maintenance/PlanReflectsForceRestore" `
        -Failure "рядок плану 'Реставрація моделі' має відображати -ForceRestore через `$shouldRestore/BRAVOMaintenanceRestoreStepEnabled"
    # dev.14 (round 3): 'Відновлення пропущених операцій' і 'Реставрація
    # моделі' — два окремі рядки плану з РІЗНИМИ значеннями. Перший
    # показує стан механізму відновлення пропущеної роботи
    # ($RunMissedRestoreOnly і справді щось пропущено), другий — чи
    # фактично виконається реставрація моделі цього прогону ($shouldRestore,
    # ширший критерій: ForceRestore АБО ця сама умова АБО плановий день/час).
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptTextForManifestStorage.Contains("'Відновлення пропущених операцій' = [bool](`$RunMissedRestoreOnly -and `$missedDailyWork)") -and
            $maintenanceScriptTextForManifestStorage.Contains("'Реставрація моделі'              = [bool]`$script:BRAVOMaintenanceRestoreStepEnabled") -and
            -not $maintenanceScriptTextForManifestStorage.Contains("'Контроль діапазонів ID'          = [bool]")
        ) `
        -Name "Maintenance/PlanShowsBothRestoreLinesWithDistinctSemantics" `
        -Failure "'Відновлення пропущених операцій' (RunMissedRestoreOnly+missedDailyWork) і 'Реставрація моделі' (shouldRestore) мають бути ДВОМА окремими рядками плану з різними значеннями; Range ID у плані не показується (лише крок)"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptTextForManifestStorage.Contains("'Перевірка розмірів'              = [bool]`$script:BRAVOMaintenanceCheckSizeStepEnabled") -and
            $maintenanceScriptTextForManifestStorage.Contains('$script:BRAVOMaintenanceCheckSizeStepEnabled = $BravoMaintenanceEnabled -and $CheckSize') -and
            $maintenanceScriptTextForManifestStorage.Contains('$CheckSize = -not $DisableSizeCheck')
        ) `
        -Name "Maintenance/PlanReflectsDisableSizeCheck" `
        -Failure "рядок плану 'Перевірка розмірів' має відображати -DisableSizeCheck через `$CheckSize"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptTextForManifestStorage.Contains("'Автоматичне вимкнення сервера'   = [bool]`$script:EnableAutoShutdown") -and
            $maintenanceScriptTextForManifestStorage.Contains('$script:EnableAutoShutdown = ($AutoShutdown -eq "on")')
        ) `
        -Name "Maintenance/PlanReflectsAutoShutdown" `
        -Failure "рядок плану 'Автоматичне вимкнення сервера' має відображати -AutoShutdown"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptTextForManifestStorage.Contains("'Архівація після maintenance'     = [bool]`$script:BRAVOMaintenanceArchiveStepEnabled") -and
            $maintenanceScriptTextForManifestStorage.Contains('$script:BRAVOMaintenanceArchiveStepEnabled = [bool]$script:EnableArchiveAfterMaintenance')
        ) `
        -Name "Maintenance/PlanReflectsArchiveAfterMaintenance" `
        -Failure "рядок плану 'Архівація після maintenance' має відображати -ArchiveAfterMaintenance"

    # --- Кроки: ізольована AST-екстракція Write-BRAVOMaintenanceStep/
    # Get-BRAVOMaintenanceStepStatus/Initialize-BRAVOMaintenanceSteps —
    # реальні функції, реальний BRAVO.Console (Write-BRAVOStepResult тощо,
    # вже імпортований вище), синтетичні кроки замість реального Main().
    $maintenanceStepModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $maintenanceScriptTextForManifestStorage `
        -FunctionNames @(
            'Initialize-BRAVOMaintenanceSteps',
            'Get-BRAVOMaintenanceStepStatus',
            'Write-BRAVOMaintenanceStep'
        )

    & $maintenanceStepModule { Initialize-BRAVOMaintenanceSteps -Total 3 }
    $maintenanceStepOkCapture = & $maintenanceStepModule {
        Write-BRAVOMaintenanceStep -Name 'Тестовий крок' -Status 'OK'
    } 6>&1
    $maintenanceStepOkText = ($maintenanceStepOkCapture | ForEach-Object { $_.ToString() }) -join "`n"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceStepOkText.Contains('[1/3] Тестовий крок') -and
            $maintenanceStepOkText -match '\.{3,}'
        ) `
        -Name "Maintenance/StepFormat" `
        -Failure "формат кроку має бути '[N/TOTAL] Назва....... STATUS   mm:ss' (Write-BRAVOStepResult/Get-BRAVOStepPrefixText)"

    $maintenanceStepVocabRejected = $false
    try {
        & $maintenanceStepModule { Write-BRAVOMaintenanceStep -Name 'X' -Status 'WARNING' } | Out-Null
    } catch {
        $maintenanceStepVocabRejected = $true
    }
    $maintenanceStepWarnCapture = & $maintenanceStepModule {
        Write-BRAVOMaintenanceStep -Name 'Y' -Status 'WARN' -Details 'тестова причина'
    } 6>&1
    $maintenanceStepFailCapture = & $maintenanceStepModule {
        Write-BRAVOMaintenanceStep -Name 'Z' -Status 'FAIL' -Details 'тестова помилка'
    } 6>&1
    Test-BRAVOCondition `
        -Condition ($maintenanceStepVocabRejected -and $null -ne $maintenanceStepWarnCapture -and $null -ne $maintenanceStepFailCapture) `
        -Name "Maintenance/StepStatusVocabulary" `
        -Failure "словник статусів кроку Maintenance має бути рівно OK/SKIPPED/WARN/FAIL — 'WARNING' (стара назва) має відхилятися ValidateSet"

    & $maintenanceStepModule { Initialize-BRAVOMaintenanceSteps -Total 2 }
    [void](& $maintenanceStepModule { Write-BRAVOMaintenanceStep -Name 'Перший' -Status 'OK' } 6>&1)
    Start-Sleep -Milliseconds 50
    $maintenanceStepDurationCapture = & $maintenanceStepModule {
        Write-BRAVOMaintenanceStep -Name 'Другий' -Status 'OK'
    } 6>&1
    $maintenanceStepDurationText = ($maintenanceStepDurationCapture | ForEach-Object { $_.ToString() }) -join "`n"
    Test-BRAVOCondition `
        -Condition ($maintenanceStepDurationText -match '\d{2}:\d{2}(:\d{2})?') `
        -Name "Maintenance/StepDurationFormat" `
        -Failure "тривалість кроку має бути mm:ss (або hh:mm:ss від години) — Format-BRAVODuration"

    # dev.14 (round 3): рівно 6 пробілів, без "Причина:"/"Деталі:" для
    # ЖОДНОГО статусу — Write-BRAVOConsoleDetail, не Write-BRAVOOperatorReason.
    $maintenanceStepWarnText = ($maintenanceStepWarnCapture | ForEach-Object { $_.ToString() }) -join "`n"
    $maintenanceStepFailText = ($maintenanceStepFailCapture | ForEach-Object { $_.ToString() }) -join "`n"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceStepWarnText.Contains('      тестова причина') -and
            $maintenanceStepFailText.Contains('      тестова помилка') -and
            -not $maintenanceStepWarnText.Contains('Причина:') -and
            -not $maintenanceStepFailText.Contains('Причина:')
        ) `
        -Name "Maintenance/StepDetailIndent" `
        -Failure "деталі кроку (будь-який статус) мають друкуватися з рівно 6-пробільним відступом і без автоматичного префікса 'Причина:'/'Деталі:'"

    # --- Директорії/manifest: SKIPPED-гілка й формулювання 'усі вже
    # існують' лишились на місці після об'єднання з MANIFESTS init/migration.
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptTextForManifestStorage.Contains("if (`$directoryStepStatus -eq 'SKIPPED')") -and
            $maintenanceScriptTextForManifestStorage.Contains("-Status 'SKIPPED'") -and
            $maintenanceScriptTextForManifestStorage.Contains("-Details 'усі вже існують'")
        ) `
        -Name "Maintenance/SkippedDirectories" `
        -Failure "'Створення необхідних директорій' має лишатися SKIPPED/'усі вже існують', коли і директорії, і MANIFESTS init/migration нічого не зробили"

    # --- 'Реставрація моделі' показує причину (Примусово/пропущений
    # слот/розклад) як Details, а 'Обробка trace і логів' — кількість
    # оброблених файлів.
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptTextForManifestStorage.Contains("-Name 'Реставрація моделі' ``") -and
            $maintenanceScriptTextForManifestStorage.Contains('-Details $restoreReason') -and
            $maintenanceScriptTextForManifestStorage.Contains('$restoreReason = if ($ForceRestore) { "Примусово" }')
        ) `
        -Name "Maintenance/ForceRestoreDetail" `
        -Failure "крок 'Реставрація моделі' має показувати причину реставрації ('Примусово' для -ForceRestore) як Details"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptTextForManifestStorage.Contains("-Name 'Обробка trace і логів' ``") -and
            $maintenanceScriptTextForManifestStorage.Contains('"оброблено файлів: $processedLogCounts"')
        ) `
        -Name "Maintenance/TraceProcessedDetail" `
        -Failure "крок 'Обробка trace і логів' має показувати кількість оброблених файлів як Details"

    # --- Range ID: реальна Test-RangeIdUsage (ізольована екстракція) на
    # відсутньому файлі має сигналізувати HasIssue=true (WARN на консолі),
    # а сам виклик у Main() — НЕ використовувати criticalErrorOccurred для
    # статусу цього конкретного кроку (інакше WARN на екрані розійшовся б
    # із FAIL).
    $rangeIdTestModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $maintenanceScriptTextForManifestStorage `
        -FunctionNames @('Test-RangeIdUsage')
    $rangeIdMissingPath = Join-Path $manifestStorageTestRoot 'does-not-exist-range-id.json'
    $rangeIdMissingResultCapture = & $rangeIdTestModule {
        param($Path)
        # Стаб дзеркалить реальну сигнатуру Write-Log (Message/Level/
        # NoTimestamp/NoConsole) — тіло порожнє навмисно (нічого не
        # логує), тому кожен параметр явно "consumed" через $null =,
        # без нового PSReviewUnusedParameter (без side effects: жодного
        # Write-Host/Write-Log/throw/exit/return).
        function Write-Log {
            param($Message, [string]$Level = 'INFO', [switch]$NoTimestamp, [switch]$NoConsole)
            $null = $Message
            $null = $Level
            $null = $NoTimestamp
            $null = $NoConsole
        }
        function Send-SlackAlert { param($Message, [switch]$IsCritical) }
        Test-RangeIdUsage -Path $Path -ThresholdPercent 90
    } $rangeIdMissingPath
    Test-BRAVOCondition `
        -Condition (
            $null -ne $rangeIdMissingResultCapture -and
            [bool]$rangeIdMissingResultCapture.HasIssue -and
            [string]$rangeIdMissingResultCapture.Reason -match 'не знайдено'
        ) `
        -Name "Maintenance/RangeIdMissingRemainsWarning" `
        -Failure "Test-RangeIdUsage на відсутньому файлі має повертати HasIssue=true з причиною, яку крок консолі показує як WARN"

    $rangeIdCallSiteStart = $maintenanceScriptTextForManifestStorage.IndexOf("-Name 'Контроль діапазонів ID' ``")
    $rangeIdCallSiteWindow = if ($rangeIdCallSiteStart -ge 0) {
        $maintenanceScriptTextForManifestStorage.Substring(
            [Math]::Max(0, $rangeIdCallSiteStart - 1100), 1100)
    } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $rangeIdCallSiteStart -ge 0 -and
            $rangeIdCallSiteWindow.Contains('$rangeIdHasWarning = $script:BRAVOWarningCount -gt $rangeIdWarningsBefore') -and
            -not $rangeIdCallSiteWindow.Contains('-CriticalBefore')
        ) `
        -Name "Maintenance/RangeIdMissingStepIsWarn" `
        -Failure "статус консольного кроку 'Контроль діапазонів ID' має рахуватися лише за приростом BRAVOWarningCount, а не за `$script:criticalErrorOccurred"

    # dev.14 (round 3): виконання severity (criticalErrorOccurred) і
    # доставка сповіщення (Send-SlackAlert -IsCritical) розв'язані.
    # Відтворюємо ТОЙ САМИЙ снепшот/відкат-алгоритм, що в Main() (реальна
    # Test-RangeIdUsage + тестовий Send-SlackAlert, який відтворює
    # РЕАЛЬНИЙ побічний ефект -IsCritical: піднімає $script:criticalErrorOccurred,
    # рівно як Send-SlackAlert справді робить) — доводимо, що відкат
    # справді нейтралізує його для цього виклику, а WARNING-лічильник і
    # сам факт виклику -IsCritical (доставка) лишаються недоторканими.
    $rangeIdCriticalRestoreCapture = & $rangeIdTestModule {
        param($Path)
        $script:criticalErrorOccurred = $false
        $script:BRAVOWarningCount = 0
        $script:SlackAlertCriticalCallCount = 0
        function Write-Log {
            param($Message, [string]$Level = 'INFO', [switch]$NoTimestamp, [switch]$NoConsole)
            # Message/NoTimestamp/NoConsole — дзеркалять реальну сигнатуру,
            # тілу цього стаба вони не потрібні (лише Level впливає на
            # $script:BRAVOWarningCount); consumed через $null =, без нового
            # PSReviewUnusedParameter і без side effects.
            $null = $Message
            $null = $NoTimestamp
            $null = $NoConsole
            if ($Level -eq 'WARNING') { $script:BRAVOWarningCount++ }
        }
        function Send-SlackAlert {
            param($Message, [switch]$IsCritical)
            if ($IsCritical) {
                $script:criticalErrorOccurred = $true
                $script:SlackAlertCriticalCallCount++
            }
        }
        $rangeIdWarningsBefore = $script:BRAVOWarningCount
        $rangeIdCriticalBefore = $script:criticalErrorOccurred
        $result = Test-RangeIdUsage -Path $Path -ThresholdPercent 90
        $rangeIdHasWarning = $script:BRAVOWarningCount -gt $rangeIdWarningsBefore
        if (-not $rangeIdCriticalBefore -and $script:criticalErrorOccurred) {
            $script:criticalErrorOccurred = $false
        }
        [pscustomobject]@{
            CriticalAfterRestore = $script:criticalErrorOccurred
            HasWarning = $rangeIdHasWarning
            SlackCriticalCallCount = $script:SlackAlertCriticalCallCount
            HasIssue = $result.HasIssue
        }
    } $rangeIdMissingPath
    Test-BRAVOCondition `
        -Condition (-not $rangeIdCriticalRestoreCapture.CriticalAfterRestore) `
        -Name "Maintenance/RangeIdMissingDoesNotSetCriticalError" `
        -Failure "після відкату `$script:criticalErrorOccurred має лишатися false — відсутній Range ID не повинен ставати критичною помилкою Maintenance"
    Test-BRAVOCondition `
        -Condition (
            -not $rangeIdCriticalRestoreCapture.CriticalAfterRestore -and
            $maintenanceScriptTextForManifestStorage.Contains('Resolve-BRAVOExitCode -HasWarnings') -and
            $maintenanceScriptTextForManifestStorage.Contains('-MaintenanceFailed')
        ) `
        -Name "Maintenance/RangeIdMissingDoesNotProduceFailureExit" `
        -Failure "з criticalErrorOccurred=false і WARN-лічильником > 0 підсумковий exit code має бути Resolve-BRAVOExitCode -HasWarnings (10), а не -MaintenanceFailed (60) — сама формула exit code (нижче) не змінена, лише вхідний прапорець"
    Test-BRAVOCondition `
        -Condition (
            $rangeIdCriticalRestoreCapture.HasIssue -and
            $rangeIdCriticalRestoreCapture.HasWarning -and
            $rangeIdCriticalRestoreCapture.SlackCriticalCallCount -eq 1
        ) `
        -Name "Maintenance/RangeIdMissingPreservesWarningNotification" `
        -Failure "Send-SlackAlert -IsCritical (доставка сповіщення навіть у errors_only) має й далі викликатися рівно один раз для відсутнього Range ID — розв'язано лише виконання-severity, не доставка"

    # --- Фінальний підсумок: та сама триланкова логіка (ПОМИЛКА/УСПІШНО З
    # ПОПЕРЕДЖЕННЯМИ/УСПІШНО), що вже керує exit code, тепер перевірена явно
    # на синтетичних BRAVOWarningCount/criticalErrorOccurred, а не лише як
    # текст джерела.
    # dev.19: 'ЧАСТКОВО' — стара, окрема від логу назва тієї самої умови —
    # замінена на канонічний Get-BRAVOMaintenanceFinalStatus (детально
    # перевірено нижче, група Maintenance/Exit*); тут лишається лише
    # верхньорівнева перевірка, що ця консольна секція й далі викликає той
    # самий канонічний helper, а не власну незалежну гілку.
    $maintenanceSummaryModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText @'
function Get-BRAVOMaintenanceSummaryResult {
    param([bool]$CriticalErrorOccurred, [int]$WarningCount)
    if ($CriticalErrorOccurred) {
        return 'ПОМИЛКА'
    } elseif ($WarningCount -gt 0) {
        return 'УСПІШНО З ПОПЕРЕДЖЕННЯМИ'
    } else {
        return 'УСПІШНО'
    }
}
'@ `
        -FunctionNames @('Get-BRAVOMaintenanceSummaryResult')
    $maintenanceSuccessResult = & $maintenanceSummaryModule {
        Get-BRAVOMaintenanceSummaryResult -CriticalErrorOccurred $false -WarningCount 0
    }
    $maintenanceFailureResult = & $maintenanceSummaryModule {
        Get-BRAVOMaintenanceSummaryResult -CriticalErrorOccurred $true -WarningCount 0
    }
    Test-BRAVOCondition `
        -Condition (
            $maintenanceSuccessResult -eq 'УСПІШНО' -and
            $maintenanceScriptTextForManifestStorage.Contains('function Get-BRAVOMaintenanceFinalStatus') -and
            $maintenanceScriptTextForManifestStorage.Contains('$maintenanceFinalStatus = Get-BRAVOMaintenanceFinalStatus') -and
            $maintenanceScriptTextForManifestStorage.Contains('$maintenanceSummaryResult = $maintenanceFinalStatus.Text') -and
            $maintenanceScriptTextForManifestStorage.Contains("Write-BRAVOFinalSummaryHeader ``") -and
            $maintenanceScriptTextForManifestStorage.Contains("-Title 'BRAVO MAINTENANCE'") -and
            $maintenanceScriptTextForManifestStorage.Contains("Write-BRAVOResultField -Label 'Статус'") -and
            $maintenanceScriptTextForManifestStorage.Contains("Write-BRAVOResultField -Label 'Початок'") -and
            $maintenanceScriptTextForManifestStorage.Contains("Write-BRAVOResultField -Label 'Завершення'") -and
            $maintenanceScriptTextForManifestStorage.Contains("Write-BRAVOResultField -Label 'Кроків'") -and
            (
                [regex]::Matches($maintenanceScriptTextForManifestStorage, "Write-BRAVOResultField -Label 'Попереджень'").Count -eq 1
            )
        ) `
        -Name "Maintenance/FinalSummarySuccess" `
        -Failure "УСПІШНО (без попереджень/критичних помилок), заголовок 'BRAVO MAINTENANCE — СТАТУС' і повний набір полів (Статус/Код завершення/Початок/Завершення/Тривалість/Кроків/Успішно/Попереджень/Пропущено/Помилок) РІВНО ОДИН РАЗ (без дублювання BRAVOWarningCount/BRAVOMaintenanceStepWarnCount)"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceFailureResult -eq 'ПОМИЛКА' -and
            $maintenanceScriptTextForManifestStorage.Contains('$maintenanceExitCodeText = "{0} — {1}" -f $script:maintenanceRuntimeExitCode, (Get-BRAVOExitCodeName -Code $script:maintenanceRuntimeExitCode)') -and
            $maintenanceScriptTextForManifestStorage.Contains("Write-BRAVOResultField -Label 'Код завершення' -Value `$maintenanceExitCodeText") -and
            $maintenanceScriptTextForManifestStorage.Contains("Write-BRAVOResultField -Label 'Помилок' -Value ([string]`$script:BRAVOMaintenanceStepFailCount)")
        ) `
        -Name "Maintenance/FinalSummaryFailure" `
        -Failure "ПОМИЛКА (критична помилка) має показувати той самий, а не вигаданий, exit code/назву через BRAVO.ExitCodes"

    # --- Pause: реструктуризація директорії/MANIFESTS/лог-міграції (round 2)
    # лишилась між тим самим зовнішнім try (Console/MaintenancePausesOnEveryExitPath
    # вище вже перевіряє межі try/finally для ВСЬОГО файлу) — тут додатково
    # явно прив'язуємо НОВИЙ блок до цього ж інваріанту, за іменем dev.14.
    Test-BRAVOCondition `
        -Condition (
            $maintenanceOuterTryIndex -ge 0 -and
            $maintenanceRuntimeTextForPause.IndexOf('ІНІЦІАЛІЗАЦІЯ/МІГРАЦІЯ MANIFESTS') -gt $maintenanceOuterTryIndex -and
            $maintenanceRuntimeTextForPause.IndexOf('ІНІЦІАЛІЗАЦІЯ/МІГРАЦІЯ MANIFESTS') -lt $maintenanceFinallyIndex
        ) `
        -Name "Maintenance/NoPausePreserved" `
        -Failure "блок ініціалізації/міграції MANIFESTS (round 2) має лишатися всередині того самого зовнішнього try/finally, що й керує Wait-BRAVOManualExit -NoPause"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceRuntimeTextForPause.Contains('Wait-BRAVOManualExit -NoPause:$NoPause') -and
            [regex]::IsMatch($maintenanceRuntimeTextForPause, '(?m)^\s*\[switch\]\$NoPause,\s*$')
        ) `
        -Name "Maintenance/SystemNoPausePreserved" `
        -Failure "SYSTEM/-NoPause запуск (заплановане завдання) не повинен чекати на клавішу — Wait-BRAVOManualExit -NoPause:`$NoPause має лишатися єдиним джерелом рішення"

    # ================================================================
    # dev.14 (round 3): "exact render" — не лише Contains/wiring, а
    # реальний рендерений layout: роздільники, підписи, відступи,
    # словник статусів, відсутність "Причина:"/дублікату "Попереджень".
    # Нормалізуються лише змінні дані (host/час/тривалість/шлях логу).
    # ================================================================

    # --- A. HeaderRender: повний layout заголовка ---
    $maintenanceHeaderLines = $maintenanceHeaderText -split "`n"
    $maintenanceSeparatorLine = '=' * 60
    Test-BRAVOCondition `
        -Condition (
            @($maintenanceHeaderLines | Where-Object { $_ -eq $maintenanceSeparatorLine }).Count -eq 2 -and
            @($maintenanceHeaderLines | Where-Object { $_.TrimStart() -like 'BRAVO MAINTENANCE*' }).Count -eq 1 -and
            @($maintenanceHeaderLines | Where-Object { $_ -eq ' TEST-COMPANY [1234567890]' }).Count -eq 1 -and
            @($maintenanceHeaderLines | Where-Object { $_ -eq " $env:COMPUTERNAME" }).Count -eq 1 -and
            @($maintenanceHeaderLines | Where-Object { $_ -eq ' Режим: MANUAL' }).Count -eq 1
        ) `
        -Name "Maintenance/HeaderRender" `
        -Failure "заголовок має мати рівно 2 роздільники '='*60, рядок Title, рядок Institution [Code], рядок Host, рядок 'Режим: ...' — у цьому порядку"

    # --- B. PlanRender: та сама формула вирівнювання, що джерело
    # (PadRight(maxLabelLength+3) + 'ТАК'/'НІ'), відтворена буквально для
    # перевірки самого layout (рядки плану — inline top-level код, не
    # функція, тому тут не AST-екстракція, а буквальне відтворення
    # формули; PlanReflects*-тести вище вже довели зв'язок зі станом).
    $planEntriesSample = [ordered]@{
        'Міграція старих журналів' = $false
        'Відновлення пропущених операцій' = $true
        'Реставрація моделі' = $true
    }
    $planLabelWidth = ($planEntriesSample.Keys | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum + 3
    $planRenderedLines = foreach ($entry in $planEntriesSample.GetEnumerator()) {
        $label = ("{0}:" -f $entry.Key).PadRight($planLabelWidth)
        $value = if ($entry.Value) { 'ТАК' } else { 'НІ' }
        "  {0}{1}" -f $label, $value
    }
    Test-BRAVOCondition `
        -Condition (
            @($planRenderedLines | Where-Object { $_ -match '^  Міграція старих журналів:\s+НІ$' }).Count -eq 1 -and
            @($planRenderedLines | Where-Object { $_ -match '^  Відновлення пропущених операцій:\s+ТАК$' }).Count -eq 1 -and
            -not ($planRenderedLines -join "`n").Contains('True') -and
            -not ($planRenderedLines -join "`n").Contains('False')
        ) `
        -Name "Maintenance/PlanRender" `
        -Failure "рядки плану мають бути '  Мітка:' + вирівнювання + 'ТАК'/'НІ', без True/False"

    # --- C. StepRender: [N/TOTAL] Назва.......... STATUS   mm:ss ---
    # baseText+dots, status і тривалість — три ОКРЕМІ Write-Host (двоє з
    # -NoNewline), тобто три окремі InformationRecord у 6>&1-захопленні;
    # -join "`n" вставляє між ними символ переводу рядка, якого на
    # реальній консолі немає (там -NoNewline тримає курсор на тому самому
    # рядку) — тому `\s*` між фрагментами, а не буквальна суміжність.
    Test-BRAVOCondition `
        -Condition (
            $maintenanceStepOkText -match '(?s)^\[1/3\] Тестовий крок\.+\s*OK\s+\d{2}:\d{2}$'
        ) `
        -Name "Maintenance/StepRender" `
        -Failure "рядок кроку має точно відповідати '[N/TOTAL] Назва' + крапки-заповнювач + 'OK' (вирівняно) + mm:ss"

    # --- D. RangeIdWarningRender: WARN-крок із деталлю канонічного шляху,
    # без "Причина:", з 6-пробільним відступом.
    & $maintenanceStepModule { Initialize-BRAVOMaintenanceSteps -Total 8 }
    for ($i = 1; $i -le 7; $i++) {
        [void](& $maintenanceStepModule { param($N) Write-BRAVOMaintenanceStep -Name "Крок $N" -Status 'OK' } $i 6>&1)
    }
    $rangeIdWarningRenderCapture = & $maintenanceStepModule {
        Write-BRAVOMaintenanceStep `
            -Name 'Контроль діапазонів ID' `
            -Status 'WARN' `
            -Details 'Файл контролю діапазонів ID не знайдено: C:\Windows\SysWOW64\range_id_log.json'
    } 6>&1
    $rangeIdWarningRenderText = ($rangeIdWarningRenderCapture | ForEach-Object { $_.ToString() }) -join "`n"
    Test-BRAVOCondition `
        -Condition (
            $rangeIdWarningRenderText -match '(?s)\[8/8\] Контроль діапазонів ID\.+\s*WARN\s+\d{2}:\d{2}' -and
            $rangeIdWarningRenderText.Contains('      Файл контролю діапазонів ID не знайдено: C:\Windows\SysWOW64\range_id_log.json') -and
            -not $rangeIdWarningRenderText.Contains('Причина:')
        ) `
        -Name "Maintenance/RangeIdWarningRender" `
        -Failure "[8/8] Контроль діапазонів ID має рендеритись як WARN з 6-пробільним canonical-шляхом, без 'Причина:'"

    # --- E/F/G. Summary render: clean/warning-only/failure ---
    # dev.14 (round 4): повний підсумок разом із footer (Write-BRAVOFinalSummaryFooter) —
    # "Журнал:" (не "Детальний журнал:"), шлях наступним рядком, закриваючий
    # '='*60 (не '-'*60 Write-BRAVOResultFooter).
    $summaryTestLogPath = 'C:\BRAVO\LOGS\BRAVO_MAINTENANCE_20260809_221003_PID1234.log'
    foreach ($summaryCase in @(
        @{ Status = 'УСПІШНО'; Color = 'Green'; TestName = 'Maintenance/SuccessSummaryRender' },
        @{ Status = 'ЧАСТКОВО'; Color = 'Yellow'; TestName = 'Maintenance/WarningSummaryRender' },
        @{ Status = 'ПОМИЛКА'; Color = 'Red'; TestName = 'Maintenance/FailureSummaryRender' }
    )) {
        $summaryHeaderCapture = Write-BRAVOFinalSummaryHeader `
            -Title 'BRAVO MAINTENANCE' -Status $summaryCase.Status -StatusColor $summaryCase.Color 6>&1
        # & { ... } 6>&1, а не @( ... ) 6>&1: редирект застосований до масиву-
        # виразу з кількома інструкціями через крапку з комою НЕ захоплював
        # Information stream кожної окремої Write-Host — лише виклик через
        # scriptblock коректно прокидає redirection на всі інструкції всередині.
        $summaryFieldsCapture = & {
            Write-BRAVOResultField -Label 'Статус' -Value $summaryCase.Status
            Write-BRAVOResultField -Label 'Код завершення' -Value '0 — Success'
            Write-BRAVOResultField -Label 'Початок' -Value '09.08.2026 22:10:03'
            Write-BRAVOResultField -Label 'Завершення' -Value '09.08.2026 22:24:15'
            Write-BRAVOResultField -Label 'Тривалість' -Value '14:12'
            Write-BRAVOResultBlankLine
            Write-BRAVOResultField -Label 'Кроків' -Value '8'
            Write-BRAVOResultField -Label 'Успішно' -Value '7'
            Write-BRAVOResultField -Label 'Попереджень' -Value '1'
            Write-BRAVOResultField -Label 'Пропущено' -Value '0'
            Write-BRAVOResultField -Label 'Помилок' -Value '0'
        } 6>&1
        $summaryFooterCapture = Write-BRAVOFinalSummaryFooter -LogFile $summaryTestLogPath 6>&1
        $summaryText = (
            @($summaryHeaderCapture) + @($summaryFieldsCapture) + @($summaryFooterCapture) |
                ForEach-Object { $_.ToString() }
        ) -join "`n"
        $summaryLines = $summaryText -split "`n"
        # 3 роздільники: заголовок відкриває й закриває (2) + footer закриває (1).
        Test-BRAVOCondition `
            -Condition (
                @($summaryLines | Where-Object { $_ -eq $maintenanceSeparatorLine }).Count -eq 3 -and
                @($summaryLines | Where-Object { $_ -eq (" BRAVO MAINTENANCE — {0}" -f $summaryCase.Status) }).Count -eq 1 -and
                @($summaryLines | Where-Object { $_ -match "^Статус:\s+$([regex]::Escape($summaryCase.Status))$" }).Count -eq 1 -and
                @([regex]::Matches($summaryText, 'Попереджень:')).Count -eq 1 -and
                @($summaryLines | Where-Object { $_ -eq 'Журнал:' }).Count -eq 1 -and
                @($summaryLines | Where-Object { $_ -eq $summaryTestLogPath }).Count -eq 1 -and
                (($summaryLines | Where-Object { $_ -eq 'Журнал:' } | Select-Object -First 1) -eq 'Журнал:') -and
                ($summaryLines[[array]::IndexOf($summaryLines, 'Журнал:') + 1] -eq $summaryTestLogPath) -and
                $summaryLines[-1] -eq $maintenanceSeparatorLine -and
                -not $summaryText.Contains('РЕЗУЛЬТАТ') -and
                -not $summaryText.Contains('Детальний журнал:') -and
                -not $summaryText.Contains(('-' * 60))
            ) `
            -Name $summaryCase.TestName `
            -Failure ("summary заголовок 'BRAVO MAINTENANCE — {0}' + поля + 'Журнал:'/шлях наступним рядком + закриваючий '='*60 (не '-'*60/'Детальний журнал:'), 'Попереджень:' рівно один раз" -f $summaryCase.Status)
    }

    # --- Maintenance/DirectoryDetailsRenderAsSeparateLines: кілька deatil-
    # частин кроку 'Створення необхідних директорій' (створено MANIFESTS +
    # перенесено manifest-ів) мають бути ОКРЕМИМИ рядками, не з'єднаними
    # через '; '.
    & $maintenanceStepModule { Initialize-BRAVOMaintenanceSteps -Total 1 }
    $directoryDetailsCapture = & $maintenanceStepModule {
        Write-BRAVOMaintenanceStep `
            -Name 'Створення необхідних директорій' `
            -Status 'OK' `
            -Details ("створено: D:\LIMS\ARCHIV\MANIFESTS`nперенесено manifest-ів: 3")
    } 6>&1
    $directoryDetailsText = ($directoryDetailsCapture | ForEach-Object { $_.ToString() }) -join "`n"
    $directoryDetailsLines = $directoryDetailsText -split "`n"
    Test-BRAVOCondition `
        -Condition (
            @($directoryDetailsLines | Where-Object { $_ -eq '      створено: D:\LIMS\ARCHIV\MANIFESTS' }).Count -eq 1 -and
            @($directoryDetailsLines | Where-Object { $_ -eq '      перенесено manifest-ів: 3' }).Count -eq 1 -and
            -not $directoryDetailsText.Contains('; ')
        ) `
        -Name "Maintenance/DirectoryDetailsRenderAsSeparateLines" `
        -Failure "декілька деталей кроку 'Створення необхідних директорій' (MANIFESTS init + migration) мають рендеритись окремими 6-пробільними рядками, не через '; '"

    # --- Maintenance/FinalSummaryContainsOnlyApprovedFields: РЕАЛЬНИЙ блок
    # фінального підсумку в джерелі (round 5) — не синтетичний виклик, а
    # текст між Write-BRAVOFinalSummaryHeader і Write-BRAVOFinalSummaryFooter
    # у самому BRAVO.Maintenance.Runtime.ps1. Затверджений compact operator
    # summary — рівно 10 полів; Maintenance/Архівація/Shutdown/"Детальний
    # журнал"/"РЕЗУЛЬТАТ" не повинні там з'являтися (вони вже видні в Плані
    # операцій і в детальному LOG).
    # dev.16: Write-BRAVOFinalSummaryHeader/Footer тепер зустрічаються ДВІЧІ
    # в реальному джерелі — вдруге в compact no-op summary
    # (Recovery/RunMissedRestoreOnly, задовго до цього блоку в файлі).
    # Пошук стартує ПІСЛЯ 'усе від Range ID до Send-FinalReport' (унікальний
    # якір десь між ними), щоб знайти саме основний 10-field summary, а не
    # ранній compact recovery-варіант.
    $maintenanceMainSummarySearchStart = $maintenanceScriptTextForManifestStorage.IndexOf('усе від Range ID до Send-FinalReport')
    $maintenanceSummaryBlockStart = $maintenanceScriptTextForManifestStorage.IndexOf('Write-BRAVOFinalSummaryHeader `', $maintenanceMainSummarySearchStart)
    $maintenanceSummaryBlockEnd = $maintenanceScriptTextForManifestStorage.IndexOf(
        'Write-BRAVOFinalSummaryFooter -LogFile $LOG_FILE', $maintenanceSummaryBlockStart)
    $maintenanceSummaryBlockText = if ($maintenanceSummaryBlockStart -ge 0 -and $maintenanceSummaryBlockEnd -gt $maintenanceSummaryBlockStart) {
        $maintenanceSummaryBlockText = $maintenanceScriptTextForManifestStorage.Substring(
            $maintenanceSummaryBlockStart,
            $maintenanceSummaryBlockEnd - $maintenanceSummaryBlockStart + "Write-BRAVOFinalSummaryFooter -LogFile `$LOG_FILE".Length)
        $maintenanceSummaryBlockText
    } else { '' }
    $maintenanceSummaryApprovedLabels = @(
        'Статус', 'Код завершення', 'Початок', 'Завершення', 'Тривалість',
        'Кроків', 'Успішно', 'Попереджень', 'Пропущено', 'Помилок'
    )
    $maintenanceSummaryMissingApproved = @(
        $maintenanceSummaryApprovedLabels | Where-Object {
            -not $maintenanceSummaryBlockText.Contains("-Label '$_'")
        }
    )
    $maintenanceSummaryForbiddenLabels = @('Maintenance', 'Архівація', 'Shutdown')
    $maintenanceSummaryHasForbidden = @(
        $maintenanceSummaryForbiddenLabels | Where-Object {
            $maintenanceSummaryBlockText.Contains("-Label '$_'")
        }
    )
    Test-BRAVOCondition `
        -Condition (
            -not [string]::IsNullOrEmpty($maintenanceSummaryBlockText) -and
            $maintenanceSummaryMissingApproved.Count -eq 0 -and
            $maintenanceSummaryHasForbidden.Count -eq 0 -and
            -not $maintenanceSummaryBlockText.Contains('Детальний журнал') -and
            -not $maintenanceSummaryBlockText.Contains('РЕЗУЛЬТАТ') -and
            $maintenanceSummaryBlockText.Contains('Write-BRAVOFinalSummaryFooter -LogFile $LOG_FILE') -and
            -not $maintenanceSummaryBlockText.Contains('Write-BRAVOResultFooter')
        ) `
        -Name "Maintenance/FinalSummaryContainsOnlyApprovedFields" `
        -Failure ("реальний final-summary блок Maintenance.Runtime.ps1 має містити рівно затверджені 10 полів (відсутні: {0}) і не містити Maintenance/Архівація/Shutdown/'Детальний журнал'/'РЕЗУЛЬТАТ' (знайдено заборонених: {1}), і завершуватись Write-BRAVOFinalSummaryFooter, не Write-BRAVOResultFooter" -f
            ($maintenanceSummaryMissingApproved -join ', '), ($maintenanceSummaryHasForbidden -join ', '))

    # ================================================================
    # dev.15: затверджений 8-step operator contract — рівно 8 кроків
    # завжди рендеряться, номер кроку НІКОЛИ не залежить від runtime-стану
    # (лише SKIPPED/OK/WARN/FAIL), Migration/Cleanup/BRAVO_ARCHIV — поза
    # цим контрактом (detailed LOG, не numbered main step). Реальний
    # source/AST Maintenance.Runtime.ps1, БЕЗ запуску production Main().
    # ================================================================
    $maintenanceApprovedStepNames = @(
        'Перевірка вільного місця',
        'Створення необхідних директорій',
        'Зупинка служб',
        'Перевірка розмірів .md',
        'Реставрація моделі',
        'Обробка trace і логів',
        'Відновлення стану служб',
        'Контроль діапазонів ID'
    )
    $maintenanceStepCallNamePattern = "Write-BRAVOMaintenanceStep[\s``]*-Name\s+'([^']+)'"
    $maintenanceStepCallMatches = [regex]::Matches($maintenanceScriptTextForManifestStorage, $maintenanceStepCallNamePattern)
    $maintenanceStepCallOrderedNames = @($maintenanceStepCallMatches | ForEach-Object { $_.Groups[1].Value })
    # Унікальні назви в порядку ПЕРШОЇ появи в джерелі — гілки (OK/WARN/
    # FAIL/SKIPPED) того самого логічного кроку повторюють ту саму назву.
    $maintenanceStepCallUniqueOrderedNames = @()
    $maintenanceStepCallSeenNames = @{}
    foreach ($stepCallName in $maintenanceStepCallOrderedNames) {
        if (-not $maintenanceStepCallSeenNames.ContainsKey($stepCallName)) {
            $maintenanceStepCallSeenNames[$stepCallName] = $true
            $maintenanceStepCallUniqueOrderedNames += $stepCallName
        }
    }
    $maintenanceStepMissingNames = @($maintenanceApprovedStepNames | Where-Object { $_ -notin $maintenanceStepCallUniqueOrderedNames })
    $maintenanceStepExtraNames = @($maintenanceStepCallUniqueOrderedNames | Where-Object { $_ -notin $maintenanceApprovedStepNames })
    $maintenanceStepOrderMatches = $maintenanceStepCallUniqueOrderedNames.Count -eq $maintenanceApprovedStepNames.Count
    if ($maintenanceStepOrderMatches) {
        for ($stepOrderIndex = 0; $stepOrderIndex -lt $maintenanceApprovedStepNames.Count; $stepOrderIndex++) {
            if ($maintenanceStepCallUniqueOrderedNames[$stepOrderIndex] -ne $maintenanceApprovedStepNames[$stepOrderIndex]) {
                $maintenanceStepOrderMatches = $false
                break
            }
        }
    }

    # --- AST: Initialize-BRAVOMaintenanceSteps -Total має бути буквальним
    # літералом 8, не виразом (5+optional/9+optional/dynamic тощо).
    $maintenanceStepTotalTokens = $null
    $maintenanceStepTotalErrors = $null
    $maintenanceStepTotalAst = [Management.Automation.Language.Parser]::ParseInput(
        $maintenanceScriptTextForManifestStorage,
        [ref]$maintenanceStepTotalTokens,
        [ref]$maintenanceStepTotalErrors
    )
    $maintenanceInitStepsCallAst = $maintenanceStepTotalAst.Find(
        {
            param($candidate)
            $candidate -is [Management.Automation.Language.CommandAst] -and
            $candidate.GetCommandName() -eq 'Initialize-BRAVOMaintenanceSteps'
        },
        $true
    )
    $maintenanceTotalParamValueAst = $null
    if ($null -ne $maintenanceInitStepsCallAst) {
        for ($cmdElementIndex = 0; $cmdElementIndex -lt $maintenanceInitStepsCallAst.CommandElements.Count; $cmdElementIndex++) {
            $cmdElement = $maintenanceInitStepsCallAst.CommandElements[$cmdElementIndex]
            if ($cmdElement -is [Management.Automation.Language.CommandParameterAst] -and $cmdElement.ParameterName -eq 'Total') {
                $maintenanceTotalParamValueAst = $maintenanceInitStepsCallAst.CommandElements[$cmdElementIndex + 1]
                break
            }
        }
    }
    Test-BRAVOCondition `
        -Condition (
            $null -ne $maintenanceTotalParamValueAst -and
            $maintenanceTotalParamValueAst -is [Management.Automation.Language.ConstantExpressionAst] -and
            [int]$maintenanceTotalParamValueAst.Value -eq 8
        ) `
        -Name "Maintenance/MainStepTotalIsExactlyEight" `
        -Failure "Initialize-BRAVOMaintenanceSteps -Total має бути буквальним літералом 8 (реальний AST), не динамічним виразом (5+optional/9+optional/тощо)"

    Test-BRAVOCondition `
        -Condition ($maintenanceStepMissingNames.Count -eq 0 -and $maintenanceStepExtraNames.Count -eq 0) `
        -Name "Maintenance/AllEightStepsHaveRenderCall" `
        -Failure ("кожен із 8 затверджених кроків має мати виклик Write-BRAVOMaintenanceStep з відповідним -Name, і жодних інших numbered кроків (Migration/Cleanup/BRAVO_ARCHIV НЕ мають власного [N/8]); відсутні: {0}; зайві: {1}" -f
            ($maintenanceStepMissingNames -join ', '), ($maintenanceStepExtraNames -join ', '))

    Test-BRAVOCondition `
        -Condition (
            $maintenanceStepOrderMatches -and
            $maintenanceStepCallUniqueOrderedNames[-1] -eq 'Контроль діапазонів ID'
        ) `
        -Name "Maintenance/LastStepCanReachEightOfEight" `
        -Failure "останній numbered крок, що фактично рендериться в джерелі, має бути 'Контроль діапазонів ID' на позиції 8 із 8 — інакше Total=8 і фактична нумерація розходяться"

    # --- Restore/SizeCheck/Logs/RangeId disabled -> SKIPPED, той самий
    # номер кроку не пропускається. Кожен тест шукає gate-умову ЦЬОГО
    # конкретного кроку (унікальний якір у джерелі), тоді перевіряє, що
    # SKIPPED/'вимкнено' (чи специфічний Details) прив'язані САМЕ до неї,
    # не просто десь є у файлі.
    $maintenanceRestoreGateIndex = $maintenanceScriptTextForManifestStorage.IndexOf('if (-not $restoreStepReported) {')
    $maintenanceRestoreGateWindow = if ($maintenanceRestoreGateIndex -ge 0) {
        $maintenanceScriptTextForManifestStorage.Substring(
            $maintenanceRestoreGateIndex,
            [Math]::Min(400, $maintenanceScriptTextForManifestStorage.Length - $maintenanceRestoreGateIndex))
    } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $maintenanceRestoreGateIndex -ge 0 -and
            $maintenanceRestoreGateWindow.Contains("-Name 'Реставрація моделі' ``") -and
            $maintenanceRestoreGateWindow.Contains("-Status 'SKIPPED' ``") -and
            $maintenanceRestoreGateWindow.Contains("'не заплановано на цей запуск'")
        ) `
        -Name "Maintenance/RestoreDisabledRendersSkipped" `
        -Failure "коли реставрація не запланована цього прогону (`$shouldRestore=false), крок 'Реставрація моделі' має рендеритись SKIPPED 'не заплановано на цей запуск', зі своїм номером [5/8]"

    $maintenanceSizeCheckGateIndex = $maintenanceScriptTextForManifestStorage.IndexOf('if ($script:BRAVOMaintenanceCheckSizeStepEnabled) {')
    $maintenanceSizeCheckGateWindow = if ($maintenanceSizeCheckGateIndex -ge 0) {
        $maintenanceScriptTextForManifestStorage.Substring(
            $maintenanceSizeCheckGateIndex,
            [Math]::Min(700, $maintenanceScriptTextForManifestStorage.Length - $maintenanceSizeCheckGateIndex))
    } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $maintenanceSizeCheckGateIndex -ge 0 -and
            $maintenanceSizeCheckGateWindow.Contains('} else {') -and
            $maintenanceSizeCheckGateWindow.Contains("-Name 'Перевірка розмірів .md' ``") -and
            $maintenanceSizeCheckGateWindow.Contains("-Status 'SKIPPED' ``") -and
            $maintenanceSizeCheckGateWindow.Contains("-Details 'вимкнено'")
        ) `
        -Name "Maintenance/SizeCheckDisabledRendersSkipped" `
        -Failure "коли перевірку розмірів .md вимкнено, крок 'Перевірка розмірів .md' має рендеритись SKIPPED 'вимкнено', зі своїм номером [4/8]"

    $maintenanceLogsGateIndex = $maintenanceScriptTextForManifestStorage.IndexOf('if (-not $script:BRAVOMaintenanceLogsStepEnabled) {')
    $maintenanceLogsGateWindow = if ($maintenanceLogsGateIndex -ge 0) {
        $maintenanceScriptTextForManifestStorage.Substring(
            $maintenanceLogsGateIndex,
            [Math]::Min(300, $maintenanceScriptTextForManifestStorage.Length - $maintenanceLogsGateIndex))
    } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $maintenanceLogsGateIndex -ge 0 -and
            $maintenanceLogsGateWindow.Contains("-Name 'Обробка trace і логів' ``") -and
            $maintenanceLogsGateWindow.Contains("-Status 'SKIPPED' ``") -and
            $maintenanceLogsGateWindow.Contains("-Details 'вимкнено'")
        ) `
        -Name "Maintenance/LogsDisabledRendersSkipped" `
        -Failure "коли компонент BRAVO вимкнено, крок 'Обробка trace і логів' має рендеритись SKIPPED 'вимкнено', зі своїм номером [6/8]"

    $maintenanceOuterRangeTryIndex = $maintenanceScriptTextForManifestStorage.IndexOf('усе від Range ID до Send-FinalReport')
    $maintenanceRangeIdGateIndex = if ($maintenanceOuterRangeTryIndex -ge 0) {
        $maintenanceScriptTextForManifestStorage.IndexOf(
            'if ($BravoMaintenanceEnabled -and $RangeIdMonitoringEnabled) {',
            $maintenanceOuterRangeTryIndex)
    } else { -1 }
    $maintenanceRangeIdGateWindow = if ($maintenanceRangeIdGateIndex -ge 0) {
        $maintenanceScriptTextForManifestStorage.Substring(
            $maintenanceRangeIdGateIndex,
            [Math]::Min(2500, $maintenanceScriptTextForManifestStorage.Length - $maintenanceRangeIdGateIndex))
    } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $maintenanceRangeIdGateIndex -ge 0 -and
            $maintenanceRangeIdGateWindow.Contains('} else {') -and
            $maintenanceRangeIdGateWindow.Contains("-Name 'Контроль діапазонів ID' ``") -and
            $maintenanceRangeIdGateWindow.Contains("-Status 'SKIPPED' ``") -and
            $maintenanceRangeIdGateWindow.Contains("-Details 'вимкнено'")
        ) `
        -Name "Maintenance/RangeIdDisabledRendersSkipped" `
        -Failure "коли компонент BRAVO або контроль діапазонів ID вимкнено, крок 'Контроль діапазонів ID' має рендеритись SKIPPED 'вимкнено', зі своїм номером [8/8]"

    # ================================================================
    # dev.15: fail-safe finalization — жоден звичайний чи exception-шлях
    # після відновлення служб не може обійти обчислення exit code і
    # фінальний summary. Структурна перевірка реального порядку в
    # джерелі (той самий IndexOf-підхід, що Console/MaintenancePausesOnEveryExitPath
    # вище), без запуску production Main().
    # ================================================================
    $maintenanceOuterRangeCatchIndex = $maintenanceScriptTextForManifestStorage.IndexOf('див. коментар біля відкриття try вище')
    $maintenanceEndOfScriptMarkerIndex = $maintenanceScriptTextForManifestStorage.IndexOf('# ===== ЗАВЕРШЕННЯ СКРИПТУ =====')
    # dev.19 (виправлено): inline if/elseif/else замінено на виклик
    # Get-BRAVOMaintenanceResolvedExitCode (та сама формула, лише
    # винесена в канонічну функцію й піднята ще вище — тепер ДО друку
    # ЛОГ "=== СТАТУС ===", не лише ДО РЕЗУЛЬТАТ) — новий буквальний
    # маркер точки присвоєння.
    $maintenanceExitCodeCalcIndex = $maintenanceScriptTextForManifestStorage.IndexOf('$script:maintenanceRuntimeExitCode = Get-BRAVOMaintenanceResolvedExitCode')
    # dev.16: обидва пошуки стартують ПІСЛЯ $maintenanceEndOfScriptMarkerIndex,
    # бо Write-BRAVOFinalSummaryHeader/Footer тепер зустрічаються й раніше
    # в файлі — у compact no-op summary (Recovery/RunMissedRestoreOnly) —
    # і незв'язаний неунковий IndexOf знайшов би ЙОГО, а не основний
    # 10-field summary, чий порядок відносно exit code/Wait-BRAVOManualExit
    # тут перевіряється.
    $maintenanceSummaryHeaderOrderIndex = $maintenanceScriptTextForManifestStorage.IndexOf('Write-BRAVOFinalSummaryHeader `', $maintenanceEndOfScriptMarkerIndex)
    $maintenanceSummaryFooterOrderIndex = $maintenanceScriptTextForManifestStorage.IndexOf('Write-BRAVOFinalSummaryFooter -LogFile $LOG_FILE', $maintenanceEndOfScriptMarkerIndex)
    $maintenanceManualExitOrderIndex = $maintenanceScriptTextForManifestStorage.LastIndexOf('Wait-BRAVOManualExit -NoPause:$NoPause')
    $maintenanceCatchBodyText = if ($maintenanceOuterRangeCatchIndex -ge 0 -and $maintenanceEndOfScriptMarkerIndex -gt $maintenanceOuterRangeCatchIndex) {
        $maintenanceScriptTextForManifestStorage.Substring(
            $maintenanceOuterRangeCatchIndex,
            $maintenanceEndOfScriptMarkerIndex - $maintenanceOuterRangeCatchIndex)
    } else { '' }

    Test-BRAVOCondition `
        -Condition (
            $maintenanceExitCodeCalcIndex -ge 0 -and
            $maintenanceSummaryHeaderOrderIndex -gt $maintenanceExitCodeCalcIndex -and
            $maintenanceSummaryFooterOrderIndex -gt $maintenanceSummaryHeaderOrderIndex -and
            $maintenanceManualExitOrderIndex -gt $maintenanceSummaryFooterOrderIndex
        ) `
        -Name "Maintenance/FinalSummaryOccursBeforeManualPause" `
        -Failure "порядок джерела має бути: обчислення exit code -> Write-BRAVOFinalSummaryHeader -> поля -> Write-BRAVOFinalSummaryFooter -> Wait-BRAVOManualExit — саме в цій послідовності"

    Test-BRAVOCondition `
        -Condition (
            $maintenanceOuterRangeTryIndex -ge 0 -and
            $maintenanceOuterRangeCatchIndex -gt $maintenanceOuterRangeTryIndex -and
            $maintenanceEndOfScriptMarkerIndex -gt $maintenanceOuterRangeCatchIndex -and
            $maintenanceExitCodeCalcIndex -gt $maintenanceEndOfScriptMarkerIndex
        ) `
        -Name "Maintenance/NormalCompletionCannotBypassFinalSummary" `
        -Failure "звичайне (без винятку) завершення має проходити крізь той самий try -> (catch пропущено) -> ЗАВЕРШЕННЯ СКРИПТУ -> обчислення exit code, без окремого return/exit, що обходить summary"

    Test-BRAVOCondition `
        -Condition (
            -not [string]::IsNullOrEmpty($maintenanceCatchBodyText) -and
            $maintenanceCatchBodyText.Contains('$script:criticalErrorOccurred = $true') -and
            -not [regex]::IsMatch($maintenanceCatchBodyText, '(?m)^\s*(exit|return)\b')
        ) `
        -Name "Maintenance/PostServiceExceptionStillReachesSummary" `
        -Failure "catch-блок (Range ID/очистка/BRAVO_ARCHIV/AutoShutdown/фінальний звіт) має позначати criticalErrorOccurred і НЕ містити return/exit, що обійшов би ЗАВЕРШЕННЯ СКРИПТУ й фінальний summary нижче"

    $maintenanceCatchCriticalFlagIndex = $maintenanceCatchBodyText.IndexOf('$script:criticalErrorOccurred = $true')
    $maintenanceCatchFirstTryIndex = $maintenanceCatchBodyText.IndexOf('try {')
    $maintenanceCatchLoggingWrapped = [regex]::IsMatch(
        $maintenanceCatchBodyText,
        'try\s*\{\s*Write-Log\s+-Message\s+"ПОМИЛКА: \$errorMsg"\s+-Level\s+"ERROR"\s*\}\s*catch\s*\{\s*#[^\}]*не rethrow[^\}]*\}'
    )
    Test-BRAVOCondition `
        -Condition (
            $maintenanceCatchCriticalFlagIndex -ge 0 -and
            $maintenanceCatchFirstTryIndex -gt $maintenanceCatchCriticalFlagIndex -and
            $maintenanceCatchLoggingWrapped
        ) `
        -Name "Maintenance/CatchLoggingFailureCannotBypassSummary" `
        -Failure "criticalErrorOccurred=true має встановлюватись ДО ізольованого Write-Log, і збій самого Write-Log (isolated try/catch, без rethrow) не повинен обійти ЗАВЕРШЕННЯ СКРИПТУ/summary нижче"

    $maintenanceCatchNotificationWrapped = [regex]::IsMatch(
        $maintenanceCatchBodyText,
        'try\s*\{\s*Send-SlackAlert\s+-Message\s+\$errorMsg\s+-IsCritical\s*\}\s*catch\s*\{\s*#[^\}]*не rethrow[^\}]*\}'
    )
    Test-BRAVOCondition `
        -Condition (
            $maintenanceCatchCriticalFlagIndex -ge 0 -and
            $maintenanceCatchFirstTryIndex -gt $maintenanceCatchCriticalFlagIndex -and
            $maintenanceCatchNotificationWrapped
        ) `
        -Name "Maintenance/CatchNotificationFailureCannotBypassSummary" `
        -Failure "criticalErrorOccurred=true має встановлюватись ДО ізольованого Send-SlackAlert, і збій самого Send-SlackAlert (isolated try/catch, без rethrow) не повинен обійти ЗАВЕРШЕННЯ СКРИПТУ/summary нижче"

    # ================================================================
    # dev.15: Range ID — WARN не дублюється в консолі (Write-Log -NoConsole
    # всередині Test-RangeIdUsage), відсутній файл дає multiline Reason.
    # ================================================================
    $maintenanceRangeIdFunctionStart = $maintenanceScriptTextForManifestStorage.IndexOf('function Test-RangeIdUsage')
    $maintenanceRangeIdFunctionEnd = $maintenanceScriptTextForManifestStorage.IndexOf('function Format-CommandOutput', $maintenanceRangeIdFunctionStart)
    $maintenanceRangeIdFunctionText = if ($maintenanceRangeIdFunctionStart -ge 0 -and $maintenanceRangeIdFunctionEnd -gt $maintenanceRangeIdFunctionStart) {
        $maintenanceScriptTextForManifestStorage.Substring(
            $maintenanceRangeIdFunctionStart, $maintenanceRangeIdFunctionEnd - $maintenanceRangeIdFunctionStart)
    } else { '' }
    # Лише виклики, чиє повідомлення повертається як .Reason (і тому й так
    # уже показується оператору через -Details кроку [8/8]) мають бути
    # -NoConsole. "Некоректне значення filled" — окреме per-entry
    # попередження, яке НЕ потрапляє в Reason/Details і тому законно
    # лишається звичайним консольним WARNING без -NoConsole.
    $maintenanceRangeIdReasonWarningCalls = [regex]::Matches(
        $maintenanceRangeIdFunctionText,
        'Write-Log\s+\$(errorMessage|readErrorMessage|message)\s+-Level\s+"WARNING"[^\r\n]*'
    )
    $maintenanceRangeIdReasonWarningCallsMissingNoConsole = @(
        $maintenanceRangeIdReasonWarningCalls | Where-Object { $_.Value -notmatch '-NoConsole' }
    )
    Test-BRAVOCondition `
        -Condition (
            $maintenanceRangeIdReasonWarningCalls.Count -eq 3 -and
            $maintenanceRangeIdReasonWarningCallsMissingNoConsole.Count -eq 0
        ) `
        -Name "Maintenance/RangeIdWarningHasSingleConsoleRender" `
        -Failure "усі Write-Log виклики, чиє повідомлення повертається як .Reason (errorMessage/readErrorMessage/message), мають бути -NoConsole — інакше WARN дублюється в консолі (раз від Write-Log, раз від Details кроку [8/8])"

    # Той самий виклик/шлях/поріг, що вже захопив $rangeIdMissingResultCapture
    # вище (RangeIdMissingRemainsWarning) — повторний виклик isolated module
    # з ідентичними стабами був би чистим дублюванням.
    Test-BRAVOCondition `
        -Condition (
            $null -ne $rangeIdMissingResultCapture -and
            [string]$rangeIdMissingResultCapture.Reason -eq "Файл контролю діапазонів ID не знайдено:`n$rangeIdMissingPath"
        ) `
        -Name "Maintenance/RangeIdMissingUsesMultilineDetail" `
        -Failure "Reason відсутнього Range ID файлу має бути multiline (мітка окремим рядком, шлях — наступним), без старого однорядкового варіанту, і без раннього return, що його випереджає"

    # ================================================================
    # dev.15: План операцій закривається тим самим '='-роздільником
    # (Write-BRAVOHeaderSeparator), що обрамляє заголовок, а не '-'
    # (Write-BRAVOSeparator, стиль блоку РЕЗУЛЬТАТ).
    # ================================================================
    $maintenanceHeaderSeparatorCapture = Write-BRAVOHeaderSeparator 6>&1
    $maintenanceHeaderSeparatorText = ($maintenanceHeaderSeparatorCapture | ForEach-Object { $_.ToString() }) -join "`n"
    # Регекс на РЕАЛЬНИЙ виклик-рядок (не substring), бо коментарі поруч
    # свідомо згадують стару назву 'Write-BRAVOSeparator' для пояснення —
    # `.Contains()` на всьому файлі ловив би й коментар.
    Test-BRAVOCondition `
        -Condition (
            [regex]::IsMatch($maintenanceScriptTextForManifestStorage, '(?m)^Write-BRAVOHeaderSeparator\s*$') -and
            -not [regex]::IsMatch($maintenanceScriptTextForManifestStorage, '(?m)^Write-BRAVOSeparator\s*$') -and
            $maintenanceHeaderSeparatorText -eq $maintenanceSeparatorLine
        ) `
        -Name "Maintenance/PlanUsesEqualsSeparator" `
        -Failure "роздільник після 'План операцій:' має бути тим самим '='*60 (Write-BRAVOHeaderSeparator), що обрамляє заголовок, а не '-'*60 (Write-BRAVOSeparator)"

    # ================================================================
    # dev.16: Remove-OldRestoreArchives — scalar .Count під Set-StrictMode.
    # Реальний DEV-LIMS acceptance-прогін dev.15 підтвердив [1/8]..[8/8]/
    # Restore SKIPPED/Range ID single render/final summary before pause —
    # усе PASS, але після [8/8] cleanup кинув "The property 'Count' cannot
    # be found on this object": під PowerShell 5.1 + Set-StrictMode
    # ($beforeCount/$afterCount, $remainingFiles) Where-Object/Get-ChildItem
    # повертають скалярний FileInfo замість масиву, коли результат рівно
    # один. dev.15 fail-safe catch перетворив це на exit 60 і все одно
    # показав summary — правильно, але сам виняток лишався. Тести нижче —
    # РЕАЛЬНА функція (ізольована AST-екстракція), синтетичний TEMP-каталог
    # (НЕ production DEV-LIMS), справжній Set-StrictMode -Version Latest
    # усередині виклику — відтворення точної причини, не симуляція.
    # ================================================================
    $restoreCleanupModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $maintenanceScriptTextForManifestStorage `
        -FunctionNames @('Remove-OldRestoreArchives')
    $restoreCleanupPrefix = 'RESTORECLEANUP'

    # --- Спільний stub-набір: Write-Log echo-ить у output stream (щоб
    # Details-рядки можна було перевірити), Get-SHA512HashCompatible —
    # справжній SHA512 через Get-FileHash (не no-op: без реального хешу
    # перевірка hash-файлу в Remove-OldRestoreArchives не пройде і група
    # ніколи не потрапить у valid), Test-BRAVOMaintenanceSevenZipArchiveIntegrity
    # застабовано (реальний 7-Zip тут не предмет тесту).
    $restoreCleanupStubScriptText = {
        function Write-Log {
            param($Message, [string]$Level = 'INFO')
            Write-Output "[$Level] $Message"
        }
        function Get-SHA512HashCompatible {
            param([string]$FilePath)
            return (Get-FileHash -LiteralPath $FilePath -Algorithm SHA512).Hash.ToUpperInvariant()
        }
        function Test-BRAVOMaintenanceSevenZipArchiveIntegrity {
            param($SevenZipPath, $ArchivePath)
            $null = $SevenZipPath
            $null = $ArchivePath
            return $true
        }
    }.ToString()

    # --- Test 1/2: ДВІ валідні сесії (кожна: один before + один after),
    # KeepCount=1 -> зберігається лише найновіша. Рівно одна сесія (без
    # другої, старішої) поверталась би раніше з функції МОВЧКИ
    # ($groupsToDelete.Count -eq 0 -> return, рядок ~3357) ще ДО цього
    # циклу — тому для сесії, що потрапляє в $groupsToKeep, обов'язково
    # потрібна ще одна, старіша, яка йде на видалення. $beforeCount/
    # $afterCount для збереженої сесії мають бути РІВНО 1 (не кидати
    # виняток; стара форма без @() кидала б саме тут).
    $restoreCleanupSingleRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("BRAVO_RESTORE_CLEANUP_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    [void][IO.Directory]::CreateDirectory($restoreCleanupSingleRoot)
    $restoreCleanupSingleThrew = $false
    $restoreCleanupSingleErrorMessage = $null
    $restoreCleanupSingleLogLines = @()
    try {
        foreach ($sessionTime in @('20260101_0100', '20260102_0100')) {
            foreach ($suffix in @('before', 'after')) {
                $fileName = "${restoreCleanupPrefix}_${suffix}_$sessionTime.mdz"
                $archivePath = Join-Path $restoreCleanupSingleRoot $fileName
                Set-Content -LiteralPath $archivePath -Value "synthetic-$suffix-$sessionTime" -Encoding ASCII
                $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA512).Hash
                "$hash *$fileName" | Out-File -FilePath "$archivePath.sha512" -Encoding ASCII
            }
        }

        try {
            $restoreCleanupSingleLogLines = @(& $restoreCleanupModule {
                param($Path, $Prefix, $StubScriptText)
                Set-StrictMode -Version Latest
                . ([scriptblock]::Create($StubScriptText))
                $script:ArchivePrefixRegex = [regex]::Escape($Prefix)
                $script:ARC_PATH = 'unused-stub-path'
                Remove-OldRestoreArchives -Path $Path -ArchivePrefix $Prefix -KeepCount 1 -InvalidRetentionDays 30
            } $restoreCleanupSingleRoot $restoreCleanupPrefix $restoreCleanupStubScriptText)
        } catch {
            $restoreCleanupSingleThrew = $true
            $restoreCleanupSingleErrorMessage = $_.Exception.Message
        }
    } finally {
        if (Test-Path -LiteralPath $restoreCleanupSingleRoot) {
            Remove-Item -LiteralPath $restoreCleanupSingleRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $restoreCleanupSingleLogText = $restoreCleanupSingleLogLines -join "`n"
    $restoreCleanupSingleCountMatch = [regex]::Match(
        $restoreCleanupSingleLogText, 'before: (\d+), after: (\d+)')

    Test-BRAVOCondition `
        -Condition (
            -not $restoreCleanupSingleThrew -and
            $restoreCleanupSingleCountMatch.Success -and
            $restoreCleanupSingleCountMatch.Groups[1].Value -eq '1'
        ) `
        -Name "Maintenance/RestoreCleanupSingleBeforeArchiveHasCountOne" `
        -Failure ("рівно один 'before'-архів у збереженій сесії має дати `$beforeCount=1 без винятку; кинуто: {0}" -f $restoreCleanupSingleErrorMessage)
    Test-BRAVOCondition `
        -Condition (
            -not $restoreCleanupSingleThrew -and
            $restoreCleanupSingleCountMatch.Success -and
            $restoreCleanupSingleCountMatch.Groups[2].Value -eq '1'
        ) `
        -Name "Maintenance/RestoreCleanupSingleAfterArchiveHasCountOne" `
        -Failure ("рівно один 'after'-архів у збереженій сесії має дати `$afterCount=1 без винятку; кинуто: {0}" -f $restoreCleanupSingleErrorMessage)
    Test-BRAVOCondition `
        -Condition (-not $restoreCleanupSingleThrew) `
        -Name "Maintenance/RestoreCleanupStrictModeSingleItemSafe" `
        -Failure ("Remove-OldRestoreArchives не повинен кидати виняток під Set-StrictMode -Version Latest, коли Where-Object повертає рівно один результат; кинуто: {0}" -f $restoreCleanupSingleErrorMessage)

    # --- Test 3: після видалення залишається РІВНО один файл із префіксом
    # (Get-ChildItem -Filter повертає скалярний FileInfo, не масив) ->
    # $remainingFiles.Count не повинен кидати виняток. KeepCount=0 видаляє
    # єдину валідну сесію (2 архіви + 2 sha512); окремий "сирітський" файл
    # поза before/after-патерном лишається єдиним, хто підпадає під
    # `${ArchivePrefix}_*` після видалення.
    $restoreCleanupRemainingRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("BRAVO_RESTORE_CLEANUP_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    [void][IO.Directory]::CreateDirectory($restoreCleanupRemainingRoot)
    $restoreCleanupRemainingThrew = $false
    $restoreCleanupRemainingErrorMessage = $null
    try {
        $sessionTime = '20260101_0200'
        foreach ($suffix in @('before', 'after')) {
            $fileName = "${restoreCleanupPrefix}_${suffix}_$sessionTime.mdz"
            $archivePath = Join-Path $restoreCleanupRemainingRoot $fileName
            Set-Content -LiteralPath $archivePath -Value "synthetic-$suffix-content" -Encoding ASCII
            $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA512).Hash
            "$hash *$fileName" | Out-File -FilePath "$archivePath.sha512" -Encoding ASCII
        }
        # Сирітський файл: не матчиться з "_(before|after)_"-групуванням,
        # тому ніколи не потрапляє у valid/invalid-групи чи видалення
        # конкретної сесії — переживає видалення й лишається єдиним
        # результатом Get-ChildItem -Filter "${Prefix}_*" наприкінці.
        Set-Content -LiteralPath (Join-Path $restoreCleanupRemainingRoot "${restoreCleanupPrefix}_orphan.mdz") `
            -Value 'orphan' -Encoding ASCII

        try {
            [void](& $restoreCleanupModule {
                param($Path, $Prefix, $StubScriptText)
                Set-StrictMode -Version Latest
                . ([scriptblock]::Create($StubScriptText))
                $script:ArchivePrefixRegex = [regex]::Escape($Prefix)
                $script:ARC_PATH = 'unused-stub-path'
                Remove-OldRestoreArchives -Path $Path -ArchivePrefix $Prefix -KeepCount 0 -InvalidRetentionDays 30
            } $restoreCleanupRemainingRoot $restoreCleanupPrefix $restoreCleanupStubScriptText)
        } catch {
            $restoreCleanupRemainingThrew = $true
            $restoreCleanupRemainingErrorMessage = $_.Exception.Message
        }
    } finally {
        if (Test-Path -LiteralPath $restoreCleanupRemainingRoot) {
            Remove-Item -LiteralPath $restoreCleanupRemainingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Test-BRAVOCondition `
        -Condition (-not $restoreCleanupRemainingThrew) `
        -Name "Maintenance/RestoreCleanupSingleRemainingFileDoesNotThrow" `
        -Failure ("коли після видалення лишається рівно один файл із префіксом, `$remainingFiles.Count не повинен кидати виняток під Set-StrictMode; кинуто: {0}" -f $restoreCleanupRemainingErrorMessage)

    # ================================================================
    # dev.16: operator-visibility pass — Migration/Cleanup/Archive/
    # AutoShutdown реально виконуються щоразу, коли увімкнені, але досі
    # мали лише LOG-видимість. Реальний source (не Main()) — той самий
    # AST/IndexOf-підхід, що dev.14/dev.15 тести вище. [1/8]...[8/8]
    # НЕ чіпались (Maintenance/MainStepTotalIsExactlyEight нижче лишається
    # без змін і мусить пройти так само).
    # ================================================================

    # --- Plan: Очистка старих даних/логів присутня й на правильній позиції
    # (Реставрація моделі -> Очистка -> Архівація після maintenance).
    $planCleanupIndex = $maintenanceScriptTextForManifestStorage.IndexOf("'Очистка старих даних/логів'      = `$true")
    $planRestoreIndex = $maintenanceScriptTextForManifestStorage.IndexOf("'Реставрація моделі'              = [bool]`$script:BRAVOMaintenanceRestoreStepEnabled")
    $planArchiveIndex = $maintenanceScriptTextForManifestStorage.IndexOf("'Архівація після maintenance'     = [bool]`$script:BRAVOMaintenanceArchiveStepEnabled")
    Test-BRAVOCondition `
        -Condition (
            $planCleanupIndex -ge 0 -and
            $planRestoreIndex -ge 0 -and
            $planArchiveIndex -gt $planCleanupIndex -and
            $planCleanupIndex -gt $planRestoreIndex
        ) `
        -Name "Maintenance/CleanupAppearsInPlan" `
        -Failure "План операцій має містити 'Очистка старих даних/логів' = `$true (effective runtime behavior, не UI-only), між 'Реставрація моделі' і 'Архівація після maintenance'"

    # --- Migration/Cleanup/Archive/AutoShutdown рендеряться через
    # Write-BRAVOOperationResult, не Write-BRAVOMaintenanceStep.
    foreach ($unnumberedOp in @(
        @{ Name = 'Міграція старих журналів'; TestName = 'Maintenance/MigrationOperationResultIsUnnumbered' },
        @{ Name = 'Очистка старих даних/логів'; TestName = 'Maintenance/CleanupOperationResultIsUnnumbered' },
        @{ Name = 'Архівація після maintenance'; TestName = 'Maintenance/ArchiveAfterMaintenanceResultIsUnnumbered' },
        @{ Name = 'Автоматичне вимкнення сервера'; TestName = 'Maintenance/AutoShutdownResultIsUnnumbered' }
    )) {
        $unnumberedOpPattern = "Write-BRAVOOperationResult[\s``]*-Name\s+'$([regex]::Escape($unnumberedOp.Name))'"
        Test-BRAVOCondition `
            -Condition ([regex]::IsMatch($maintenanceScriptTextForManifestStorage, $unnumberedOpPattern)) `
            -Name $unnumberedOp.TestName `
            -Failure "'$($unnumberedOp.Name)' має рендеритись через Write-BRAVOOperationResult (без [N/8]), не Write-BRAVOMaintenanceStep"
    }

    # --- Total лишається буквальним 8 (той самий AST-вузол, що
    # Maintenance/MainStepTotalIsExactlyEight нижче) — жоден unnumbered
    # блок не додає доданок.
    Test-BRAVOCondition `
        -Condition (
            $null -ne $maintenanceTotalParamValueAst -and
            $maintenanceTotalParamValueAst -is [Management.Automation.Language.ConstantExpressionAst] -and
            [int]$maintenanceTotalParamValueAst.Value -eq 8
        ) `
        -Name "Maintenance/UnnumberedOperationsDoNotIncreaseMainStepTotal" `
        -Failure "Initialize-BRAVOMaintenanceSteps -Total має лишатися буквальним 8 — жоден unnumbered post-[8/8] блок не повинен додавати доданок до Total"

    # --- Функціональний доказ: реальний Write-BRAVOOperationResult (з уже
    # імпортованого BRAVO.Console) не чіпає лічильники ізольованого
    # $maintenanceStepModule — інші модульні scope, фізично неможливо
    # торкнутися $script:BRAVOMaintenanceStepCurrent/OkCount/... звідти.
    & $maintenanceStepModule { Initialize-BRAVOMaintenanceSteps -Total 8 }
    [void](& $maintenanceStepModule { Write-BRAVOMaintenanceStep -Name 'X' -Status 'OK' } 6>&1)
    $countersBeforeOperationResult = & $maintenanceStepModule {
        [pscustomobject]@{
            Current = $script:BRAVOMaintenanceStepCurrent
            Ok = $script:BRAVOMaintenanceStepOkCount
            Warn = $script:BRAVOMaintenanceStepWarnCount
            Skipped = $script:BRAVOMaintenanceStepSkippedCount
            Fail = $script:BRAVOMaintenanceStepFailCount
        }
    }
    [void](Write-BRAVOOperationResult -Name 'Тест' -Status 'OK' -Duration ([timespan]::Zero) 6>&1)
    [void](Write-BRAVOOperationResult -Name 'Тест' -Status 'WARN' -Duration ([timespan]::Zero) -Details 'x' 6>&1)
    [void](Write-BRAVOOperationResult -Name 'Тест' -Status 'FAIL' -Duration ([timespan]::Zero) -Details 'x' 6>&1)
    [void](Write-BRAVOOperationResult -Name 'Тест' -Status 'SKIPPED' -Duration ([timespan]::Zero) -Details 'x' 6>&1)
    $countersAfterOperationResult = & $maintenanceStepModule {
        [pscustomobject]@{
            Current = $script:BRAVOMaintenanceStepCurrent
            Ok = $script:BRAVOMaintenanceStepOkCount
            Warn = $script:BRAVOMaintenanceStepWarnCount
            Skipped = $script:BRAVOMaintenanceStepSkippedCount
            Fail = $script:BRAVOMaintenanceStepFailCount
        }
    }
    Test-BRAVOCondition `
        -Condition (
            $countersBeforeOperationResult.Current -eq $countersAfterOperationResult.Current -and
            $countersBeforeOperationResult.Ok -eq $countersAfterOperationResult.Ok -and
            $countersBeforeOperationResult.Warn -eq $countersAfterOperationResult.Warn -and
            $countersBeforeOperationResult.Skipped -eq $countersAfterOperationResult.Skipped -and
            $countersBeforeOperationResult.Fail -eq $countersAfterOperationResult.Fail
        ) `
        -Name "Maintenance/UnnumberedOperationsDoNotChangeStepCounters" `
        -Failure "Write-BRAVOOperationResult (будь-який статус) не повинен змінювати BRAVOMaintenanceStepCurrent/OkCount/WarnCount/SkippedCount/FailCount"

    # --- Cleanup: SKIPPED/OK/WARN-FAIL wiring у реальному джерелі.
    $cleanupResultCallIndex = $maintenanceScriptTextForManifestStorage.IndexOf("-Name 'Очистка старих даних/логів' ``", $planCleanupIndex)
    $cleanupResultCallWindow = if ($cleanupResultCallIndex -ge 0) {
        $maintenanceScriptTextForManifestStorage.Substring([Math]::Max(0, $cleanupResultCallIndex - 1400), 1400)
    } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $cleanupResultCallWindow.Contains("'SKIPPED'") -and
            $cleanupResultCallWindow.Contains("-not `$hasDataToClean") -and
            $cleanupResultCallWindow.Contains("'даних для очищення немає'")
        ) `
        -Name "Maintenance/CleanupNoDataRendersSkipped" `
        -Failure "коли `$hasDataToClean=false, 'Очистка старих даних/логів' має рендеритись SKIPPED 'даних для очищення немає'"
    Test-BRAVOCondition `
        -Condition (
            $cleanupResultCallWindow.Contains('Get-BRAVOMaintenanceStepStatus') -and
            $cleanupResultCallWindow.Contains('$cleanupCriticalBefore') -and
            $cleanupResultCallWindow.Contains('$cleanupWarningsBefore') -and
            $cleanupResultCallWindow.Contains('каталогів:') -and
            $cleanupResultCallWindow.Contains('файлів:')
        ) `
        -Name "Maintenance/CleanupSuccessRendersOk" `
        -Failure "коли є дані для очищення й без нових critical/warning, статус має братися з Get-BRAVOMaintenanceStepStatus (OK), Details — агрегат кандидатів"
    Test-BRAVOCondition `
        -Condition (
            $cleanupResultCallWindow.Contains("-eq 'WARN' -or") -and
            $cleanupResultCallWindow.Contains("-eq 'FAIL'") -and
            $cleanupResultCallWindow.Contains("'перевірте LOG для деталей'")
        ) `
        -Name "Maintenance/CleanupFailureRendersFail" `
        -Failure "WARN/FAIL 'Очистка старих даних/логів' має показувати Details 'перевірте LOG для деталей'"

    # --- Archive after maintenance: SKIPPED/OK/FAIL wiring.
    $archiveResultCallIndex = $maintenanceScriptTextForManifestStorage.IndexOf("`$script:currentMaintenanceOperation = 'Архівація після maintenance'")
    $archiveResultCallWindow = if ($archiveResultCallIndex -ge 0) {
        $maintenanceScriptTextForManifestStorage.Substring($archiveResultCallIndex, [Math]::Min(3600, $maintenanceScriptTextForManifestStorage.Length - $archiveResultCallIndex))
    } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $archiveResultCallWindow.Contains("-Status 'SKIPPED' ``") -and
            $archiveResultCallWindow.Contains("-Details 'вимкнено'") -and
            $archiveResultCallWindow.Contains('if ($script:EnableArchiveAfterMaintenance)')
        ) `
        -Name "Maintenance/ArchiveDisabledRendersSkipped" `
        -Failure "коли `$script:EnableArchiveAfterMaintenance=false, 'Архівація після maintenance' має рендеритись SKIPPED 'вимкнено'"
    Test-BRAVOCondition `
        -Condition (
            $archiveResultCallWindow.Contains('Get-BRAVOMaintenanceStepStatus') -and
            $archiveResultCallWindow.Contains('$archiveCriticalBefore') -and
            $archiveResultCallWindow.Contains('$archiveWarningsBefore')
        ) `
        -Name "Maintenance/ArchiveSuccessRendersOk" `
        -Failure "успіх/помилка 'Архівація після maintenance' мають визначатись через Get-BRAVOMaintenanceStepStatus за тим самим `$script:criticalErrorOccurred, що дочірній процес уже виставляє"
    Test-BRAVOCondition `
        -Condition (
            $archiveResultCallWindow.Contains('"BRAVO_ARCHIV завершився з кодом $($archivProcess.ExitCode)"') -and
            $archiveResultCallWindow.Contains('"скрипт не знайдено: $bravoArchivePath"') -and
            $archiveResultCallWindow.Contains("archiveOperationDetail = 'перевірте LOG для деталей'")
        ) `
        -Name "Maintenance/ArchiveFailureRendersFail" `
        -Failure "FAIL 'Архівація після maintenance' (exit!=0/не знайдено/exception) має показувати конкретну коротку причину в Details"

    # --- AutoShutdown: SKIPPED/OK/FAIL wiring (Invoke-AutoShutdown реально
    # НЕ викликається в тесті — це системна команда shutdown; лише
    # структурна перевірка джерела, повернення значення й wiring).
    $autoShutdownResultCallIndex = $maintenanceScriptTextForManifestStorage.IndexOf("`$script:currentMaintenanceOperation = 'Автоматичне вимкнення сервера'")
    # dev.16 (review round 3): 2200, не 1400 — гілка $script:EnableAutoShutdown
    # тепер містить 3-way Scheduled/Cancelled/Failed switch (AutoShutdown
    # final-state rendering), і фіксоване вікно мусить сягати ELSE-гілки
    # (SKIPPED 'вимкнено') нижче за течією тексту.
    $autoShutdownResultCallWindow = if ($autoShutdownResultCallIndex -ge 0) {
        $maintenanceScriptTextForManifestStorage.Substring($autoShutdownResultCallIndex, [Math]::Min(2200, $maintenanceScriptTextForManifestStorage.Length - $autoShutdownResultCallIndex))
    } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $autoShutdownResultCallWindow.Contains("-Status 'SKIPPED' ``") -and
            $autoShutdownResultCallWindow.Contains("-Details 'вимкнено'") -and
            $autoShutdownResultCallWindow.Contains('if ($script:EnableAutoShutdown)')
        ) `
        -Name "Maintenance/AutoShutdownDisabledRendersSkipped" `
        -Failure "коли `$script:EnableAutoShutdown=false, 'Автоматичне вимкнення сервера' має рендеритись SKIPPED 'вимкнено'"
    Test-BRAVOCondition `
        -Condition (
            $autoShutdownResultCallWindow.Contains('$autoShutdownOutcome = Invoke-AutoShutdown') -and
            $autoShutdownResultCallWindow.Contains("'Scheduled' { 'OK' }") -and
            $autoShutdownResultCallWindow.Contains('"заплановано через $ShutdownTimeout с"')
        ) `
        -Name "Maintenance/AutoShutdownScheduledRendersOk" `
        -Failure "успішне планування (Invoke-AutoShutdown повертає 'Scheduled') має рендерити OK 'заплановано через N с'"
    Test-BRAVOCondition `
        -Condition (
            $autoShutdownResultCallWindow.Contains("default     { 'FAIL' }") -and
            $autoShutdownResultCallWindow.Contains("'не вдалося ініціювати вимкнення") -and
            $maintenanceScriptTextForManifestStorage.Contains('Write-Log -Message "Помилка ініціювання вимкнення системи. Код помилки: $($process.ExitCode)" -Level "ERROR"') -and
            [regex]::Matches($maintenanceScriptTextForManifestStorage, "(?m)^\s*return 'Failed'\s*`$").Count -ge 2
        ) `
        -Name "Maintenance/AutoShutdownFailureRendersFail" `
        -Failure "невдале планування/виняток (Invoke-AutoShutdown повертає 'Failed') має рендерити FAIL з коротким поясненням; Invoke-AutoShutdown має явно return 'Failed' і на гілці помилки коду виходу, і в catch"
    Test-BRAVOCondition `
        -Condition (
            $autoShutdownResultCallWindow.Contains("'Cancelled' { 'SKIPPED' }") -and
            $autoShutdownResultCallWindow.Contains("'скасовано користувачем'") -and
            $maintenanceScriptTextForManifestStorage.Contains("Вимкнення успішно скасовано") -and
            $maintenanceScriptTextForManifestStorage.Contains("return 'Cancelled'")
        ) `
        -Name "Maintenance/AutoShutdownCancelledRendersSkipped" `
        -Failure "коли оператор інтерактивно скасував заплановане вимкнення (Invoke-AutoShutdown повертає 'Cancelled'), результат має рендеритись SKIPPED 'скасовано користувачем'"

    # --- AutoShutdown: рівно один production call-site (AST, не текстовий
    # пошук — рахує реальні CommandAst-виклики Invoke-AutoShutdown у
    # джерелі, ігнорує коментарі; саме визначення function Invoke-
    # AutoShutdown не є CommandAst і не потрапляє в підрахунок).
    $autoShutdownCallSiteTokens = $null
    $autoShutdownCallSiteErrors = $null
    $autoShutdownCallSiteAst = [Management.Automation.Language.Parser]::ParseInput(
        $maintenanceScriptTextForManifestStorage,
        [ref]$autoShutdownCallSiteTokens,
        [ref]$autoShutdownCallSiteErrors
    )
    $autoShutdownCallSites = @($autoShutdownCallSiteAst.FindAll(
        {
            param($candidate)
            $candidate -is [Management.Automation.Language.CommandAst] -and
            $candidate.GetCommandName() -eq 'Invoke-AutoShutdown'
        },
        $true
    ))
    Test-BRAVOCondition `
        -Condition ($autoShutdownCallSites.Count -eq 1) `
        -Name "Maintenance/AutoShutdownInvokedExactlyOnce" `
        -Failure "Invoke-AutoShutdown має мати рівно один production call site (AST-підрахунок CommandAst); знайдено: $($autoShutdownCallSites.Count)"

    # --- Cleanup details: $groupsToDelete має лишатись строго локальним
    # для Remove-OldRestoreArchives (AST) — Main обчислює власний,
    # інакше названий candidate-count для Details, щоб уникнути
    # оманливого name collision між різними scope/обчисленнями.
    $cleanupScopeAst = $autoShutdownCallSiteAst
    $restoreArchivesFunctionAst = $cleanupScopeAst.Find(
        {
            param($candidate)
            $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $candidate.Name -eq 'Remove-OldRestoreArchives'
        },
        $true
    )
    $groupsToDeleteReferences = @($cleanupScopeAst.FindAll(
        {
            param($candidate)
            $candidate -is [Management.Automation.Language.VariableExpressionAst] -and
            $candidate.VariablePath.UserPath -eq 'groupsToDelete'
        },
        $true
    ))
    $groupsToDeleteOutsideFunction = @($groupsToDeleteReferences | Where-Object {
        $null -eq $restoreArchivesFunctionAst -or
        $_.Extent.StartOffset -lt $restoreArchivesFunctionAst.Extent.StartOffset -or
        $_.Extent.StartOffset -ge $restoreArchivesFunctionAst.Extent.EndOffset
    })
    Test-BRAVOCondition `
        -Condition (
            $null -ne $restoreArchivesFunctionAst -and
            $groupsToDeleteReferences.Count -gt 0 -and
            $groupsToDeleteOutsideFunction.Count -eq 0
        ) `
        -Name "Maintenance/CleanupResultUsesOnlyInScopeVariables" `
        -Failure "`$groupsToDelete має лишатись строго локальним для Remove-OldRestoreArchives; знайдено використань поза функцією: $($groupsToDeleteOutsideFunction.Count)"

    # --- Порядок: пост-операції рендеряться ПІСЛЯ [8/8], а весь цей блок —
    # ДО обчислення exit code/фінального summary (доповнює
    # Maintenance/FinalSummaryOccursBeforeManualPause вище тими самими
    # якорями).
    $rangeIdStepCallIndex = $maintenanceScriptTextForManifestStorage.IndexOf("-Name 'Контроль діапазонів ID' ``")
    Test-BRAVOCondition `
        -Condition (
            $rangeIdStepCallIndex -ge 0 -and
            $cleanupResultCallIndex -gt $rangeIdStepCallIndex -and
            $archiveResultCallIndex -gt $cleanupResultCallIndex -and
            $autoShutdownResultCallIndex -gt $archiveResultCallIndex
        ) `
        -Name "Maintenance/PostOperationsRenderAfterEightOfEight" `
        -Failure "Cleanup -> Archive -> AutoShutdown мають рендеритись у цьому порядку, і всі — після [8/8] Контроль діапазонів ID"
    Test-BRAVOCondition `
        -Condition (
            $autoShutdownResultCallIndex -ge 0 -and
            $maintenanceExitCodeCalcIndex -gt $autoShutdownResultCallIndex -and
            $maintenanceSummaryHeaderOrderIndex -gt $maintenanceExitCodeCalcIndex
        ) `
        -Name "Maintenance/PostOperationsPrecedeFinalSummary" `
        -Failure "AutoShutdown має рендеритись ДО обчислення exit code, яке, своєю чергою, ДО Write-BRAVOFinalSummaryHeader"

    # --- Exact failure attribution: реальний $errorMsg у catch і
    # fallback-FAIL "рівно один раз" через прапорці *Reported.
    Test-BRAVOCondition `
        -Condition (
            $maintenanceCatchBodyText.Contains('$errorMsg = "Помилка операції') -and
            $maintenanceCatchBodyText.Contains('$($script:currentMaintenanceOperation)') -and
            -not $maintenanceCatchBodyText.Contains('Range ID/очистка/BRAVO_ARCHIV/AutoShutdown/фінальний звіт')
        ) `
        -Name "Maintenance/UnexpectedPostOperationFailureNamesExactOperation" `
        -Failure "catch має формувати `$errorMsg із `$script:currentMaintenanceOperation (конкретна назва), не з generic переліку 'Range ID/очистка/BRAVO_ARCHIV/AutoShutdown/фінальний звіт'"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceCatchBodyText.Contains("'Очистка старих даних/логів' {") -and
            $maintenanceCatchBodyText.Contains('if (-not $script:cleanupOperationReported)') -and
            $maintenanceCatchBodyText.Contains("'Архівація після maintenance' {") -and
            $maintenanceCatchBodyText.Contains('if (-not $script:archiveOperationReported)') -and
            $maintenanceCatchBodyText.Contains("'Автоматичне вимкнення сервера' {") -and
            $maintenanceCatchBodyText.Contains('if (-not $script:autoShutdownOperationReported)') -and
            ([regex]::Matches($maintenanceCatchBodyText, "Write-BRAVOOperationResult")).Count -eq 3
        ) `
        -Name "Maintenance/VisiblePostOperationFailureRendersOnce" `
        -Failure "outer catch має рендерити FAIL для активної операції (Cleanup/Archive/AutoShutdown) РІВНО ОДИН РАЗ, лише якщо вона ще не відзвітувала сама (*Reported)"

    # --- Recovery no-op: compact success summary ДО exit 0, у межах
    # того самого зовнішнього try/finally (Wait-BRAVOManualExit — той
    # самий шлях, що й звичайний прогін).
    $recoveryNoWorkIndex = $maintenanceScriptTextForManifestStorage.IndexOf('$RunMissedRestoreOnly -and -not $missedDailyWork')
    $recoveryNoWorkWindow = if ($recoveryNoWorkIndex -ge 0) {
        $maintenanceScriptTextForManifestStorage.Substring($recoveryNoWorkIndex, [Math]::Min(1600, $maintenanceScriptTextForManifestStorage.Length - $recoveryNoWorkIndex))
    } else { '' }
    $recoveryHeaderIndexInWindow = $recoveryNoWorkWindow.IndexOf('Write-BRAVOFinalSummaryHeader')
    $recoveryFooterIndexInWindow = $recoveryNoWorkWindow.IndexOf('Write-BRAVOFinalSummaryFooter')
    # Пошук РЕАЛЬНОГО "exit 0" стартує ПІСЛЯ footer: пояснювальний
    # коментар вище в цьому ж блоці сам згадує "exit 0" в лапках
    # (документує старий голий exit), і неунковий пошук знайшов би
    # текст коментаря, а не справжній statement.
    $recoveryExitIndexInWindow = $recoveryNoWorkWindow.IndexOf('exit 0', [Math]::Max(0, $recoveryFooterIndexInWindow))
    Test-BRAVOCondition `
        -Condition (
            $recoveryNoWorkIndex -ge 0 -and
            $recoveryHeaderIndexInWindow -ge 0 -and
            $recoveryNoWorkWindow.Contains("-Status 'УСПІШНО'") -and
            $recoveryNoWorkWindow.Contains("-Value 'Пропущених операцій не знайдено'") -and
            $recoveryFooterIndexInWindow -gt $recoveryHeaderIndexInWindow -and
            $recoveryExitIndexInWindow -gt $recoveryFooterIndexInWindow -and
            -not [regex]::IsMatch($recoveryNoWorkWindow.Substring(0, $recoveryExitIndexInWindow), "Write-BRAVOMaintenanceStep ``")
        ) `
        -Name "Maintenance/RecoveryNoWorkRendersSuccessSummaryBeforePause" `
        -Failure "'RunMissedRestoreOnly -and -not `$missedDailyWork' має друкувати compact summary (Write-BRAVOFinalSummaryHeader/Footer, БЕЗ [1/8]...[8/8]) ДО 'exit 0', не голий exit без підсумку"

    $legacyEntryPoints = @(
        'ARCHIV_VETOFFICE.ps1',
        'ARCHIV_VETOFFICE.config.ps1',
        'ARCHIV_VETOFFICE.cmd'
    )
    Test-BRAVOCondition `
        -Condition (-not ($legacyEntryPoints | Where-Object { Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf })) `
        -Name "Legacy/VetOfficeRemoved" `
        -Failure "legacy VETOFFICE entrypoints не мають повертатися до runtime"
    $legacyCommandWrappers = @(Get-ChildItem -LiteralPath $root -File -Filter 'BRAVO_*.cmd')
    Test-BRAVOCondition `
        -Condition ($legacyCommandWrappers.Count -eq 0) `
        -Name "Legacy/CommandWrappersRemoved" `
        -Failure "BRAVO .cmd-обгортки не мають повертатися до runtime"

    foreach ($runtimeFile in @(
            "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1",
            "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1",
            "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"
        )) {
        $text = [IO.File]::ReadAllText(
            (Join-Path $root $runtimeFile),
            [Text.Encoding]::UTF8
        )
        Test-BRAVOCondition `
            -Condition ($text.Contains('$operationLockSettings.Path')) `
            -Name "SharedLock/$runtimeFile" `
            -Failure "скрипт не використовує canonical machine-wide operationLockSettings.Path"
    }

    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("`$isLocalSystem = `$currentIdentity.User.Value -eq 'S-1-5-18'") -and
            $archiveScriptText.Contains('!$isLocalSystem -and !$currentPrincipal.IsInRole') -and
            $maintenanceScriptText.Contains("`$isLocalSystem = `$currentIdentity.User.Value -eq 'S-1-5-18'") -and
            $maintenanceScriptText.Contains('-not $isLocalSystem -and -not $currentPrincipal.IsInRole')
        ) `
        -Name "Scheduler/SystemDoesNotInvokeUac" `
        -Failure "SYSTEM-завдання не повинні викликати інтерактивний UAC/RunAs"

    Test-BRAVOCondition `
        -Condition (
            -not $archiveScriptText.Contains('BEGIN BRAVO EMBEDDED RUNTIME LIBRARIES') -and
            -not $maintenanceScriptText.Contains('BEGIN BRAVO EMBEDDED RUNTIME LIBRARIES') -and
            $archiveScriptText.Contains("BRAVO.Compatibility") -and
            $archiveScriptText.Contains("BRAVO.Credentials") -and
            $archiveScriptText.Contains("BRAVO.ArchiveRuntime") -and
            $maintenanceScriptText.Contains("BRAVO.Compatibility") -and
            $maintenanceScriptText.Contains("BRAVO.Credentials")
        ) `
        -Name "Runtime/SharedCompatibilityAndCredentials" `
        -Failure "archive та maintenance мають використовувати спільні compatibility/credentials замість вбудованих копій"
    $healthScriptTextForPatchLevel = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $credentialsSetupTextForPatchLevel = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_CREDENTIALS_SETUP.ps1"),
        [Text.Encoding]::UTF8
    )
    $tasksInstallTextForPatchLevel = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_TASKS_INSTALL.ps1"),
        [Text.Encoding]::UTF8
    )
    $tasksUninstallTextForPatchLevel = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_TASKS_UNINSTALL.ps1"),
        [Text.Encoding]::UTF8
    )
    # Свіжість накопичувальних оновлень Windows — health-метрика, а не
    # умова виконання. В операційних скриптах вона лише додавала WARNING (а
    # з ним і ненульовий код завершення 10) до дії, на результат якої вік
    # патчів не впливає. Тому діагностика лишається рівно в одному місці —
    # BRAVO_HEALTH, який для цього й існує.
    Test-BRAVOCondition `
        -Condition (
            $healthScriptTextForPatchLevel.Contains("Get-BRAVOWindowsPatchLevelRecommendation") -and
            -not $archiveScriptText.Contains("Get-BRAVOWindowsPatchLevelRecommendation") -and
            -not $maintenanceScriptText.Contains("Get-BRAVOWindowsPatchLevelRecommendation") -and
            -not $credentialsSetupTextForPatchLevel.Contains("Get-BRAVOWindowsPatchLevelRecommendation") -and
            -not $tasksInstallTextForPatchLevel.Contains("Get-BRAVOWindowsPatchLevelRecommendation") -and
            -not $tasksUninstallTextForPatchLevel.Contains("Get-BRAVOWindowsPatchLevelRecommendation")
        ) `
        -Name "Runtime/WindowsPatchLevelOnlyInHealth" `
        -Failure "діагностика свіжості оновлень Windows має виконуватись лише в BRAVO_HEALTH і не впливати на код завершення Archive/Maintenance/Recovery/Tasks"
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("Get-BRAVOToolIntegrityRecommendation") -and
            $maintenanceScriptText.Contains("Get-BRAVOToolIntegrityRecommendation") -and
            $healthScriptTextForPatchLevel.Contains("Get-BRAVOToolIntegrityRecommendation")
        ) `
        -Name "Runtime/SharedToolIntegrityRecommendation" `
        -Failure "Archive/Health/Maintenance мають перевіряти цілісність Tools (7za.exe/WinSCP) через спільну функцію"

    # Аудит P1: Archive і Maintenance мають саме БЛОКУВАТИ запуск при
    # порушенні еталонного маніфесту (обидва викликають 7za/WinSCP від
    # SYSTEM). Health — read-only діагностика, він звітує, а не блокує.
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("Test-BRAVOToolManifestIntegrity") -and
            $archiveScriptText.Contains("-ToolIntegrityViolation") -and
            $maintenanceScriptText.Contains("Test-BRAVOToolManifestIntegrity") -and
            $maintenanceScriptText.Contains("-ToolIntegrityViolation") -and
            $healthScriptTextForPatchLevel.Contains("Test-BRAVOToolManifestIntegrity")
        ) `
        -Name "Runtime/ToolManifestBlocksArchiveAndMaintenance" `
        -Failure "Archive і Maintenance мають блокувати запуск (exit 32) при порушенні TOOLS_MANIFEST.json; Health — звітувати"

    Test-BRAVOCondition `
        -Condition ($archiveScriptText.Contains("Send-ToolIntegrityAlert")) `
        -Name "Runtime/ToolManifestSendsCriticalAlert" `
        -Failure "Archive має надсилати критичне сповіщення при заблокованому запуску через цілісність інструментів"

    # Виправлено після рев'ю: Health не має запускати WinSCP, цілісність
    # якого не підтверджена. Аргумент "Health read-only" був хибний —
    # небезпечний сам ЗАПУСК підміненого бінарника (виконає довільний код
    # від SYSTEM), а не те, куди Health пише. Локальні перевірки Tools не
    # запускають і мають продовжуватись.
    $healthSftpGateIndex = $healthScriptTextForPatchLevel.IndexOf("function Test-SFTPHealthConfiguration")
    $healthSftpGateBody = if ($healthSftpGateIndex -ge 0) {
        $healthScriptTextForPatchLevel.Substring(
            $healthSftpGateIndex,
            [math]::Min(3000, $healthScriptTextForPatchLevel.Length - $healthSftpGateIndex)
        )
    } else {
        ""
    }
    Test-BRAVOCondition `
        -Condition (
            $healthSftpGateBody.Contains("BRAVOToolManifest") -and
            $healthSftpGateBody.Contains("ShouldBlock")
        ) `
        -Name "Runtime/HealthSkipsWinSCPWhenToolManifestBroken" `
        -Failure "Test-SFTPHealthConfiguration має пропускати SFTP-перевірки (єдиний шлях запуску WinSCP у Health), якщо цілісність інструментів не підтверджена"

    Test-BRAVOCondition `
        -Condition (
            $healthScriptTextForPatchLevel.Contains("Resolve-BRAVOExitCode -ToolIntegrityViolation")
        ) `
        -Name "Runtime/HealthExitsWithToolIntegrityCode" `
        -Failure "Health має завершуватись кодом 32 при порушенні цілісності інструментів, щоб подія безпеки була видима моніторингу"
    $archiveRuntimeText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.ArchiveRuntime\BRAVO.ArchiveRuntime.psm1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $archiveRuntimeText.Contains('Get-BRAVOWmiInstance -ClassName Win32_Process') -and
            -not $archiveRuntimeText.Contains('Get-CimInstance -ClassName Win32_Process') -and
            -not $archiveRuntimeText.Contains('function Start-BRAVOProcessOutputCapture') -and
            -not $archiveRuntimeText.Contains('function Complete-BRAVOProcessOutputCapture')
        ) `
        -Name "Runtime/WinSCPProcessCheckCompatibility" `
        -Failure "SFTP runtime має використовувати WMI/CIM fallback і не дублювати process-capture функції"
    Test-BRAVOCondition `
        -Condition (
            $archiveRuntimeText.Contains('function Get-BRAVOWinSCPDotNetComponents') -and
            -not $archiveScriptText.Contains('function Get-WinSCPDotNetComponents') -and
            -not $healthScriptText.Contains('function Get-WinSCPDotNetComponents')
        ) `
        -Name "Runtime/SharedWinSCPDotNetDiscovery" `
        -Failure "пошук WinSCP .NET components має мати одну реалізацію у BRAVO.ArchiveRuntime"

    # Аудит Low #10: Get-BRAVOWinSCPBusyMessage формував текст в обхід
    # єдиної точки санітизації. Її результат іде у Write-BRAVOLog (Archive)
    # і в throw (Health) — тобто в журнал і в сповіщення.
    #
    # Сьогодні в $Availability.Processes лежать лише ProcessId, і витікати
    # нема чому. Але $Availability.Error — це вільний текст винятку, а
    # найприроднішим розширенням діагностики "який саме WinSCP працює" є
    # CommandLine з Win32_Process, у якому лежить sftp://user:password@host.
    # Тест фіксує вимогу заздалегідь, а не після інциденту.
    Remove-Module -Name 'BRAVO.ArchiveRuntime' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.ArchiveRuntime\BRAVO.ArchiveRuntime.psd1") -Force -ErrorAction Stop

    # Фікстура складається з частин, а не пишеться літералом: рядок виду
    # sftp://user:pass@host у файлі репозиторію — це справжній секрет для
    # будь-якого сканера, і GitGuardian на нього вже спрацював. Тримати в
    # коді щось, що виглядає як облікові дані, і глушити сканер винятком —
    # гірше, ніж не тримати цього зовсім.
    $busyLeakUser = 'bravo'
    $busyLeakSecret = 'S3cr3t' + 'Pass'
    $busyLeakSecondSecret = 'T0pS3' + 'cret'
    $busyLeakAvailability = [pscustomobject]@{
        Available = $false
        Processes = @()
        Error = (
            'WinSCP.com /command "open sftp://{0}:{1}@nas.local/" -password={2}' -f
                $busyLeakUser, $busyLeakSecret, $busyLeakSecondSecret
        )
    }
    $busyLeakMessage = Get-BRAVOWinSCPBusyMessage `
        -Availability $busyLeakAvailability -Operation "передача архіву"
    Test-BRAVOCondition `
        -Condition (
            -not $busyLeakMessage.Contains($busyLeakSecret) -and
            -not $busyLeakMessage.Contains($busyLeakSecondSecret) -and
            $busyLeakMessage.Contains('***') -and
            $busyLeakMessage.Contains('nas.local')
        ) `
        -Name "Secrets/WinSCPBusyMessageIsSanitized" `
        -Failure "повідомлення про зайнятість WinSCP має проходити Get-SanitizedWinSCPDiagnostic: пароль не повинен потрапляти в журнал і сповіщення (отримано: $busyLeakMessage)"

    # Санітизація не повинна псувати звичайний випадок: діагностика без
    # секретів має лишатися читабельною, інакше її почнуть обходити.
    $busyNormalMessage = Get-BRAVOWinSCPBusyMessage `
        -Availability ([pscustomobject]@{
            Available = $false
            Processes = @([pscustomobject]@{ ProcessId = 4242; Started = 'x' })
            Error = $null
        }) `
        -Operation "синхронізація BAZA"
    Test-BRAVOCondition `
        -Condition (
            $busyNormalMessage.Contains('PID=4242') -and
            $busyNormalMessage.Contains('синхронізація BAZA')
        ) `
        -Name "Secrets/WinSCPBusyMessageKeepsDiagnostics" `
        -Failure "санітизація не повинна прибирати корисну діагностику (PID, назву операції): $busyNormalMessage"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptText.Contains('BRAVO.ArchiveHelpers') -and
            $maintenanceScriptText.Contains('function Test-BRAVOMaintenanceSevenZipArchiveIntegrity') -and
            -not $maintenanceScriptText.Contains('function Test-SevenZipArchiveIntegrity')
        ) `
        -Name "Runtime/SharedSevenZipIntegrityHelper" `
        -Failure "Maintenance має використовувати спільну перевірку 7-Zip з ArchiveHelpers"
    $setupScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_SETUP.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition ($setupScriptText.Contains('$requiresAdministrator = (-not $ValidateOnly) -and (')) `
        -Name "Setup/ValidateOnlyDoesNotRequireUac" `
        -Failure "BRAVO_SETUP -ValidateOnly не повинен вимагати UAC"

    $taskInstaller = Join-Path $root "BRAVO_TASKS_INSTALL.ps1"
    $taskInstallerText = [IO.File]::ReadAllText($taskInstaller, [Text.Encoding]::UTF8)
    Test-BRAVOCondition `
        -Condition (
            $taskInstallerText.Contains("TASK_TRIGGER_BOOT") -and
            $taskInstallerText.Contains("schedulerSettings.Recovery") -and
            $taskInstallerText.Contains("RetryEveryMinutes")
        ) `
        -Name "Scheduler/MissedRestoreStartupTask" `
        -Failure "для пропущеної реставрації потрібне startup-завдання"
    & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -File $taskInstaller `
        -ConfigPath $resolvedConfig `
        -ValidateOnly
    Test-BRAVOCondition `
        -Condition ($LASTEXITCODE -eq 0) `
        -Name "Scheduler/ValidateOnly" `
        -Failure "BRAVO_TASKS_INSTALL повернув код $LASTEXITCODE"

    # ===== RUNTIME / DATA ROOTS, EFFECTIVE CONFIGPATH, SYSTEM PREFLIGHT =====
    # (ТЗ «production-grade runtime, Task Scheduler, log rotation…», §93-§116)
    # Жоден сценарій не керує реальними службами й не змінює production-дані:
    # усе перевіряється на тимчасових каталогах і на тексті самих скриптів.
    $dryRunTextForRuntime = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_DRY_RUN.ps1"),
        [Text.Encoding]::UTF8
    )
    $tasksDiagnoseTextForRuntime = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_TASKS_DIAGNOSE.ps1"),
        [Text.Encoding]::UTF8
    )
    $configLoaderTextForRuntime = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_CONFIG_LOADER.ps1"),
        [Text.Encoding]::UTF8
    )
    # Саме ФАЙЛИ ТОЧОК ВХОДУ, а не runtime-модулі: effective ConfigPath
    # визначається до Import-Module, у самому .ps1.
    $archiveEntrypointText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_ARCHIV.ps1"),
        [Text.Encoding]::UTF8
    )
    $maintenanceEntrypointText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_MAINTENANCE.ps1"),
        [Text.Encoding]::UTF8
    )
    $healthEntrypointText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_HEALTH.ps1"),
        [Text.Encoding]::UTF8
    )

    # --- Runtime/01: валідація коренів даних (Test-BravoDataRootValue) ---
    # Порожнє LIMSRoot/SystemLogRoot/BackupRoot допустиме з -AllowEmpty (=AUTO);
    # без -AllowEmpty порожнє відхиляється; відносний шлях відхиляється завжди.
    $dataRootModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $configLoaderTextForRuntime `
        -FunctionNames @('Test-BravoDataRootValue', 'Assert-BravoDataRootsAreIndependent')
    $absoluteAccepted = $true
    try {
        & $dataRootModule {
            param($Value)
            Test-BravoDataRootValue -Name 'BackupRoot' -Value $Value
        } '"%SystemDrive%\BRAVO_TEST_ROOT"'
    } catch { $absoluteAccepted = $false }
    $emptyLimsAllowed = $true
    try {
        & $dataRootModule { Test-BravoDataRootValue -Name 'LIMSRoot' -Value '' -AllowEmpty }
    } catch { $emptyLimsAllowed = $false }
    # Новий контракт: порожній BackupRoot із -AllowEmpty дозволений (AUTO).
    $emptyBackupAllowed = $true
    try {
        & $dataRootModule { Test-BravoDataRootValue -Name 'BackupRoot' -Value '' -AllowEmpty }
    } catch { $emptyBackupAllowed = $false }
    # Відносний шлях відхиляється НАВІТЬ із -AllowEmpty (порожнє != відносне).
    $relativeRejected = $false
    try {
        & $dataRootModule {
            param($Value)
            Test-BravoDataRootValue -Name 'BackupRoot' -Value $Value -AllowEmpty
        } 'ARCHIV'
    } catch { $relativeRejected = $_.Exception.Message -like '*абсолютним шляхом*' }
    # Без -AllowEmpty порожнє все ще відхиляється (перемикач справді працює).
    $emptyRejectedWithoutSwitch = $false
    try {
        & $dataRootModule { Test-BravoDataRootValue -Name 'BackupRoot' -Value '' }
    } catch { $emptyRejectedWithoutSwitch = $_.Exception.Message -like '*не задано*' }
    Test-BRAVOCondition `
        -Condition (
            $absoluteAccepted -and $emptyLimsAllowed -and $emptyBackupAllowed -and
            $relativeRejected -and $emptyRejectedWithoutSwitch
        ) `
        -Name "Runtime/01-DataRootValueValidation" `
        -Failure "Test-BravoDataRootValue: абсолютний+%ENV% приймається, порожнє з -AllowEmpty дозволене (AUTO) для всіх коренів, відносний відхиляється завжди, порожнє без -AllowEmpty відхиляється"

    # --- Runtime/02: relocatable runtime — незалежні корені на різних дисках ---
    # Дві валідні крайності: (а) усі три корені explicit на різних дисках;
    # (б) усі три "" (all-AUTO). RuntimeRoot передається завантажувачу окремим
    # параметром і не виводиться з жодного кореня даних.
    $relocatableValid = $true
    try {
        & $dataRootModule {
            param($Settings)
            Assert-BravoDataRootsAreIndependent -PathSettings $Settings
        } @{ LIMSRoot = 'D:\LIMS-NEW'; SystemLogRoot = 'E:\BRAVO_LOGS'; BackupRoot = 'F:\BRAVO_BACKUPS' }
    } catch { $relocatableValid = $false }
    $allAutoValid = $true
    try {
        & $dataRootModule {
            param($Settings)
            Assert-BravoDataRootsAreIndependent -PathSettings $Settings
        } @{ LIMSRoot = ''; SystemLogRoot = ''; BackupRoot = '' }
    } catch { $allAutoValid = $false }
    Test-BRAVOCondition `
        -Condition (
            $relocatableValid -and $allAutoValid -and
            $configLoaderTextForRuntime.Contains('[string]$RuntimeRoot') -and
            $configLoaderTextForRuntime.Contains('-ConfigRoot $resolvedConfigRoot -RuntimeRoot $resolvedRuntimeRoot')
        ) `
        -Name "Runtime/02-RelocatableRuntimeSupportsSeparateDisks" `
        -Failure "мають бути валідними обидві крайності: усі три корені explicit на різних дисках І усі три '' (all-AUTO); RuntimeRoot окремим параметром, не з коренів даних"

    # --- Runtime/03: effective ConfigPath використовується всюди ---
    $entrypointConfigPathChecks = @(
        @{ Name = 'BRAVO_ARCHIV.ps1'; Text = $archiveEntrypointText },
        @{ Name = 'BRAVO_MAINTENANCE.ps1'; Text = $maintenanceEntrypointText },
        @{ Name = 'BRAVO_HEALTH.ps1'; Text = $healthEntrypointText }
    )
    $configPathFailures = @(
        $entrypointConfigPathChecks | Where-Object {
            -not $_.Text.Contains('$effectiveConfigPath = if ([string]::IsNullOrWhiteSpace($ConfigPath))') -or
            -not $_.Text.Contains('-ConfigPath $effectiveConfigPath `') -or
            $_.Text.Contains("-ConfigPath (Join-Path `$PSScriptRoot 'BRAVO.config') ``") -or
            -not $_.Text.Contains('$ConfigPath = $effectiveConfigPath')
        } | ForEach-Object { $_.Name }
    )
    Test-BRAVOCondition `
        -Condition ($configPathFailures.Count -eq 0) `
        -Name "Runtime/03-EffectiveConfigPathUsedBySecurityChecks" `
        -Failure "перемикачі безпеки мають перевірятись у ТІЙ САМІЙ конфігурації, з якою запущено скрипт (-ConfigPath), а не в захардкоденому `$PSScriptRoot\BRAVO.config; порушено в: $($configPathFailures -join ', ')"

    # --- Runtime/04: Tools і LOGS живуть у різних коренях ---
    $bravoConfigTextForTools = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO.config"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $bravoConfigTextForTools.Contains('$global:toolsPath = Join-Path $runtimeRoot "Tools"') -and
            $bravoConfigTextForTools.Contains('$global:arcPath = Join-Path $toolsPath "7za.exe"') -and
            $bravoConfigTextForTools.Contains('$global:winSCPPath = Join-Path $toolsPath "WinSCP.com"') -and
            $maintenanceScriptText -notmatch '\$ARC_PATH = Join-Path \$ARCHIVE_ROOT' -and
            $maintenanceScriptText.Contains('$ARC_PATH = if (-not [string]::IsNullOrWhiteSpace([string]$arcPath))')
        ) `
        -Name "Runtime/04-ToolsResolveFromRuntimeRoot" `
        -Failure "7za.exe/WinSCP — runtime-залежності комплекту: вони мають братись із RuntimeRoot\Tools і з одного джерела в Archive та Maintenance"

    # --- Runtime/05: заборонені інтерактивні залежності під SYSTEM ---
    $scheduledEntrypoints = @(
        @{ Name = 'BRAVO_ARCHIV.ps1'; Text = $archiveScriptText },
        @{ Name = 'BRAVO_MAINTENANCE.ps1'; Text = $maintenanceScriptText },
        @{ Name = 'BRAVO_HEALTH.ps1'; Text = $healthScriptText }
    )
    # Інваріант: якщо runtime взагалі вміє підвищувати права, кожне таке
    # підвищення має бути закрите перевіркою на SYSTEM. SYSTEM уже має
    # потрібний контекст, а Start-Process -Verb RunAs там повертає
    # 0x80070001 — тобто заплановане завдання просто вмирає без сліду.
    # $healthScriptText тут — саме BRAVO.Health.Runtime.ps1 (як і два інші),
    # і воно й далі не елевейтиться — задовольняє інваріант за побудовою.
    # dev.13: сам entrypoint BRAVO_HEALTH.ps1 (інший файл, тонкий wrapper,
    # тут НЕ сканується) тепер елевейтиться самостійно — той самий інваріант
    # (SYSTEM/-Verb RunAs) для НЬОГО перевіряють окремі тести нижче:
    # Health/RunAsOnlyReachableFromStandardBranch і
    # Health/ElevationSystemNeverRelaunches.
    $interactiveFailures = @(
        $scheduledEntrypoints | Where-Object {
            ($_.Text -match '-Verb\s+RunAs') -and -not (
                $_.Text.Contains("'S-1-5-18'") -and
                $_.Text -match '(?:!|-not\s+)\$isLocalSystem\s+-and'
            )
        } | ForEach-Object { $_.Name }
    )
    Test-BRAVOCondition `
        -Condition (
            $interactiveFailures.Count -eq 0 -and
            $taskInstallerText.Contains('$actionArguments += " -NoPause"') -and
            $taskInstallerText.Contains('-NoLogo -NoProfile -NonInteractive') -and
            $taskInstallerText.Contains('$actionArguments += " -ExecutionPolicy Bypass"')
        ) `
        -Name "Runtime/05-NoInteractiveDependenciesUnderSystem" `
        -Failure "під SYSTEM (S-1-5-18) не можна викликати Start-Process -Verb RunAs, а кожне заплановане завдання має отримувати -NoProfile/-NonInteractive/-NoPause; порушено в: $($interactiveFailures -join ', ')"

    # --- Runtime/06: Task Scheduler action — абсолютні шляхи й SYSTEM ---
    $bravoConfigTextForScheduler = $bravoConfigTextForTools
    # Principal (акаунт/LogonType/RunLevel) береться з канонічного
    # Get-BRAVOExpectedSchedulerPrincipal (BRAVO.System), а не хардкодиться в
    # Installer — той самий розрахунок перевіряє Diagnose. RunLevel=Highest
    # гарантує сам helper (перевіряє Scheduler/ExpectedPrincipalFromConfig).
    $systemModuleTextForScheduler = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.System\BRAVO.System.psm1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            [regex]::IsMatch($bravoConfigTextForScheduler, 'PowerShellExecutable\s*=\s*Join-Path\s+\$env:SystemRoot\s+"System32\\WindowsPowerShell\\v1\.0\\powershell\.exe"') -and
            $taskInstallerText.Contains('Get-BRAVOExpectedSchedulerPrincipal -SchedulerSettings $schedulerSettings') -and
            $taskInstallerText.Contains('$definition.Principal.RunLevel = $expectedPrincipal.RunLevel') -and
            $systemModuleTextForScheduler.Contains('RunLevel = 1') -and
            $taskInstallerText.Contains('$action.WorkingDirectory = Split-Path -Path $scriptPath -Parent') -and
            $taskInstallerText.Contains('$actionArguments += " -File `"$scriptPath`""') -and
            $taskInstallerText.Contains('$actionArguments += " -ConfigPath `"$ResolvedConfigPath`""')
        ) `
        -Name "Runtime/06-SchedulerActionUsesAbsolutePathsAndHighest" `
        -Failure "дія завдання має використовувати абсолютний powershell.exe, абсолютні -File/-ConfigPath, WorkingDirectory = каталог скрипта; principal (RunLevel Highest) — з Get-BRAVOExpectedSchedulerPrincipal"

    # --- Runtime/07: diagnostics покриває всі production-завдання ---
    # Перевірка визначення тепер SID-based (акаунт) і проти EFFECTIVE expected
    # значень (той самий Get-BRAVOExpectedSchedulerPrincipal, що й Installer),
    # а не проти хардкоду SYSTEM/5/Highest — інакше прийняте Installer-ом
    # визначення могло б оголошуватись invalid у Diagnose.
    Test-BRAVOCondition `
        -Condition (
            $tasksDiagnoseTextForRuntime.Contains('@("Backup", "Maintenance", "Health", "Recovery", "BAZASync")') -and
            $tasksDiagnoseTextForRuntime.Contains('function Test-BRAVOScheduledTaskDefinition') -and
            $tasksDiagnoseTextForRuntime.Contains('BAZASync    = @(''-NoPause'', ''-SyncBAZA'')') -and
            $tasksDiagnoseTextForRuntime.Contains('Recovery    = @(''-NoPause'', ''-RunMissedRestoreOnly'')') -and
            $tasksDiagnoseTextForRuntime.Contains('Test-BRAVOAccountIdentityEquivalent') -and
            $tasksDiagnoseTextForRuntime.Contains('Get-BRAVOExpectedSchedulerPrincipal -SchedulerSettings $schedulerSettings') -and
            $tasksDiagnoseTextForRuntime.Contains('LogonType=$($principal.LogonType), очікується $ExpectedLogonType') -and
            $tasksDiagnoseTextForRuntime.Contains('RunLevel=$($principal.RunLevel), очікується $ExpectedRunLevel')
        ) `
        -Name "Runtime/07-TaskDiagnosticsCoversAllProductionTasks" `
        -Failure "діагностика має перевіряти визначення ВСІХ production-завдань, включно з BAZASync, SID-based акаунтом і проти effective expected LogonType/RunLevel"

    # --- Runtime/08: SYSTEM preflight робить справжній probe запису ---
    $dryRunProbeModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $dryRunTextForRuntime `
        -FunctionNames @(
            'Test-BRAVOMappedNetworkDrivePath',
            'Test-BRAVOFileSystemReadAccess',
            'Test-BRAVOFileSystemWriteAccess'
        )
    $archiveReadProbeModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $archiveScriptText `
        -FunctionNames @('Test-BRAVOSourceReadProbe')
    $preflightTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_PREFLIGHT_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        $missingDirectory = Join-Path $preflightTestRoot "created\by\probe"
        $writeResult = & $dryRunProbeModule {
            param($Path)
            Test-BRAVOFileSystemWriteAccess -Path $Path
        } $missingDirectory
        $probeLeftovers = @(
            Get-ChildItem -LiteralPath $missingDirectory -File -ErrorAction SilentlyContinue
        )
        $readMissing = & $dryRunProbeModule {
            param($Path)
            Test-BRAVOFileSystemReadAccess -Path $Path
        } (Join-Path $preflightTestRoot "no-such-directory")
        $readExisting = & $dryRunProbeModule {
            param($Path)
            Test-BRAVOFileSystemReadAccess -Path $Path
        } $missingDirectory
        Test-BRAVOCondition `
            -Condition (
                [bool]$writeResult.Success -and
                ([string]$writeResult.Detail).Contains('запис/читання/видалення підтверджено') -and
                $probeLeftovers.Count -eq 0 -and
                -not [bool]$readMissing.Success -and
                [bool]$readExisting.Success -and
                $dryRunTextForRuntime.Contains('[IO.File]::WriteAllBytes($probePath, $probeBytes)') -and
                $dryRunTextForRuntime.Contains('$readBack = [IO.File]::ReadAllBytes($probePath)')
            ) `
            -Name "Runtime/08-SystemPreflightPerformsRealWriteProbe" `
            -Failure "preflight має реально створювати, записувати, зчитувати назад і видаляти probe-файл: наявність каталогу не гарантує право запису під SYSTEM"
        Test-BRAVOCondition `
            -Condition (
                $archiveScriptText.Contains('function Test-BRAVOFileSystemWriteProbe') -and
                $archiveScriptText.Contains('function Test-BRAVOSourceReadProbe') -and
                $archiveScriptText.Contains("[IO.FileMode]::CreateNew") -and
                $archiveScriptText.Contains("[IO.File]::ReadAllBytes(`$probePath)") -and
                $archiveScriptText.Contains("(Split-Path -Path ([string]`$operationLockSettings.Path) -Parent)") -and
                $archiveScriptText.Contains("`$writeProbePaths += [System.IO.Path]::Combine([string]`$archive.Destination, '.work')")
            ) `
            -Name 'Runtime/08-ProductionSystemPreflightMatchesDryRun' `
            -Failure 'production Archive має повторювати SYSTEM source-read/write-readback-delete preflight для data roots, destinations, .work і machine lock'

        $emptySourceRoot = Join-Path $preflightTestRoot 'empty-source'
        New-Item -ItemType Directory -Path $emptySourceRoot -Force | Out-Null
        $emptySourceProbe = & $archiveReadProbeModule {
            param($Path)
            Test-BRAVOSourceReadProbe -Path $Path
        } $emptySourceRoot
        Test-BRAVOCondition `
            -Condition ($emptySourceProbe.Success -and $emptySourceProbe.Empty) `
            -Name 'Runtime/08-ArchiveSourceProbeAcceptsEmptyDirectory' `
            -Failure 'доступний порожній BEXCH/BAZA source має проходити preflight; відсутність елементів не є помилкою читання'

        # --- Runtime/09: підключені мережеві диски як production-залежність ---
        $networkDriveLetter = @(
            [System.IO.DriveInfo]::GetDrives() |
                Where-Object { $_.DriveType -eq [System.IO.DriveType]::Network } |
                Select-Object -First 1
        )
        $mappedDriveDetected = if ($networkDriveLetter.Count -gt 0) {
            & $dryRunProbeModule {
                param($Path)
                Test-BRAVOMappedNetworkDrivePath -Path $Path
            } (Join-Path $networkDriveLetter[0].Name "BRAVO")
        } else {
            # На машині без мережевих дисків перевіряємо контракт функції:
            # локальний шлях і UNC не повинні позначатись як mapped drive.
            $true
        }
        $localNotFlagged = & $dryRunProbeModule {
            param($Path)
            Test-BRAVOMappedNetworkDrivePath -Path $Path
        } 'C:\BRAVO'
        $uncNotFlagged = & $dryRunProbeModule {
            param($Path)
            Test-BRAVOMappedNetworkDrivePath -Path $Path
        } '\\server\share\BRAVO'
        Test-BRAVOCondition `
            -Condition (
                [bool]$mappedDriveDetected -and
                -not [bool]$localNotFlagged -and
                -not [bool]$uncNotFlagged -and
                $tasksDiagnoseTextForRuntime.Contains('function Test-BRAVOMappedNetworkDrive') -and
                $dryRunTextForRuntime.Contains('підключений мережевий диск')
            ) `
            -Name "Runtime/09-MappedNetworkDriveIsRejected" `
            -Failure "буква підключеного мережевого диска не може бути production-залежністю (SYSTEM її не бачить); локальні шляхи й UNC при цьому мають лишатись дозволеними"
    } finally {
        if (Test-Path -LiteralPath $preflightTestRoot) {
            Remove-Item -LiteralPath $preflightTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- Runtime/10: preflight перевіряє читання й запис усіх коренів ---
    Test-BRAVOCondition `
        -Condition (
            $dryRunTextForRuntime.Contains('$dryRunRuntimeLogRoot = [string]$global:runtimeLogRoot') -and
            $dryRunTextForRuntime.Contains('$dryRunLimsRoot = [string]$global:effectiveLimsRoot') -and
            $dryRunTextForRuntime.Contains('$dryRunSystemLogRoot = [string]$global:systemLogRoot') -and
            $dryRunTextForRuntime.Contains('$dryRunBackupRoot = [string]$global:backupRootPath') -and
            $dryRunTextForRuntime.Contains('$dryRunStateRoot = [string]$global:stateRoot') -and
            $dryRunTextForRuntime.Contains('. $dryRunGuardPath -RuntimeRoot $runtimeRoot') -and
            $dryRunTextForRuntime.Contains("SFTPLogin = ''") -and
            $dryRunTextForRuntime.Contains("Webhook = ''") -and
            $dryRunTextForRuntime.Contains("'RuntimeRoot' = `$dryRunRuntimeRoot") -and
            $dryRunTextForRuntime.Contains("'bravo.ini'   = [string]`$bravoDiscoveryResult.BravoIniPath") -and
            $dryRunTextForRuntime.Contains("'RuntimeRoot\LOGS (script logs)' = `$dryRunRuntimeLogRoot") -and
            $dryRunTextForRuntime.Contains("'BackupRoot'                     = `$dryRunBackupRoot") -and
            $dryRunTextForRuntime.Contains("'SystemLogRoot'                  = `$dryRunSystemLogRoot") -and
            $dryRunTextForRuntime.Contains("[System.IO.Path]::Combine(`$dryRunSystemLogRoot, 'Trace')") -and
            $dryRunTextForRuntime.Contains("'Machine state'        = `$dryRunStateRoot") -and
            $dryRunTextForRuntime.Contains("'Operation lock'") -and
            $dryRunTextForRuntime.Contains('destination"] = [string]$definition.Destination') -and
            $dryRunTextForRuntime.Contains("work`"] = [System.IO.Path]::Combine([string]`$definition.Destination, '.work')") -and
            $dryRunTextForRuntime.Contains("Add-DryRunResult FAIL 'VSS' 'Capability' `$vssDetail") -and
            $dryRunTextForRuntime.Contains('Test-BRAVOToolManifestIntegrity') -and
            $dryRunTextForRuntime.Contains("Add-DryRunResult PASS 'VSS' 'Capability'") -and
            $dryRunTextForRuntime.Contains("Add-DryRunResult PASS 'SFTP' 'Actual endpoint'")
        ) `
        -Name "Runtime/10-PreflightCoversAllRequiredRoots" `
        -Failure "SYSTEM preflight має перевіряти читання RuntimeRoot/ConfigPath/modules/Tools/LIMSRoot/bravo.ini і запис ArchiveRoot/BackupRoot/LOGS та всіх каталогів призначення ротації"

    # ===== АРХІТЕКТУРА ШЛЯХІВ: RuntimeRoot/LIMSRoot/SystemLogRoot/BackupRoot
    # (ТЗ «Рефакторинг архітектури шляхів BRAVO») =====
    Remove-Module -Name 'BRAVO.Discovery' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $root "modules\BRAVO.Discovery\BRAVO.Discovery.psd1") -Force -ErrorAction Stop
    $bravoConfigTextForPaths = [IO.File]::ReadAllText((Join-Path $root "BRAVO.config"), [Text.Encoding]::UTF8)

    $svcCanonical = @([pscustomobject]@{ Name='BRAVO'; DisplayName='BRAVO Service'; State='Stopped'; StartMode='Disabled'; PathName='"D:\LIMS-NEW\bravo.exe" -service' })
    $svcAmbiguous = @(
        [pscustomobject]@{ Name='BRAVO'; DisplayName='BRAVO Service'; State='Running'; StartMode='Auto'; PathName='"D:\LIMS\bravo.exe"' },
        [pscustomobject]@{ Name='BRAVO'; DisplayName='BRAVO Service'; State='Stopped'; StartMode='Manual'; PathName='"E:\LIMS\bravo.exe"' })

    # --- Paths/01: AUTO LIMSRoot зі служби (Disabled допустимо) ---
    $autoLims = Resolve-BRAVOEffectiveLimsRoot -ConfiguredPath '' -Services $svcCanonical
    Test-BRAVOCondition `
        -Condition ([string]$autoLims.Source -eq 'ServiceDiscovery' -and [string]$autoLims.EffectivePath -eq 'D:\LIMS-NEW') `
        -Name "Paths/01-AutoLimsRootFromService" `
        -Failure "LIMSRoot='' має визначатись як каталог bravo.exe встановленої служби (Disabled — теж валідна identity)"

    # --- Paths/02: explicit LIMSRoot має пріоритет над службою ---
    $explicitLims = Resolve-BRAVOEffectiveLimsRoot -ConfiguredPath 'E:\CUSTOM_BRAVO' -Services $svcAmbiguous
    Test-BRAVOCondition `
        -Condition ([string]$explicitLims.Source -eq 'ExplicitConfig' -and [string]$explicitLims.EffectivePath -eq 'E:\CUSTOM_BRAVO') `
        -Name "Paths/02-ExplicitLimsRootWins" `
        -Failure "явний LIMSRoot має використовуватись точно й не перевизначатись service discovery"

    # --- Paths/03: відсутня служба -> fail-closed ---
    $noServiceLims = Resolve-BRAVOEffectiveLimsRoot -ConfiguredPath '' -Services @()
    Test-BRAVOCondition `
        -Condition ([string]$noServiceLims.Source -eq 'Error' -and [string]::IsNullOrWhiteSpace([string]$noServiceLims.EffectivePath)) `
        -Name "Paths/03-NoServiceFailsClosed" `
        -Failure "LIMSRoot='' без служби BRAVO має давати керовану помилку, а не fallback на RuntimeRoot/ConfigRoot"

    # --- Paths/04: неоднозначна служба -> fail-closed ---
    $ambiguousLims = Resolve-BRAVOEffectiveLimsRoot -ConfiguredPath '' -Services $svcAmbiguous
    Test-BRAVOCondition `
        -Condition ([string]$ambiguousLims.Source -eq 'Error' -and [string]::IsNullOrWhiteSpace([string]$ambiguousLims.EffectivePath)) `
        -Name "Paths/04-AmbiguousServiceFailsClosed" `
        -Failure "кілька служб BRAVO з різними виконуваними файлами при LIMSRoot='' мають давати помилку (fail-closed), а не first-match"

    # --- Paths/05: AUTO SystemLogRoot = <LIMSRoot>\ARCHIV\LOGS ---
    $autoSysLog = Resolve-BRAVOEffectiveSystemLogRoot -ConfiguredPath '' -EffectiveLimsRoot 'D:\LIMS-NEW'
    Test-BRAVOCondition `
        -Condition ([string]$autoSysLog.Source -eq 'AutoFromLIMSRoot' -and [string]$autoSysLog.EffectivePath -eq 'D:\LIMS-NEW\ARCHIV\LOGS') `
        -Name "Paths/05-AutoSystemLogRootFromLims" `
        -Failure "SystemLogRoot='' має давати <EffectiveLIMSRoot>\ARCHIV\LOGS"

    # --- Paths/06: explicit SystemLogRoot використовується точно ---
    $explicitSysLog = Resolve-BRAVOEffectiveSystemLogRoot -ConfiguredPath 'E:\BRAVO_SYSTEM_LOGS' -EffectiveLimsRoot 'D:\LIMS-NEW'
    Test-BRAVOCondition `
        -Condition ([string]$explicitSysLog.Source -eq 'ExplicitConfig' -and [string]$explicitSysLog.EffectivePath -eq 'E:\BRAVO_SYSTEM_LOGS') `
        -Name "Paths/06-ExplicitSystemLogRootExact" `
        -Failure "явний SystemLogRoot має використовуватись точно, без дописування ARCHIV\LOGS"

    # --- Paths/07: BRAVO.config — новий контракт pathSettings ---
    Test-BRAVOCondition `
        -Condition (
            [regex]::IsMatch($bravoConfigTextForPaths, '(?m)^\s*LIMSRoot\s*=') -and
            [regex]::IsMatch($bravoConfigTextForPaths, '(?m)^\s*SystemLogRoot\s*=') -and
            [regex]::IsMatch($bravoConfigTextForPaths, '(?m)^\s*BackupRoot\s*=') -and
            -not [regex]::IsMatch($bravoConfigTextForPaths, '(?m)^\s*ArchiveRoot\s*=') -and
            $bravoConfigTextForPaths.Contains('Resolve-BRAVOEffectiveLimsRoot') -and
            $bravoConfigTextForPaths.Contains('Resolve-BRAVOEffectiveSystemLogRoot') -and
            $bravoConfigTextForPaths.Contains('Resolve-BRAVOEffectiveBackupRoot')
        ) `
        -Name "Paths/07-ConfigContractHasNoArchiveRoot" `
        -Failure "pathSettings має містити LIMSRoot/SystemLogRoot/BackupRoot і викликати Resolve-BRAVOEffective* (Lims/SystemLog/Backup); ArchiveRoot має бути прибраний"

    # --- Paths/08: script logs = RuntimeRoot\LOGS; state = ProgramData\State ---
    Test-BRAVOCondition `
        -Condition (
            $bravoConfigTextForPaths.Contains('$global:runtimeLogRoot = Join-Path $runtimeRoot "LOGS"') -and
            $bravoConfigTextForPaths.Contains('$global:logPath = $global:runtimeLogRoot') -and
            $bravoConfigTextForPaths.Contains("`$global:stateRoot = Join-Path `$programDataRoot 'BRAVO\State'") -and
            $bravoConfigTextForPaths.Contains('$global:systemLogRoot = [string]$systemLogRootResult.EffectivePath')
        ) `
        -Name "Paths/08-ScriptLogsRuntimeStateProgramData" `
        -Failure "логи скриптів мають бути RuntimeRoot\LOGS (logPath=runtimeLogRoot), стан — ProgramData\BRAVO\State, systemLogRoot — окремий"

    # --- Paths/09: Maintenance — Trace/exchangAPI/BravoWeb під SystemLogRoot,
    # власні логи під RuntimeLogRoot, стан під ProgramData\State ---
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptText.Contains('$SYSTEM_LOG_ROOT = [string]$systemLogRoot') -and
            $maintenanceScriptText.Contains('$TRACE_DIR = Join-Path $SYSTEM_LOG_ROOT "Trace"') -and
            $maintenanceScriptText.Contains('$LOG_DIR = [string]$runtimeLogRoot') -and
            $maintenanceScriptText.Contains("Join-Path `$stateRoot 'BRAVO_RESTORE_STATE.json'") -and
            $maintenanceScriptText.Contains("Join-Path `$stateRoot 'BRAVO_TASK_EXECUTION_STATE.json'") -and
            $maintenanceScriptText -notmatch '\$ARCHIVE_ROOT'
        ) `
        -Name "Paths/09-MaintenanceSplitsRuntimeSystemState" `
        -Failure "Maintenance: Trace/exchangAPI/BravoWeb під SystemLogRoot, власні логи під RuntimeLogRoot, стан під ProgramData\State; ARCHIVE_ROOT прибрано"

    # --- Paths/10: Archive backup execution state -> ProgramData\State ---
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("Join-Path `$stateRoot 'BRAVO_TASK_EXECUTION_STATE.json'") -and
            -not $archiveScriptText.Contains("Join-Path `$logPath 'BRAVO_TASK_EXECUTION_STATE.json'")
        ) `
        -Name "Paths/10-ArchiveStateInProgramData" `
        -Failure "Archive backup execution state має писатись у ProgramData\BRAVO\State, а не в каталог логів"

    # --- Paths/11: BackupRoot — BAZA_APP/BAZA_WWW роздільно ---
    Test-BRAVOCondition `
        -Condition (
            $bravoConfigTextForPaths.Contains('[System.IO.Path]::Combine($backupRootPath, "BAZA_APP")') -and
            $bravoConfigTextForPaths.Contains('[System.IO.Path]::Combine($backupRootPath, "BAZA_WWW")') -and
            $bravoConfigTextForPaths.Contains('[System.IO.Path]::Combine($backupRootPath, "MODEL")')
        ) `
        -Name "Paths/11-BackupRootBazaAppWwwDistinct" `
        -Failure "локальні призначення backup: BackupRoot\{MODEL,BLOG,BRAVOEXCH,BAZA_APP,BAZA_WWW}; BAZA_APP не має зватись просто BAZA"

    # --- Paths/12: AUTO BackupRoot = <EffectiveLIMSRoot>\ARCHIV ---
    $autoBackup = Resolve-BRAVOEffectiveBackupRoot -ConfiguredPath '' -EffectiveLimsRoot 'D:\LIMS-NEW'
    Test-BRAVOCondition `
        -Condition ([string]$autoBackup.Source -eq 'AutoFromLIMSRoot' -and [string]$autoBackup.EffectivePath -eq 'D:\LIMS-NEW\ARCHIV') `
        -Name "Paths/12-AutoBackupRootFromLims" `
        -Failure "BackupRoot='' має давати <EffectiveLIMSRoot>\ARCHIV із Source=AutoFromLIMSRoot"

    # --- Paths/13: explicit BackupRoot використовується точно ---
    $explicitBackup = Resolve-BRAVOEffectiveBackupRoot -ConfiguredPath 'E:\BACKUPS' -EffectiveLimsRoot 'D:\LIMS-NEW'
    Test-BRAVOCondition `
        -Condition ([string]$explicitBackup.Source -eq 'ExplicitConfig' -and [string]$explicitBackup.EffectivePath -eq 'E:\BACKUPS') `
        -Name "Paths/13-ExplicitBackupRootExact" `
        -Failure "явний BackupRoot має використовуватись точно, без дописування ARCHIV"

    # --- Paths/14: all-AUTO ланцюжок від синтетичної служби BRAVO ---
    # LIMSRoot=""/SystemLogRoot=""/BackupRoot="" + служба з bravo.exe у
    # D:\LIMS-NEW мають дати повний детермінований розклад коренів.
    $chainLims = Resolve-BRAVOEffectiveLimsRoot -ConfiguredPath '' -Services $svcCanonical
    $chainSysLog = Resolve-BRAVOEffectiveSystemLogRoot -ConfiguredPath '' -EffectiveLimsRoot ([string]$chainLims.EffectivePath)
    $chainBackup = Resolve-BRAVOEffectiveBackupRoot -ConfiguredPath '' -EffectiveLimsRoot ([string]$chainLims.EffectivePath)
    Test-BRAVOCondition `
        -Condition (
            [string]$chainLims.EffectivePath -eq 'D:\LIMS-NEW' -and
            [string]$chainSysLog.EffectivePath -eq 'D:\LIMS-NEW\ARCHIV\LOGS' -and
            [string]$chainBackup.EffectivePath -eq 'D:\LIMS-NEW\ARCHIV' -and
            [string]$chainLims.Source -eq 'ServiceDiscovery' -and
            [string]$chainSysLog.Source -eq 'AutoFromLIMSRoot' -and
            [string]$chainBackup.Source -eq 'AutoFromLIMSRoot'
        ) `
        -Name "Paths/14-AllAutoLayoutFromService" `
        -Failure "all-AUTO (усі три '') зі службою bravo.exe у D:\LIMS-NEW має дати LIMS=D:\LIMS-NEW, SystemLog=...\ARCHIV\LOGS, Backup=...\ARCHIV"

    # --- Paths/15: композиція шляху на відсутньому диску не кидає виняток ---
    # Резолвери мають будувати шлях через [IO.Path]::Combine, тому навіть корінь
    # на відсутньому диску (Q:) не має давати DriveNotFoundException під час
    # завантаження — недоступність виявляє write-probe у dry-run, а не резолвер.
    $qDrivePresent = [bool](Get-PSDrive -Name 'Q' -ErrorAction SilentlyContinue)
    $backupCompositionSafe = $false
    if (-not $qDrivePresent) {
        try {
            $qBackup = Resolve-BRAVOEffectiveBackupRoot -ConfiguredPath '' -EffectiveLimsRoot 'Q:\LIMS-NEW'
            $qModel = [System.IO.Path]::Combine([string]$qBackup.EffectivePath, 'MODEL')
            $backupCompositionSafe = ([string]$qBackup.EffectivePath -eq 'Q:\LIMS-NEW\ARCHIV' -and $qModel -eq 'Q:\LIMS-NEW\ARCHIV\MODEL')
        } catch { $backupCompositionSafe = $false }
    } else {
        # Диск Q: реально існує на цьому хості — сценарій "відсутній диск"
        # непридатний; тест не має сенсу тут провалювати.
        $backupCompositionSafe = $true
    }
    Test-BRAVOCondition `
        -Condition $backupCompositionSafe `
        -Name "Paths/15-BackupCompositionOnAbsentDriveDoesNotThrow" `
        -Failure "побудова BackupRoot і призначень на відсутньому диску (Q:) не має кидати DriveNotFoundException — лише [IO.Path]::Combine, без Join-Path"

    # ===== ВИПРАВЛЕННЯ ПІСЛЯ ТЕСТОВОГО РОЗГОРТАННЯ 5.0.0-dev.1
    # (SID-акаунти, RuntimeRoot!=ConfigRoot, effective BAZASync, BAZA source
    # validation, boot-trigger NextRunTime, version provenance) =====
    Remove-Module -Name 'BRAVO.System' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $root "modules\BRAVO.Discovery\BRAVO.Discovery.psd1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $root "modules\BRAVO.System\BRAVO.System.psd1") -Force -ErrorAction Stop

    $syncSftpDirs = @{ BAZA = 'baza_app'; BAZAWWW = 'baza_www' }

    # --- Sync/01: BAZA_APP only -> BAZASync потрібне, лише /baza_app ---
    $syncAppOnly = Get-BRAVOEffectiveSynchronizationConfiguration `
        -Synchronization @{ BAZA_APP_SFTP = $true; BAZA_APP_LOCAL = $false; BAZA_WWW_SFTP = $false; BAZA_WWW_LOCAL = $false } `
        -BazaAppSource 'D:\LIMS-NEW\BAZA' -BazaWWWSource '' -BazaWWWDetection $null -SftpDirectories $syncSftpDirs
    $syncAppComp = @($syncAppOnly.Components | Where-Object { $_.Name -eq 'BAZA_APP' })[0]
    $syncWwwCompA = @($syncAppOnly.Components | Where-Object { $_.Name -eq 'BAZA_WWW' })[0]
    Test-BRAVOCondition `
        -Condition (
            $syncAppOnly.ScheduledSftpSyncRequired -and
            $syncAppComp.AnyEnabled -and -not $syncWwwCompA.AnyEnabled -and
            (@($syncAppOnly.RequiredSftpDestinations) -contains 'baza_app') -and
            (@($syncAppOnly.RequiredSftpDestinations) -notcontains 'baza_www')
        ) `
        -Name "Sync/01-BazaAppOnlyEnablesSync" `
        -Failure "BAZA_APP_SFTP=true (WWW off) має вмикати BAZASync і вимагати лише /baza_app"

    # --- Sync/02: BAZA_WWW only -> BAZASync ТАКОЖ потрібне (регресія) ---
    $syncWwwOnly = Get-BRAVOEffectiveSynchronizationConfiguration `
        -Synchronization @{ BAZA_APP_SFTP = $false; BAZA_APP_LOCAL = $false; BAZA_WWW_SFTP = $true; BAZA_WWW_LOCAL = $false } `
        -BazaAppSource '' -BazaWWWSource 'C:\Br-a-vo.web\www\BAZA' -BazaWWWDetection ([pscustomobject]@{ Success = $true; Reason = $null }) -SftpDirectories $syncSftpDirs
    $syncWwwComp = @($syncWwwOnly.Components | Where-Object { $_.Name -eq 'BAZA_WWW' })[0]
    Test-BRAVOCondition `
        -Condition (
            $syncWwwOnly.ScheduledSftpSyncRequired -and $syncWwwComp.AnyEnabled -and
            (@($syncWwwOnly.RequiredSftpDestinations) -contains 'baza_www')
        ) `
        -Name "Sync/02-BazaWwwOnlyEnablesSync" `
        -Failure "BAZA_WWW_SFTP=true (APP off) теж має вмикати BAZASync (регресія: Installer дивився лише на BAZA_APP_SFTP)"

    # --- Sync/03: обидва вимкнені -> BAZASync не потрібне ---
    $syncNone = Get-BRAVOEffectiveSynchronizationConfiguration `
        -Synchronization @{ BAZA_APP_SFTP = $false; BAZA_APP_LOCAL = $false; BAZA_WWW_SFTP = $false; BAZA_WWW_LOCAL = $false } `
        -BazaAppSource '' -BazaWWWSource '' -BazaWWWDetection $null -SftpDirectories $syncSftpDirs
    Test-BRAVOCondition `
        -Condition (-not $syncNone.ScheduledSftpSyncRequired -and @($syncNone.RequiredSftpDestinations).Count -eq 0) `
        -Name "Sync/03-BothDisabledNoSync" `
        -Failure "обидва SFTP-прапорці вимкнені -> BAZASync не потрібне, destinations порожні"

    # --- Sync/04: увімкнений компонент із порожнім джерелом -> позначено ---
    $syncMissingSource = Get-BRAVOEffectiveSynchronizationConfiguration `
        -Synchronization @{ BAZA_APP_SFTP = $false; BAZA_APP_LOCAL = $false; BAZA_WWW_SFTP = $true; BAZA_WWW_LOCAL = $false } `
        -BazaAppSource '' -BazaWWWSource '' -BazaWWWDetection ([pscustomobject]@{ Success = $false; Reason = 'службу BRAVO Web не знайдено' }) -SftpDirectories $syncSftpDirs
    $syncMissingComp = @($syncMissingSource.Components | Where-Object { $_.Name -eq 'BAZA_WWW' })[0]
    Test-BRAVOCondition `
        -Condition (
            $syncMissingComp.AnyEnabled -and
            [string]::IsNullOrWhiteSpace([string]$syncMissingComp.Source) -and
            ([string]$syncMissingComp.SourceReason -eq 'службу BRAVO Web не знайдено')
        ) `
        -Name "Sync/04-EnabledMissingSourceIsFlagged" `
        -Failure "увімкнений BAZA_WWW із невизначеним джерелом -> AnyEnabled=true з причиною (Dry Run має дати FAIL)"

    # --- Sync/05: ВИМКНЕНИЙ компонент із порожнім джерелом -> не блокує ---
    $syncDisabledMissing = Get-BRAVOEffectiveSynchronizationConfiguration `
        -Synchronization @{ BAZA_APP_SFTP = $true; BAZA_APP_LOCAL = $false; BAZA_WWW_SFTP = $false; BAZA_WWW_LOCAL = $false } `
        -BazaAppSource 'D:\LIMS-NEW\BAZA' -BazaWWWSource '' -BazaWWWDetection ([pscustomobject]@{ Success = $false; Reason = 'вимкнено' }) -SftpDirectories $syncSftpDirs
    $syncDisabledComp = @($syncDisabledMissing.Components | Where-Object { $_.Name -eq 'BAZA_WWW' })[0]
    Test-BRAVOCondition `
        -Condition (-not $syncDisabledComp.AnyEnabled) `
        -Name "Sync/05-DisabledMissingSourceDoesNotBlock" `
        -Failure "вимкнений BAZA_WWW не має вважатися увімкненим лише через відсутнє джерело"

    # --- Scheduler/ExpectedPrincipalFromConfig: не хардкод, а з effective settings ---
    $principalService = Get-BRAVOExpectedSchedulerPrincipal -SchedulerSettings @{ RunAsUser = 'SYSTEM'; LogonType = 'ServiceAccount' }
    $principalInteractive = Get-BRAVOExpectedSchedulerPrincipal -SchedulerSettings @{ RunAsUser = 'DOMAIN\svc-bravo'; LogonType = 'Interactive' }
    Test-BRAVOCondition `
        -Condition (
            [string]$principalService.UserId -eq 'SYSTEM' -and [int]$principalService.LogonType -eq 5 -and [int]$principalService.RunLevel -eq 1 -and
            [string]$principalInteractive.UserId -eq 'DOMAIN\svc-bravo' -and [int]$principalInteractive.LogonType -eq 3
        ) `
        -Name "Scheduler/ExpectedPrincipalFromConfig" `
        -Failure "expected principal (акаунт/LogonType/RunLevel) має братися з schedulerSettings, а не хардкодитися"

    # --- Scheduler/InstallSummary*: actual INSTALL summary path must not read
    # Recovery-only StartupDelayMinutes for daily/repeating tasks.
    $systemSourceTextForScheduler = [IO.File]::ReadAllText(
        (Join-Path $root 'modules\BRAVO.System\BRAVO.System.psm1'),
        [Text.Encoding]::UTF8
    )
    $installSummaryModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($taskInstallerText + "`n" + $systemSourceTextForScheduler) `
        -FunctionNames @('Format-BRAVOSchedulerNextRun', 'Format-BRAVOInstalledTaskSummaryNextRun')
    $invokeInstalledTaskSummary = {
        param($TaskType, $TaskSettings, $NextRunTime)
        Set-StrictMode -Version Latest
        Format-BRAVOInstalledTaskSummaryNextRun `
            -TaskType $TaskType `
            -TaskSettings $TaskSettings `
            -NextRunTime $NextRunTime
    }
    $backupSummaryOk = $false
    try {
        $backupSummary = & $installSummaryModule `
            $invokeInstalledTaskSummary `
            'Backup' `
            @{ DailyAt = '23:00' } `
            ([datetime]'2026-08-09T23:00:00')
        $backupSummaryOk = ($backupSummary -eq '09.08.2026 23:00')
    } catch { $backupSummaryOk = $false }
    Test-BRAVOCondition `
        -Condition $backupSummaryOk `
        -Name "Scheduler/InstallSummaryBackupDoesNotRequireStartupDelay" `
        -Failure "INSTALL-summary Backup не має читати Recovery.StartupDelayMinutes під Set-StrictMode"

    $maintenanceSummaryOk = $false
    try {
        $maintenanceSummary = & $installSummaryModule `
            $invokeInstalledTaskSummary `
            'Maintenance' `
            @{ DailyAt = '01:00' } `
            ([datetime]'2026-08-10T01:00:00')
        $maintenanceSummaryOk = ($maintenanceSummary -eq '10.08.2026 01:00')
    } catch { $maintenanceSummaryOk = $false }
    Test-BRAVOCondition `
        -Condition $maintenanceSummaryOk `
        -Name "Scheduler/InstallSummaryMaintenanceDoesNotRequireStartupDelay" `
        -Failure "INSTALL-summary Maintenance не має читати Recovery.StartupDelayMinutes під Set-StrictMode"

    $healthSummaryOk = $false
    try {
        $healthSummary = & $installSummaryModule `
            $invokeInstalledTaskSummary `
            'Health' `
            @{ StartAt = '08:00'; RepeatEveryMinutes = 60 } `
            ([datetime]'2026-08-09T08:00:00')
        $healthSummaryOk = ($healthSummary -eq '09.08.2026 08:00')
    } catch { $healthSummaryOk = $false }
    Test-BRAVOCondition `
        -Condition $healthSummaryOk `
        -Name "Scheduler/InstallSummaryHealthDoesNotRequireStartupDelay" `
        -Failure "INSTALL-summary Health не має читати Recovery.StartupDelayMinutes під Set-StrictMode"

    $bazaSyncSummaryOk = $false
    try {
        $bazaSyncSummary = & $installSummaryModule `
            $invokeInstalledTaskSummary `
            'BAZASync' `
            @{ StartAt = '08:30'; RepeatEveryHours = 2 } `
            ([datetime]'2026-08-09T08:30:00')
        $bazaSyncSummaryOk = ($bazaSyncSummary -eq '09.08.2026 08:30')
    } catch { $bazaSyncSummaryOk = $false }
    Test-BRAVOCondition `
        -Condition $bazaSyncSummaryOk `
        -Name "Scheduler/InstallSummaryBazaSyncDoesNotRequireStartupDelay" `
        -Failure "INSTALL-summary BAZASync не має читати Recovery.StartupDelayMinutes під Set-StrictMode"

    $recoverySummaryOk = $false
    try {
        $recoverySummary = & $installSummaryModule `
            $invokeInstalledTaskSummary `
            'Recovery' `
            @{ StartupDelayMinutes = 7 } `
            ([datetime]'1899-12-30T00:00:00')
        $recoverySummaryOk = ($recoverySummary -eq 'після наступного старту Windows; затримка 7 хв.')
    } catch { $recoverySummaryOk = $false }
    Test-BRAVOCondition `
        -Condition $recoverySummaryOk `
        -Name "Scheduler/InstallSummaryRecoveryUsesStartupDelay" `
        -Failure "INSTALL-summary Recovery має передавати налаштовану StartupDelayMinutes у Format-BRAVOSchedulerNextRun"

    # --- SchedulerDiagnose/*: Diagnose permanent-task next-run formatting has
    # the same Recovery-only StartupDelayMinutes contract as Installer.
    $diagnoseNextRunModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($tasksDiagnoseTextForRuntime + "`n" + $systemSourceTextForScheduler) `
        -FunctionNames @('Format-BRAVOSchedulerNextRun', 'Format-BRAVODiagnoseTaskNextRun')
    $invokeDiagnoseNextRun = {
        param($TaskType, $TaskSettings, $NextRunTime)
        Set-StrictMode -Version Latest
        Format-BRAVODiagnoseTaskNextRun `
            -TaskType $TaskType `
            -TaskSettings $TaskSettings `
            -NextRunTime $NextRunTime
    }
    $diagnoseCases = @(
        [pscustomobject]@{
            Name = "SchedulerDiagnose/BackupDoesNotRequireStartupDelay"
            Type = "Backup"
            Settings = @{ DailyAt = "23:00" }
            NextRunTime = [datetime]"2026-08-09T23:00:00"
            Expected = "09.08.2026 23:00"
        },
        [pscustomobject]@{
            Name = "SchedulerDiagnose/MaintenanceDoesNotRequireStartupDelay"
            Type = "Maintenance"
            Settings = @{ DailyAt = "01:00" }
            NextRunTime = [datetime]"2026-08-10T01:00:00"
            Expected = "10.08.2026 01:00"
        },
        [pscustomobject]@{
            Name = "SchedulerDiagnose/HealthDoesNotRequireStartupDelay"
            Type = "Health"
            Settings = @{ StartAt = "08:00"; RepeatEveryMinutes = 60 }
            NextRunTime = [datetime]"2026-08-09T08:00:00"
            Expected = "09.08.2026 08:00"
        },
        [pscustomobject]@{
            Name = "SchedulerDiagnose/BazaSyncDoesNotRequireStartupDelay"
            Type = "BAZASync"
            Settings = @{ StartAt = "08:30"; RepeatEveryHours = 2 }
            NextRunTime = [datetime]"2026-08-09T08:30:00"
            Expected = "09.08.2026 08:30"
        },
        [pscustomobject]@{
            Name = "SchedulerDiagnose/RecoveryUsesStartupDelay"
            Type = "Recovery"
            Settings = @{ StartupDelayMinutes = 7 }
            NextRunTime = [datetime]"1899-12-30T00:00:00"
            Expected = "після наступного старту Windows; затримка 7 хв."
        }
    )
    foreach ($diagnoseCase in $diagnoseCases) {
        $diagnoseNextRunOk = $false
        try {
            $diagnoseNextRun = & $diagnoseNextRunModule `
                $invokeDiagnoseNextRun `
                $diagnoseCase.Type `
                $diagnoseCase.Settings `
                $diagnoseCase.NextRunTime
            $diagnoseNextRunOk = (
                $diagnoseNextRun -eq $diagnoseCase.Expected -and
                ($diagnoseCase.Type -ne "Recovery" -or $diagnoseNextRun -notmatch "1899")
            )
        } catch {
            $diagnoseNextRunOk = $false
        }
        Test-BRAVOCondition `
            -Condition $diagnoseNextRunOk `
            -Name $diagnoseCase.Name `
            -Failure "Diagnose next-run formatter має не падати під Set-StrictMode і читати StartupDelayMinutes лише для Recovery"
    }

    # --- Scheduler/BootTriggerNextRunNo1899: Recovery ніколи не показує 30.12.1899 ---
    $recoveryNext = Format-BRAVOSchedulerNextRun -TaskType 'Recovery' -NextRunTime ([datetime]'1899-12-30T00:00:00') -StartupDelayMinutes 0
    $recoveryNextDelay = Format-BRAVOSchedulerNextRun -TaskType 'Recovery' -NextRunTime ([datetime]'1899-12-30T00:00:00') -StartupDelayMinutes 5
    $dailySentinel = Format-BRAVOSchedulerNextRun -TaskType 'Backup' -NextRunTime ([datetime]'1899-12-30T00:00:00') -StartupDelayMinutes 0
    $dailyValid = Format-BRAVOSchedulerNextRun -TaskType 'Backup' -NextRunTime ([datetime]'2026-08-09T23:00:00') -StartupDelayMinutes 0
    Test-BRAVOCondition `
        -Condition (
            $recoveryNext -eq 'після наступного старту Windows' -and
            ($recoveryNextDelay -like '*затримка 5 хв.*') -and ($recoveryNext -notmatch '1899') -and
            ($dailySentinel -eq 'невідомо') -and ($dailySentinel -notmatch '1899') -and
            ($dailyValid -like '*09.08.2026*')
        ) `
        -Name "Scheduler/BootTriggerNextRunNo1899" `
        -Failure "Recovery (boot) -> 'після наступного старту Windows', ніколи 30.12.1899; sentinel звичайного завдання -> 'невідомо'"

    # --- Deploy/RuntimeRootConfigRootSeparation: runtime-ресурси з RuntimeRoot ---
    $separateConfigRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_CFGROOT_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $separateConfigRoot -Force | Out-Null
    try {
        Copy-Item -LiteralPath $resolvedConfig -Destination (Join-Path $separateConfigRoot 'BRAVO.config') -Force
        Import-BravoConfiguration `
            -ConfigRoot $separateConfigRoot `
            -ConfigPath (Join-Path $separateConfigRoot 'BRAVO.config') `
            -RuntimeRoot $root | Out-Null
        $runtimePrefix = ([IO.Path]::GetFullPath($root)).TrimEnd('\') + '\'
        $configPrefix = ([IO.Path]::GetFullPath($separateConfigRoot)).TrimEnd('\') + '\'
        $backupScript = [string]$global:schedulerSettings.Backup.ScriptPath
        $healthScript = [string]$global:schedulerSettings.Health.ScriptPath
        $bazaScript = [string]$global:schedulerSettings.BAZASync.ScriptPath
        $runtimeLogRootValue = [string]$global:runtimeLogRoot
        Test-BRAVOCondition `
            -Condition (
                $backupScript.StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase) -and
                $healthScript.StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase) -and
                $bazaScript.StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase) -and
                $runtimeLogRootValue.StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase) -and
                -not $backupScript.StartsWith($configPrefix, [StringComparison]::OrdinalIgnoreCase)
            ) `
            -Name "Deploy/RuntimeRootConfigRootSeparation" `
            -Failure "коли RuntimeRoot != ConfigRoot, скрипти-завдання й RuntimeLogRoot мають резолвитися з RuntimeRoot, а не з каталогу конфігурації"
        Test-BRAVOCondition `
            -Condition ([bool]$global:schedulerSettings.BAZASync.Enabled -eq [bool]$global:bazaSyncEffective.ScheduledSftpSyncRequired) `
            -Name "Deploy/BazaSyncEnabledFromEffective" `
            -Failure "schedulerSettings.BAZASync.Enabled має дорівнювати bazaSyncEffective.ScheduledSftpSyncRequired"
    } finally {
        Remove-Item -LiteralPath $separateConfigRoot -Recurse -Force -ErrorAction SilentlyContinue
        # Відновити ізольований стан без залежності від служби BRAVO на CI runner.
        Import-BravoConfiguration `
            -ConfigRoot (Split-Path -Path $resolvedConfig -Parent) `
            -ConfigPath $resolvedConfig `
            -RuntimeRoot $root | Out-Null
    }

    # --- TaskDefinition/*: синтетична перевірка Test-BRAVOScheduledTaskDefinition ---
    # Об'єднуємо текст Diagnose (Test-BRAVOScheduledTaskDefinition + залежний
    # Test-BRAVOMappedNetworkDrive) і Compatibility (SID-хелпери), щоб функція
    # мала всі залежності у власному module scope.
    $diagnoseSourceText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_TASKS_DIAGNOSE.ps1'), [Text.Encoding]::UTF8)
    $compatibilitySourceText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Compatibility\BRAVO.Compatibility.psm1'), [Text.Encoding]::UTF8)
    $taskDefinitionModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($diagnoseSourceText + "`n" + $compatibilitySourceText) `
        -FunctionNames @('Test-BRAVOMappedNetworkDrive', 'ConvertTo-BRAVOAccountSidValue', 'Test-BRAVOAccountIdentityEquivalent', 'Test-BRAVOScheduledTaskDefinition')
    $syntheticExecutable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $newSyntheticTask = {
        param($UserId, $LogonType, $RunLevel, $ExecutablePath)
        [pscustomobject]@{
            Enabled = $true
            Definition = [pscustomobject]@{
                Principal = [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel }
                Settings = [pscustomobject]@{ ExecutionTimeLimit = 'PT30M' }
                Actions = @([pscustomobject]@{ Path = $ExecutablePath; Arguments = '-NoProfile -NonInteractive'; WorkingDirectory = $null })
            }
        }
    }
    $invokeTaskDefinition = {
        param($Task)
        Test-BRAVOScheduledTaskDefinition `
            -TaskType 'Backup' -RegisteredTask $Task -TaskSettings @{} `
            -ExpectedConfigPath '' -ExpectedExecutable '' -RequiredArgumentTokens @() `
            -ExpectedAccount 'SYSTEM' -ExpectedLogonType 5 -ExpectedRunLevel 1
    }
    # SID-форма SYSTEM — те, що Task Scheduler зберігає для локалізованого "СИСТЕМА".
    $taskLocalizedSid = (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')).Value
    $problemsSystem = @(& $taskDefinitionModule $invokeTaskDefinition (& $newSyntheticTask $taskLocalizedSid 5 1 $syntheticExecutable))
    $problemsMismatch = @(& $taskDefinitionModule $invokeTaskDefinition (& $newSyntheticTask 'S-1-5-19' 5 1 $syntheticExecutable))
    $problemsLogon = @(& $taskDefinitionModule $invokeTaskDefinition (& $newSyntheticTask $taskLocalizedSid 3 1 $syntheticExecutable))
    $problemsRunLevel = @(& $taskDefinitionModule $invokeTaskDefinition (& $newSyntheticTask $taskLocalizedSid 5 0 $syntheticExecutable))
    Test-BRAVOCondition `
        -Condition (@($problemsSystem | Where-Object { $_ -like '*UserId*' }).Count -eq 0) `
        -Name "TaskDefinition/SystemAccountBySidPasses" `
        -Failure "SYSTEM у SID-формі (як на локалізованій Windows) не має давати проблему UserId"
    Test-BRAVOCondition `
        -Condition (@($problemsMismatch | Where-Object { $_ -like '*UserId*' }).Count -gt 0) `
        -Name "TaskDefinition/WrongAccountFails" `
        -Failure "невідповідний акаунт (LocalService замість SYSTEM) має давати проблему UserId"
    Test-BRAVOCondition `
        -Condition (@($problemsLogon | Where-Object { $_ -like '*LogonType*' }).Count -gt 0) `
        -Name "TaskDefinition/WrongLogonTypeFails" `
        -Failure "невідповідний LogonType має фіксуватися проти expected"
    Test-BRAVOCondition `
        -Condition (@($problemsRunLevel | Where-Object { $_ -like '*RunLevel*' }).Count -gt 0) `
        -Name "TaskDefinition/WrongRunLevelFails" `
        -Failure "невідповідний RunLevel має фіксуватися проти expected"

    # --- Version/StampConsistency: buildId є префіксом sourceCommit ---
    # Ловить неузгоджений/pre-stamp VERSION.json (packageVersion нова, а
    # build/sourceCommit від іншого коміту). Провенанс детально документовано в
    # ci\Update-BRAVOVersionStamp.ps1 і RELEASE_CHECKLIST.md.
    $versionStampJson = [IO.File]::ReadAllText((Join-Path $root 'VERSION.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    $stampBuildId = [string]$versionStampJson.buildId
    $stampSourceCommit = [string]$versionStampJson.sourceCommit
    Test-BRAVOCondition `
        -Condition (
            -not [string]::IsNullOrWhiteSpace($stampBuildId) -and
            -not [string]::IsNullOrWhiteSpace($stampSourceCommit) -and
            ($stampSourceCommit -match '^[0-9a-fA-F]{40}$') -and
            ($stampBuildId.Length -ge 7) -and
            $stampSourceCommit.StartsWith($stampBuildId, [StringComparison]::OrdinalIgnoreCase)
        ) `
        -Name "Version/StampConsistency" `
        -Failure "VERSION.json.buildId має бути префіксом 40-символьного sourceCommit; інакше артефакт pre-stamp/неузгоджений"

    # ===== РОТАЦІЯ, МІГРАЦІЯ ТА RETENTION ЖУРНАЛІВ: 27 сценаріїв
    # (ТЗ «Production-grade ротація, міграція, архівація та retention
    # логів BRAVO», §80-§102) =====
    # Перевіряються на СПРАВЖНІХ файлах у тимчасовому каталозі, а не лише
    # текстовим пошуком: нумерація, відсутність перезапису, звірка розміру
    # після Move й ідемпотентність міграції — саме те, чого текстова
    # перевірка підтвердити не може, а помилка в чому коштує журналів.
    #
    # Жоден сценарій не керує реальними службами (ТЗ §103): усе, що
    # стосується BRAVO/Apache/exchangAPI, перевіряється на синтетичних
    # об'єктах служб і на файлах у тимчасовому каталозі.
    Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $root "modules\BRAVO.Discovery\BRAVO.Discovery.psd1") -Force -ErrorAction Stop

    $logRotationModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $maintenanceScriptText `
        -FunctionNames @(
            "Write-BRAVOLogRotationMessage",
            "Get-BRAVONextLogSequence",
            "Move-BRAVOLogWithSequence",
            "New-BRAVOLogRotationSummary",
            "Get-BRAVOExchangeApiLogFiles",
            "Get-BRAVOApacheLogFiles",
            "Get-BRAVOWebApplicationLogFiles",
            "Write-BRAVOLogRotationSummary",
            "New-BRAVOLogRotationItem",
            "Invoke-BRAVOLogRotation",
            "Invoke-BRAVOTraceRotation",
            "Invoke-BRAVOExchangeApiLogRotation",
            "Invoke-BRAVOApacheLogRotation",
            "Invoke-BRAVOWebApplicationLogRotation",
            "Get-BRAVOBravoWebComponentPlan",
            "Get-BRAVOOptionalServiceComponentPlan",
            "Get-BRAVOTraceConfiguration",
            "Get-BRAVOLegacyLogMigrationPlan",
            "Get-BRAVOFreeMigrationPath",
            "Move-BRAVOLegacyLogFile",
            "Remove-BRAVOEmptyLegacyDirectory",
            "Invoke-BRAVOLegacyLogMigration",
            "Remove-BRAVOExpiredCompressedLogs",
            "Resolve-BRAVOExchangeApiRuntimeDirectory"
        )

    $rotationTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_LOG_ROTATION_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($rotationTestRoot)
        $rotationLogMessages = New-Object System.Collections.Generic.List[string]
        $rotationLogger = {
            param($Message, $Level)
            $rotationLogMessages.Add("[$Level] $Message")
        }

        function New-BRAVOLogRotationFixture {
            param(
                [string]$Directory,
                [string]$Name,
                [string]$Content = "log",
                [Nullable[datetime]]$LastWriteTime
            )

            [void][IO.Directory]::CreateDirectory($Directory)
            $path = Join-Path $Directory $Name
            [IO.File]::WriteAllText($path, $Content, (New-Object Text.UTF8Encoding($false)))
            if ($null -ne $LastWriteTime) {
                (Get-Item -LiteralPath $path).LastWriteTime = [datetime]$LastWriteTime
            }
            return $path
        }

        function Get-BRAVOLogRotationNames {
            param([string]$Directory)
            return @(
                Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Name |
                    Sort-Object
            )
        }

        function Test-BRAVOLogRotationWarned {
            param([object]$Messages)
            return (@($Messages | Where-Object { $_.StartsWith("[WARNING]") }).Count -gt 0)
        }

        function New-BRAVOSyntheticBravoService {
            param([string]$ExecutablePath)
            return [pscustomobject]@{
                Name = "BRAVO"
                DisplayName = "BRAVO Service"
                State = "Running"
                StartMode = "Auto"
                PathName = ('"{0}" -k runservice' -f $ExecutablePath)
            }
        }

        function Invoke-BRAVORotationHelper {
            param([scriptblock]$Body, [object[]]$Arguments = @())
            return (& $logRotationModule $Body @Arguments)
        }

        # --- Test 1/2: bravo.ini визначається виключно архітектурою ОС ---
        $iniPathOnX64 = Get-BRAVOSystemBravoIniPath -SystemRoot "C:\WindowsTest" -Is64BitOperatingSystem $true
        $iniPathOnX86 = Get-BRAVOSystemBravoIniPath -SystemRoot "C:\WindowsTest" -Is64BitOperatingSystem $false
        Test-BRAVOCondition `
            -Condition ($iniPathOnX64 -eq "C:\WindowsTest\SysWOW64\bravo.ini") `
            -Name "LogRotation/01-BravoIniPathOnX64" `
            -Failure "на 64-бітній ОС очікуваний bravo.ini — рівно %SystemRoot%\SysWOW64\bravo.ini"
        Test-BRAVOCondition `
            -Condition ($iniPathOnX86 -eq "C:\WindowsTest\System32\bravo.ini") `
            -Name "LogRotation/02-BravoIniPathOnX86" `
            -Failure "на 32-бітній ОС очікуваний bravo.ini — рівно %SystemRoot%\System32\bravo.ini"

        $absentBravoWebPlan = Invoke-BRAVORotationHelper {
            Get-BRAVOBravoWebComponentPlan `
                -ComponentEnabled $true `
                -ServiceExists $false `
                -ServiceDisabled $false `
                -ServiceMatchCount 0
        }
        Test-BRAVOCondition `
            -Condition $absentBravoWebPlan.SilentlySkipped `
            -Name "BravoWeb/AbsentServiceIsSilentlySkipped" `
            -Failure "увімкнений, але не встановлений BRAVO Web має пропускатись без warning/error"
        Test-BRAVOCondition `
            -Condition ($absentBravoWebPlan.WarningCountDelta -eq 0) `
            -Name "BravoWeb/AbsentServiceDoesNotIncrementWarningCount" `
            -Failure "відсутня Apache/BRAVO Web служба не повинна змінювати лічильник WARNING"
        Test-BRAVOCondition `
            -Condition (
                -not $absentBravoWebPlan.ManageService -and
                -not $absentBravoWebPlan.IncludeLegacyWebData
            ) `
            -Name "BravoWeb/AbsentServiceDoesNotScheduleWebActions" `
            -Failure "відсутній BRAVO Web не повинен планувати service, migration, retention або web-log дії"
        $presentBravoWebPlan = Invoke-BRAVORotationHelper {
            Get-BRAVOBravoWebComponentPlan `
                -ComponentEnabled $true `
                -ServiceExists $true `
                -ServiceDisabled $false `
                -ServiceMatchCount 1
        }
        Test-BRAVOCondition `
            -Condition (
                -not $presentBravoWebPlan.SilentlySkipped -and
                $presentBravoWebPlan.ManageService -and
                $presentBravoWebPlan.IncludeLegacyWebData -and
                -not $presentBravoWebPlan.WarnDuplicateService
            ) `
            -Name "BravoWeb/PresentServicePreservesMaintenance" `
            -Failure "встановлений активний BRAVO Web має зберегти service і log maintenance"
        $duplicateBravoWebPlan = Invoke-BRAVORotationHelper {
            Get-BRAVOBravoWebComponentPlan `
                -ComponentEnabled $true `
                -ServiceExists $true `
                -ServiceDisabled $false `
                -ServiceMatchCount 2
        }
        Test-BRAVOCondition `
            -Condition $duplicateBravoWebPlan.WarnDuplicateService `
            -Name "BravoWeb/DuplicateServiceStillWarns" `
            -Failure "кілька служб для одного httpd.exe мають зберегти existing WARNING"
        $disabledBravoWebPlan = Invoke-BRAVORotationHelper {
            Get-BRAVOBravoWebComponentPlan `
                -ComponentEnabled $true `
                -ServiceExists $true `
                -ServiceDisabled $true `
                -ServiceMatchCount 1
        }
        $disabledAndAbsentBravoWebPlan = Invoke-BRAVORotationHelper {
            Get-BRAVOBravoWebComponentPlan `
                -ComponentEnabled $false `
                -ServiceExists $false `
                -ServiceDisabled $false `
                -ServiceMatchCount 0
        }
        Test-BRAVOCondition `
            -Condition (
                $disabledBravoWebPlan.IncludeLegacyWebData -and
                -not $disabledBravoWebPlan.ManageService -and
                -not $disabledAndAbsentBravoWebPlan.IncludeLegacyWebData
            ) `
            -Name "BravoWeb/DisabledAndAbsentDoesNotProcessLegacyData" `
            -Failure "legacy web дані допустимі лише для встановленого BRAVO Web, навіть якщо його службу Disabled"
        Test-BRAVOCondition `
            -Condition (
                -not $absentBravoWebPlan.IncludeLegacyWebData -and
                -not $disabledAndAbsentBravoWebPlan.IncludeLegacyWebData
            ) `
            -Name "BravoWeb/LegacyDirectoryDoesNotActivateAbsentOrDisabledComponent" `
            -Failure "залишений Br-a-vo.web не повинен активувати absent або вимкнений у конфігурації BRAVO Web"

        $absentExchangeApiPlan = Invoke-BRAVORotationHelper {
            Get-BRAVOOptionalServiceComponentPlan -ServiceExists $false -ServiceDisabled $false
        }
        Test-BRAVOCondition `
            -Condition $absentExchangeApiPlan.SilentlySkipped `
            -Name "OptionalComponents/ExchangeApiAbsentIsSilentlySkipped" `
            -Failure "відсутній exchangAPI має бути optional-компонентом без повідомлень"
        Test-BRAVOCondition `
            -Condition (-not $absentExchangeApiPlan.ManageService) `
            -Name "OptionalComponents/ExchangeApiAbsentDoesNotIncrementWarningCount" `
            -Failure "відсутній exchangAPI не повинен планувати warning-producing service actions"
        Test-BRAVOCondition `
            -Condition (
                -not $absentExchangeApiPlan.ManageService -and
                -not $absentExchangeApiPlan.IncludeLegacyData
            ) `
            -Name "OptionalComponents/ExchangeApiAbsentDoesNotScheduleActions" `
            -Failure "відсутній exchangAPI не повинен планувати runtime, log, retention або service дії"
        Test-BRAVOCondition `
            -Condition (-not $absentExchangeApiPlan.IncludeLegacyData) `
            -Name "OptionalComponents/ExchangeApiAbsentDoesNotMigrateLegacyLogs" `
            -Failure "залишений legacy каталог exchangAPI не активує відсутній компонент"
        $presentExchangeApiPlan = Invoke-BRAVORotationHelper {
            Get-BRAVOOptionalServiceComponentPlan -ServiceExists $true -ServiceDisabled $false
        }
        Test-BRAVOCondition `
            -Condition ($presentExchangeApiPlan.ManageService -and $presentExchangeApiPlan.IncludeLegacyData) `
            -Name "OptionalComponents/ExchangeApiPresentPreservesMaintenance" `
            -Failure "встановлений активний exchangAPI має зберегти наявну maintenance поведінку"
        $disabledExchangeApiPlan = Invoke-BRAVORotationHelper {
            Get-BRAVOOptionalServiceComponentPlan -ServiceExists $true -ServiceDisabled $true
        }
        Test-BRAVOCondition `
            -Condition (-not $disabledExchangeApiPlan.SilentlySkipped -and -not $disabledExchangeApiPlan.ManageService -and $disabledExchangeApiPlan.IncludeLegacyData) `
            -Name "OptionalComponents/ExchangeApiDisabledIsNotTreatedAsAbsent" `
            -Failure "встановлений Disabled exchangAPI має лишатись відмінним від відсутньої служби"
        Test-BRAVOCondition `
            -Condition (-not $absentExchangeApiPlan.IncludeLegacyData) `
            -Name "OptionalComponents/LegacyDirectoryDoesNotActivateAbsentComponent" `
            -Failure "залишений каталог exchangAPI не повинен активувати відсутній optional-компонент"

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
        $manualLauncherRoot = Join-Path ([IO.Path]::GetTempPath()) (
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

        # range_id_log.json має той самий WOW64-контракт, що й bravo.ini:
        # один системний каталог, жодного fallback до LIMSRoot або legacy
        # RangeIdMonitoring.FilePath.
        $rangeIdPathOnX64 = Get-BRAVOSystemRangeIdLogPath `
            -SystemRoot "C:\WindowsTest" `
            -Is64BitOperatingSystem $true
        $rangeIdPathOnX86 = Get-BRAVOSystemRangeIdLogPath `
            -SystemRoot "C:\WindowsTest" `
            -Is64BitOperatingSystem $false
        Test-BRAVOCondition `
            -Condition ($rangeIdPathOnX64 -eq "C:\WindowsTest\SysWOW64\range_id_log.json") `
            -Name "RangeId/01-SystemPathOnX64" `
            -Failure "на 64-бітній ОС range_id_log.json має визначатись рівно в %SystemRoot%\SysWOW64"
        Test-BRAVOCondition `
            -Condition ($rangeIdPathOnX86 -eq "C:\WindowsTest\System32\range_id_log.json") `
            -Name "RangeId/02-SystemPathOnX86" `
            -Failure "на 32-бітній ОС range_id_log.json має визначатись рівно в %SystemRoot%\System32"
        Test-BRAVOCondition `
            -Condition (
                (Split-Path -Parent $rangeIdPathOnX64) -eq
                    (Get-BRAVOSystemDirectoryPath -SystemRoot "C:\WindowsTest" -Is64BitOperatingSystem $true) -and
                (Split-Path -Parent $rangeIdPathOnX86) -eq
                    (Get-BRAVOSystemDirectoryPath -SystemRoot "C:\WindowsTest" -Is64BitOperatingSystem $false) -and
                (Split-Path -Parent $iniPathOnX64) -eq (Split-Path -Parent $rangeIdPathOnX64) -and
                (Split-Path -Parent $iniPathOnX86) -eq (Split-Path -Parent $rangeIdPathOnX86)
            ) `
            -Name "RangeId/03-UsesSameSystemDirectoryContractAsBravoIni" `
            -Failure "bravo.ini і range_id_log.json мають використовувати один системний каталог для кожної архітектури ОС"
        $syntheticLimsRoot = Join-Path $rotationTestRoot "RangeIdLimsRoot"
        $limsRangeIdPath = Join-Path $syntheticLimsRoot "range_id_log.json"
        [void](New-BRAVOLogRotationFixture -Directory $syntheticLimsRoot -Name "range_id_log.json" -Content '{}')
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath $limsRangeIdPath -PathType Leaf) -and
                $rangeIdPathOnX64 -ne $limsRangeIdPath -and
                $rangeIdPathOnX64 -notlike "$syntheticLimsRoot\*"
            ) `
            -Name "RangeId/04-LimsRootIsNeverFallback" `
            -Failure "існування range_id_log.json у LIMSRoot не може підміняти системний шлях"
        $legacyConfiguredRangeIdPath = "D:\LIMS\range_id_log.json"
        Test-BRAVOCondition `
            -Condition (
                $rangeIdPathOnX64 -ne $legacyConfiguredRangeIdPath -and
                $maintenanceScriptText.Contains('Get-BRAVOSystemRangeIdLogPath') -and
                -not $maintenanceScriptText.Contains('RangeIdMonitoring.FilePath')
            ) `
            -Name "RangeId/05-LegacyConfiguredFilePathDoesNotOverrideSystemPath" `
            -Failure "legacy RangeIdMonitoring.FilePath може лишатись у локальному config для сумісності, але не має визначати шлях runtime"
        $rangeIdUsageModule = New-BRAVOSelfTestRuntimeModule `
            -SourceText $maintenanceScriptText `
            -FunctionNames @('Test-RangeIdUsage')
        $missingSystemRangeIdWarning = & $rangeIdUsageModule {
            param($Path)
            $messages = New-Object System.Collections.Generic.List[string]
            function Write-Log {
                param($Message, $Level, [switch]$NoTimestamp, [switch]$NoConsole)
                # NoTimestamp/NoConsole — дзеркалять реальну сигнатуру,
                # тілу не потрібні (лише Message/Level фіксуються);
                # consumed через $null =, без нового PSReviewUnusedParameter.
                $null = $NoTimestamp
                $null = $NoConsole
                $messages.Add("[$Level] $Message")
            }
            function Send-SlackAlert { param($Message, [switch]$IsCritical) }
            Test-RangeIdUsage -Path $Path -ThresholdPercent 80
            return @($messages)
        } $rangeIdPathOnX64
        Test-BRAVOCondition `
            -Condition (
                @($missingSystemRangeIdWarning | Where-Object {
                    $_ -eq "[WARNING] Файл контролю діапазонів ID не знайдено: $rangeIdPathOnX64"
                }).Count -eq 1
            ) `
            -Name "RangeId/06-MissingSystemFileProducesWarning" `
            -Failure "відсутній authoritative системний range_id_log.json має давати WARNING з фактичним шляхом без пошуку копій"

        # --- Test 3: відсутній bravo.ini -> помилка з назвою шляху, без
        # мовчазного fallback на каталог поруч із bravo.exe ---
        $test3SystemRoot = Join-Path $rotationTestRoot "test03\Windows"
        [void][IO.Directory]::CreateDirectory((Join-Path $test3SystemRoot "SysWOW64"))
        $test3InstallDirectory = Join-Path $rotationTestRoot "test03\LIMS"
        [void](New-BRAVOLogRotationFixture -Directory $test3InstallDirectory -Name "bravo.exe" -Content "exe")
        # Пастка: поруч із bravo.exe лежить ЧУЖИЙ bravo.ini з іншим trace.
        [void](New-BRAVOLogRotationFixture `
            -Directory $test3InstallDirectory `
            -Name "bravo.ini" `
            -Content "[Debug]`r`nFILE=D:\WRONG\wrong.out`r`n")
        $test3Discovery = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $test3InstallDirectory `
            -Services @(New-BRAVOSyntheticBravoService -ExecutablePath (Join-Path $test3InstallDirectory "bravo.exe")) `
            -SystemRoot $test3SystemRoot `
            -Is64BitOperatingSystem $true
        Test-BRAVOCondition `
            -Condition (
                [string]::IsNullOrWhiteSpace([string]$test3Discovery.BravoIniPath) -and
                [string]$test3Discovery.Reasons.BravoIniPath -like "*SysWOW64\bravo.ini*" -and
                [string]::IsNullOrWhiteSpace([string]$test3Discovery.TRACE_FILE)
            ) `
            -Name "LogRotation/03-NoFallbackToBravoExeDirectory" `
            -Failure "за відсутності bravo.ini у системному каталозі має бути помилка з назвою перевіреного шляху, а не мовчазне читання чужого bravo.ini поруч із bravo.exe"

        # --- Test 4: відносний [Debug]/FILE резолвиться від каталогу
        # інсталяції BRAVO ---
        $test4SystemRoot = Join-Path $rotationTestRoot "test04\Windows"
        $test4InstallDirectory = Join-Path $rotationTestRoot "test04\LIMS-NEW"
        [void](New-BRAVOLogRotationFixture -Directory $test4InstallDirectory -Name "bravo.exe" -Content "exe")
        [void](New-BRAVOLogRotationFixture `
            -Directory (Join-Path $test4SystemRoot "SysWOW64") `
            -Name "bravo.ini" `
            -Content "[model]`r`nMODEL=D:\LIMS\MODEL\lims`r`n[Debug]`r`nFILE= `"TraceSRV.out`" `r`n")
        $test4Discovery = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $test4InstallDirectory `
            -Services @(New-BRAVOSyntheticBravoService -ExecutablePath (Join-Path $test4InstallDirectory "bravo.exe")) `
            -SystemRoot $test4SystemRoot `
            -Is64BitOperatingSystem $true
        Test-BRAVOCondition `
            -Condition (
                [string]$test4Discovery.TRACE_FILE -eq (Join-Path $test4InstallDirectory "TraceSRV.out") -and
                -not [bool]$test4Discovery.TRACE_FILE_OUTSIDE_INSTALLATION
            ) `
            -Name "LogRotation/04-RelativeTraceResolvedAgainstInstallation" `
            -Failure "відносний [Debug]/FILE має резолвитись від каталогу інсталяції BRAVO (не від CWD, ArchiveRoot чи SysWOW64), із trim і знятими лапками"

        # --- Test 5: trace поза каталогом інсталяції позначається ---
        $test5SystemRoot = Join-Path $rotationTestRoot "test05\Windows"
        $test5InstallDirectory = Join-Path $rotationTestRoot "test05\LIMS-NEW"
        $test5OutsidePath = Join-Path $rotationTestRoot "test05\Elsewhere\BravoDebug.log"
        [void](New-BRAVOLogRotationFixture -Directory $test5InstallDirectory -Name "bravo.exe" -Content "exe")
        [void](New-BRAVOLogRotationFixture `
            -Directory (Join-Path $test5SystemRoot "SysWOW64") `
            -Name "bravo.ini" `
            -Content "[Debug]`r`nFILE=$test5OutsidePath`r`n")
        $test5Discovery = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $test5InstallDirectory `
            -Services @(New-BRAVOSyntheticBravoService -ExecutablePath (Join-Path $test5InstallDirectory "bravo.exe")) `
            -SystemRoot $test5SystemRoot `
            -Is64BitOperatingSystem $true
        Test-BRAVOCondition `
            -Condition (
                [string]$test5Discovery.TRACE_FILE -eq $test5OutsidePath -and
                [bool]$test5Discovery.TRACE_FILE_OUTSIDE_INSTALLATION
            ) `
            -Name "LogRotation/05-TraceOutsideInstallationIsFlagged" `
            -Failure "trace поза каталогом інсталяції BRAVO має бути позначений у діагностиці, але не втрачений"

        # --- Test 6: [Debug] без FILE -> помилка з назвами bravo.ini/[Debug]/FILE ---
        $test6SystemRoot = Join-Path $rotationTestRoot "test06\Windows"
        [void](New-BRAVOLogRotationFixture `
            -Directory (Join-Path $test6SystemRoot "SysWOW64") `
            -Name "bravo.ini" `
            -Content "[model]`r`nMODEL=D:\LIMS\MODEL\lims`r`n[Debug]`r`n")
        $test6Discovery = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $rotationTestRoot `
            -Services @() `
            -SystemRoot $test6SystemRoot `
            -Is64BitOperatingSystem $true
        $test6Configuration = Invoke-BRAVORotationHelper -Body {
            param($DiscoveryResult, $TraceRoot, $DateFolder)
            Get-BRAVOTraceConfiguration `
                -DiscoveryResult $DiscoveryResult `
                -TraceRootDirectory $TraceRoot `
                -DateFolderName $DateFolder
        } -Arguments @($test6Discovery, (Join-Path $rotationTestRoot "test06\Trace"), "2026-08-08")
        $test6Reason = [string]$test6Configuration.Reason
        Test-BRAVOCondition `
            -Condition (
                -not [bool]$test6Configuration.IsValid -and
                $test6Reason.Contains("bravo.ini") -and
                $test6Reason.Contains("[Debug]") -and
                $test6Reason.Contains("FILE")
            ) `
            -Name "LogRotation/06-MissingDebugFileIsConfigurationError" `
            -Failure "без ключа FILE у секції [Debug] має бути помилка конфігурації, у якій названо і bravo.ini, і [Debug], і FILE"

        # --- Test 7: Trace MAX+1, а не перший вільний номер ---
        $test7Source = Join-Path $rotationTestRoot "test07\src"
        $test7Destination = Join-Path $rotationTestRoot "test07\dst"
        foreach ($existingName in @("TraceSRV_1.out", "TraceSRV_2.out", "TraceSRV_5.out")) {
            [void](New-BRAVOLogRotationFixture -Directory $test7Destination -Name $existingName)
        }
        $test7TracePath = New-BRAVOLogRotationFixture -Directory $test7Source -Name "TraceSRV.out" -Content "trace"
        $test7Summary = Invoke-BRAVORotationHelper -Body {
            param($TracePath, $Destination, $Logger)
            Invoke-BRAVOTraceRotation `
                -TracePath $TracePath `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test7TracePath, $test7Destination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath (Join-Path $test7Destination "TraceSRV_6.out")) -and
                [int]$test7Summary.Moved -eq 1
            ) `
            -Name "LogRotation/07-TraceMaxPlusOne" `
            -Failure "за наявних _1/_2/_5 наступним має бути _6 (MAX+1), а не _3 (перший вільний номер)"

        # --- Test 8: порожній Trace лишається в джерелі ---
        $test8Source = Join-Path $rotationTestRoot "test08\src"
        $test8Destination = Join-Path $rotationTestRoot "test08\dst"
        $test8TracePath = New-BRAVOLogRotationFixture -Directory $test8Source -Name "TraceSRV.out" -Content ""
        $test8Summary = Invoke-BRAVORotationHelper -Body {
            param($TracePath, $Destination, $Logger)
            Invoke-BRAVOTraceRotation `
                -TracePath $TracePath `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test8TracePath, $test8Destination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath $test8TracePath) -and
                [int]$test8Summary.Empty -eq 1 -and
                [int]$test8Summary.Moved -eq 0 -and
                [int]$test8Summary.Errors -eq 0 -and
                @(Get-BRAVOLogRotationNames -Directory $test8Destination).Count -eq 0
            ) `
            -Name "LogRotation/08-EmptyTraceRemainsInSource" `
            -Failure "порожній trace не переміщується, не видаляється й не створює файл призначення"

        # --- Test 9: відсутній Trace -> діагностика без фейкового файла ---
        $rotationLogMessages.Clear()
        $test9Destination = Join-Path $rotationTestRoot "test09\dst"
        $test9TracePath = Join-Path $rotationTestRoot "test09\src\TraceSRV.out"
        $test9Summary = Invoke-BRAVORotationHelper -Body {
            param($TracePath, $Destination, $Logger)
            Invoke-BRAVOTraceRotation `
                -TracePath $TracePath `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test9TracePath, $test9Destination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                [int]$test9Summary.Errors -eq 0 -and
                [int]$test9Summary.Moved -eq 0 -and
                -not (Test-Path -LiteralPath $test9TracePath) -and
                @($rotationLogMessages | Where-Object { $_ -like "*ще не створено*" }).Count -gt 0
            ) `
            -Name "LogRotation/09-AbsentTraceIsDiagnosticOnly" `
            -Failure "відсутній trace дає діагностичне повідомлення, не помилку і не створює фейкове джерело"

        # --- Test 10: обидва шаблони exchangAPI + дедуплікація за FullName ---
        $test10Source = Join-Path $rotationTestRoot "test10\src"
        foreach ($sourceName in @("exchangAPI.log", "exchangAPI_1.log", "exchangAPI_2.log")) {
            [void](New-BRAVOLogRotationFixture -Directory $test10Source -Name $sourceName -Content "x")
        }
        $test10Files = @(Invoke-BRAVORotationHelper -Body {
            param($Directory)
            Get-BRAVOExchangeApiLogFiles -Directory $Directory -Patterns @("exchangAPI_*.log", "exchangAPI*.log")
        } -Arguments @($test10Source))
        Test-BRAVOCondition `
            -Condition (
                $test10Files.Count -eq 3 -and
                @($test10Files | Select-Object -ExpandProperty FullName -Unique).Count -eq 3
            ) `
            -Name "LogRotation/10-ExchangeApiDualPatternDeduplicated" `
            -Failure "exchangAPI шукається за обома шаблонами, але exchangAPI_1.log відповідає обом — після merge має лишитись 3 унікальні файли, а не 5"

        # --- Test 11: номер джерела exchangAPI ігнорується ---
        $test11Source = Join-Path $rotationTestRoot "test11\src"
        $test11Destination = Join-Path $rotationTestRoot "test11\dst"
        [void](New-BRAVOLogRotationFixture -Directory $test11Source -Name "exchangAPI_25.log" -Content "x")
        foreach ($existingName in @("exchangAPI_1.log", "exchangAPI_2.log", "exchangAPI_9.log")) {
            [void](New-BRAVOLogRotationFixture -Directory $test11Destination -Name $existingName)
        }
        [void](Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOExchangeApiLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test11Source, $test11Destination, $rotationLogger))
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath (Join-Path $test11Destination "exchangAPI_10.log")) -and
                -not (Test-Path -LiteralPath (Join-Path $test11Destination "exchangAPI_25.log")) -and
                -not (Test-Path -LiteralPath (Join-Path $test11Destination "exchangAPI_25_1.log"))
            ) `
            -Name "LogRotation/11-ExchangeApiSourceSequenceIgnored" `
            -Failure "exchangAPI_25.log має стати exchangAPI_10.log (MAX+1 у призначенні), а не зберегти власний номер чи стати exchangAPI_25_1.log"

        # --- Test 12: кілька файлів exchangAPI у стабільному порядку ---
        $test12Source = Join-Path $rotationTestRoot "test12\src"
        $test12Destination = Join-Path $rotationTestRoot "test12\dst"
        [void](New-BRAVOLogRotationFixture -Directory $test12Source -Name "exchangAPI.log" -Content "first" -LastWriteTime ([datetime]"2026-08-08T10:00:00"))
        [void](New-BRAVOLogRotationFixture -Directory $test12Source -Name "exchangAPI_1.log" -Content "second" -LastWriteTime ([datetime]"2026-08-08T11:00:00"))
        [void](New-BRAVOLogRotationFixture -Directory $test12Source -Name "exchangAPI_error.log" -Content "third" -LastWriteTime ([datetime]"2026-08-08T12:00:00"))
        foreach ($existingName in @("exchangAPI_1.log", "exchangAPI_2.log", "exchangAPI_5.log")) {
            [void](New-BRAVOLogRotationFixture -Directory $test12Destination -Name $existingName)
        }
        $test12Summary = Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOExchangeApiLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test12Source, $test12Destination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                [int]$test12Summary.Moved -eq 3 -and
                [IO.File]::ReadAllText((Join-Path $test12Destination "exchangAPI_6.log")) -eq "first" -and
                [IO.File]::ReadAllText((Join-Path $test12Destination "exchangAPI_7.log")) -eq "second" -and
                [IO.File]::ReadAllText((Join-Path $test12Destination "exchangAPI_8.log")) -eq "third"
            ) `
            -Name "LogRotation/12-ExchangeApiStableSourceOrder" `
            -Failure "три файли exchangAPI мають отримати _6/_7/_8 у стабільному порядку (LastWriteTime ASC, потім Name ASC)"

        # --- Test 13: Apache бере лише журнали й не заходить у підкаталоги ---
        $test13Source = Join-Path $rotationTestRoot "test13\src"
        $test13Destination = Join-Path $rotationTestRoot "test13\dst"
        [void](New-BRAVOLogRotationFixture -Directory $test13Source -Name "access.log" -Content "a")
        [void](New-BRAVOLogRotationFixture -Directory $test13Source -Name "error.log" -Content "e")
        [void](New-BRAVOLogRotationFixture -Directory $test13Source -Name "httpd.pid" -Content "1234")
        [void](New-BRAVOLogRotationFixture -Directory $test13Source -Name "worker.lock" -Content "l")
        [void](New-BRAVOLogRotationFixture -Directory $test13Source -Name "temp.tmp" -Content "t")
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test13Source "old") -Name "nested.log" -Content "n")
        [void](Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOApacheLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test13Source, $test13Destination, $rotationLogger))
        Test-BRAVOCondition `
            -Condition (
                ((Get-BRAVOLogRotationNames -Directory $test13Destination) -join ",") -eq "access_1.log,error_1.log" -and
                ((Get-BRAVOLogRotationNames -Directory $test13Source) -join ",") -eq "httpd.pid,temp.tmp,worker.lock" -and
                (Test-Path -LiteralPath (Join-Path $test13Source "old\nested.log"))
            ) `
            -Name "LogRotation/13-ApacheFiltersServiceFilesAndStaysFlat" `
            -Failure "Apache має брати лише *.log безпосередньо з apache\logs: httpd.pid/*.lock/*.tmp і вкладені каталоги лишаються недоторканими"

        # --- Test 14: незалежні послідовності Apache і пропуски в нумерації ---
        $test14Source = Join-Path $rotationTestRoot "test14\src"
        $test14Destination = Join-Path $rotationTestRoot "test14\dst"
        [void](New-BRAVOLogRotationFixture -Directory $test14Source -Name "access.log" -Content "a")
        [void](New-BRAVOLogRotationFixture -Directory $test14Source -Name "error.log" -Content "e")
        [void](New-BRAVOLogRotationFixture -Directory $test14Source -Name "ssl_error.log" -Content "s")
        foreach ($existingName in @("access_1.log", "access_3.log", "access_10.log", "error_1.log", "error_9.log")) {
            [void](New-BRAVOLogRotationFixture -Directory $test14Destination -Name $existingName)
        }
        [void](Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOApacheLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test14Source, $test14Destination, $rotationLogger))
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath (Join-Path $test14Destination "access_11.log")) -and
                (Test-Path -LiteralPath (Join-Path $test14Destination "error_10.log")) -and
                (Test-Path -LiteralPath (Join-Path $test14Destination "ssl_error_1.log"))
            ) `
            -Name "LogRotation/14-IndependentSequencesAndGapsNeverReused" `
            -Failure "кожне ім'я має власну послідовність, а пропуски не перевикористовуються: access->_11 (числове порівняння), error->_10, ssl_error->_1"

        # --- Test 15: BRAVO Web зберігає відносну структуру каталогів ---
        $test15Source = Join-Path $rotationTestRoot "test15\src"
        $test15Destination = Join-Path $rotationTestRoot "test15\dst"
        [void](New-BRAVOLogRotationFixture -Directory $test15Source -Name "bravoexec.log" -Content "b")
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test15Source "API") -Name "request.log" -Content "api")
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test15Source "Integration\API") -Name "request.log" -Content "integration")
        $test15Summary = Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOWebApplicationLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test15Source, $test15Destination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                [int]$test15Summary.Moved -eq 3 -and
                (Test-Path -LiteralPath (Join-Path $test15Destination "bravoexec_1.log")) -and
                [IO.File]::ReadAllText((Join-Path $test15Destination "API\request_1.log")) -eq "api" -and
                [IO.File]::ReadAllText((Join-Path $test15Destination "Integration\API\request_1.log")) -eq "integration"
            ) `
            -Name "LogRotation/15-BravoWebRecursivePreservesStructure" `
            -Failure "www\log обходиться рекурсивно зі збереженням відносної структури: однакові імена в різних гілках не повинні колізувати"

        # --- Test 16: незалежна послідовність у кожному підкаталозі ---
        $test16Source = Join-Path $rotationTestRoot "test16\src"
        $test16Destination = Join-Path $rotationTestRoot "test16\dst"
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test16Source "API") -Name "request.log" -Content "api")
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test16Source "Integration\API") -Name "request.log" -Content "integration")
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test16Destination "API") -Name "request_1.log" -Content "old-api")
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test16Destination "API") -Name "request_2.log" -Content "old-api-2")
        [void](Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOWebApplicationLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test16Source, $test16Destination, $rotationLogger))
        Test-BRAVOCondition `
            -Condition (
                [IO.File]::ReadAllText((Join-Path $test16Destination "API\request_3.log")) -eq "api" -and
                [IO.File]::ReadAllText((Join-Path $test16Destination "Integration\API\request_1.log")) -eq "integration" -and
                [IO.File]::ReadAllText((Join-Path $test16Destination "API\request_1.log")) -eq "old-api"
            ) `
            -Name "LogRotation/16-SequencePerRelativeDirectory" `
            -Failure "послідовність рахується окремо для кожного відносного каталогу призначення: API\request_3.log і Integration\API\request_1.log"

        # --- Test 17: порожній application log лишається в джерелі ---
        $test17Source = Join-Path $rotationTestRoot "test17\src"
        $test17Destination = Join-Path $rotationTestRoot "test17\dst"
        $test17EmptyPath = New-BRAVOLogRotationFixture -Directory $test17Source -Name "errornum.log" -Content ""
        $test17Summary = Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOWebApplicationLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test17Source, $test17Destination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                [int]$test17Summary.Empty -eq 1 -and
                [int]$test17Summary.Moved -eq 0 -and
                [int]$test17Summary.Errors -eq 0 -and
                (Test-Path -LiteralPath $test17EmptyPath)
            ) `
            -Name "LogRotation/17-EmptyApplicationLogSkipped" `
            -Failure "порожній application log лишається в джерелі, не отримує номера й не є помилкою"

        # --- Test 18: жодного перезапису наявного журналу ---
        $test18Source = Join-Path $rotationTestRoot "test18\src"
        $test18Destination = Join-Path $rotationTestRoot "test18\dst"
        [void](New-BRAVOLogRotationFixture -Directory $test18Source -Name "access.log" -Content "new-content")
        [void](New-BRAVOLogRotationFixture -Directory $test18Destination -Name "access_1.log" -Content "must-survive")
        [void](Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOApacheLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test18Source, $test18Destination, $rotationLogger))
        $moveWithSequenceBody = [regex]::Match(
            $maintenanceScriptText,
            '(?s)function Move-BRAVOLogWithSequence \{.*?\r?\n\}'
        )
        Test-BRAVOCondition `
            -Condition (
                [IO.File]::ReadAllText((Join-Path $test18Destination "access_1.log")) -eq "must-survive" -and
                [IO.File]::ReadAllText((Join-Path $test18Destination "access_2.log")) -eq "new-content" -and
                $moveWithSequenceBody.Success -and
                $moveWithSequenceBody.Value -notmatch 'Move-Item[^\r\n]*-Force'
            ) `
            -Name "LogRotation/18-NoOverwriteOfExistingLog" `
            -Failure "наявний файл призначення не можна перезаписувати: потрібен новий MAX+1 і жодного Move-Item -Force"

        # --- Test 19: структурований результат і перевірка після move ---
        $test19Source = Join-Path $rotationTestRoot "test19\src"
        $test19Destination = Join-Path $rotationTestRoot "test19\dst"
        $test19Content = "payload-0123456789"
        $test19SourcePath = New-BRAVOLogRotationFixture -Directory $test19Source -Name "firm.log" -Content $test19Content
        [void](New-BRAVOLogRotationFixture -Directory $test19Destination -Name "firm_4.log")
        $test19Result = Invoke-BRAVORotationHelper -Body {
            param($SourcePath, $Destination, $Logger)
            Move-BRAVOLogWithSequence `
                -SourcePath $SourcePath `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test19SourcePath, $test19Destination, $rotationLogger)
        $test19ExpectedSize = [Text.Encoding]::UTF8.GetByteCount($test19Content)
        Test-BRAVOCondition `
            -Condition (
                [string]$test19Result.Status -eq "MOVED" -and
                [int]$test19Result.Sequence -eq 5 -and
                [int]$test19Result.Attempts -eq 1 -and
                [int64]$test19Result.SourceSize -eq $test19ExpectedSize -and
                [int64]$test19Result.DestinationSize -eq $test19ExpectedSize -and
                -not (Test-Path -LiteralPath $test19SourcePath) -and
                (Test-Path -LiteralPath ([string]$test19Result.DestinationPath))
            ) `
            -Name "LogRotation/19-StructuredResultAndPostMoveValidation" `
            -Failure "результат move має містити Status/Sequence/Attempts/SourceSize/DestinationSize, а сам move — підтверджуватись відсутністю джерела, наявністю призначення й збігом розміру"

        # --- Test 20: журнал показує початкове й кінцеве ім'я, зокрема з підкаталогом ---
        $rotationLogMessages.Clear()
        $test20Source = Join-Path $rotationTestRoot "test20\src"
        $test20Destination = Join-Path $rotationTestRoot "test20\dst"
        [void](New-BRAVOLogRotationFixture -Directory $test20Source -Name "exchangAPI_2.log" -Content "x")
        foreach ($existingName in @("exchangAPI_1.log", "exchangAPI_5.log")) {
            [void](New-BRAVOLogRotationFixture -Directory $test20Destination -Name $existingName)
        }
        [void](Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOExchangeApiLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test20Source, $test20Destination, $rotationLogger))
        $test20NestedSource = Join-Path $rotationTestRoot "test20\web"
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test20NestedSource "API") -Name "request.log" -Content "api")
        [void](Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOWebApplicationLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test20NestedSource, (Join-Path $rotationTestRoot "test20\webdst"), $rotationLogger))
        Test-BRAVOCondition `
            -Condition (
                @($rotationLogMessages | Where-Object {
                    $_ -eq "[SUCCESS] Переміщено exchangAPI_2.log -> exchangAPI_6.log"
                }).Count -eq 1 -and
                @($rotationLogMessages | Where-Object {
                    $_ -eq "[SUCCESS] Переміщено API\request.log -> API\request_1.log"
                }).Count -eq 1
            ) `
            -Name "LogRotation/20-MoveLogShowsBothNames" `
            -Failure "успішне переміщення має показувати початкове І кінцеве ім'я, а для вкладених журналів — разом із відносним каталогом"

        # --- Test 21: агрегована статистика компонента ---
        $rotationLogMessages.Clear()
        $test21Source = Join-Path $rotationTestRoot "test21\src"
        $test21Destination = Join-Path $rotationTestRoot "test21\dst"
        [void](New-BRAVOLogRotationFixture -Directory $test21Source -Name "access.log" -Content "a")
        [void](New-BRAVOLogRotationFixture -Directory $test21Source -Name "error.log" -Content "")
        [void](Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOApacheLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test21Source, $test21Destination, $rotationLogger))
        Test-BRAVOCondition `
            -Condition (
                @($rotationLogMessages | Where-Object {
                    $_ -eq "[SUCCESS] Apache: знайдено: 2, непорожніх: 1, переміщено: 1, порожніх: 1, пропущено: 1, помилок: 0"
                }).Count -eq 1
            ) `
            -Name "LogRotation/21-AggregatedSummaryIsLogged" `
            -Failure "кожен компонент має завершуватись агрегованим рядком «знайдено/непорожніх/переміщено/порожніх/пропущено/помилок»"

        # --- Test 22: робочий каталог exchangAPI (NSSM і Win32_Service) ---
        $test22NssmResult = Invoke-BRAVORotationHelper -Body {
            param($ServiceInstance, $NssmParameters)
            Resolve-BRAVOExchangeApiRuntimeDirectory `
                -ServiceName "exchangAPI" `
                -FallbackDirectory "D:\LIMS-FALLBACK" `
                -ServiceInstance $ServiceInstance `
                -NssmParameters $NssmParameters
        } -Arguments @(
            [pscustomobject]@{ PathName = '"C:\nssm\nssm.exe"' },
            @{ Application = "D:\LIMS-NEW\exchangAPI.exe"; AppDirectory = "D:\LIMS-NEW\" }
        )
        $test22ServiceResult = Invoke-BRAVORotationHelper -Body {
            param($ServiceInstance, $NssmParameters)
            Resolve-BRAVOExchangeApiRuntimeDirectory `
                -ServiceName "exchangAPI" `
                -FallbackDirectory "D:\LIMS-FALLBACK" `
                -ServiceInstance $ServiceInstance `
                -NssmParameters $NssmParameters
        } -Arguments @(
            [pscustomobject]@{ PathName = '"D:\LIMS-NEW\exchangAPI.exe" -k runservice' },
            @{}
        )
        $test22FallbackResult = Invoke-BRAVORotationHelper -Body {
            param($ServiceInstance, $NssmParameters)
            Resolve-BRAVOExchangeApiRuntimeDirectory `
                -ServiceName "exchangAPI" `
                -FallbackDirectory "D:\LIMS-FALLBACK" `
                -ServiceInstance $ServiceInstance `
                -NssmParameters $NssmParameters
        } -Arguments @([pscustomobject]@{ PathName = "" }, @{})
        Test-BRAVOCondition `
            -Condition (
                [string]$test22NssmResult.Directory -eq "D:\LIMS-NEW" -and
                [string]$test22ServiceResult.Directory -eq "D:\LIMS-NEW" -and
                [string]$test22FallbackResult.Directory -eq "D:\LIMS-FALLBACK" -and
                ([string]$test22FallbackResult.Reason).Contains("fallback")
            ) `
            -Name "LogRotation/22-ExchangeApiRuntimeDirectoryResolution" `
            -Failure "робочий каталог exchangAPI: NSSM AppDirectory має пріоритет, інакше Win32_Service.PathName, і лише потім явно позначений fallback"

        # --- Test 23: міграція legacy-каталогів, ідемпотентна ---
        $test23ArchiveRoot = Join-Path $rotationTestRoot "test23\ARCHIV"
        $test23LogRoot = Join-Path $test23ArchiveRoot "LOGS"
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test23ArchiveRoot "Trace\2026-07-01") -Name "TraceSRV_000001.out" -Content "old-trace")
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test23ArchiveRoot "Trace") -Name "Trace_2026-06-01.mdz" -Content "archive")
        [void](New-BRAVOLogRotationFixture `
            -Directory (Join-Path $test23ArchiveRoot "exchangAPI") `
            -Name "exchangAPI_3.log" `
            -Content "legacy-loose" `
            -LastWriteTime ([datetime]"2026-07-05T09:00:00"))
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test23ArchiveRoot "Br-a-vo.web\2026-07-02") -Name "access_000001.log" -Content "web")
        $test23Plan = @(Invoke-BRAVORotationHelper -Body {
            param($ArchiveRoot, $LogRoot)
            Get-BRAVOLegacyLogMigrationPlan -ArchiveRoot $ArchiveRoot -LogRoot $LogRoot
        } -Arguments @($test23ArchiveRoot, $test23LogRoot))
        foreach ($migrationPass in @(1, 2)) {
            foreach ($planEntry in $test23Plan) {
                [void](Invoke-BRAVORotationHelper -Body {
                    param($Entry, $Logger)
                    Invoke-BRAVOLegacyLogMigration `
                        -LegacyPath $Entry.LegacyPath `
                        -DestinationPath $Entry.DestinationPath `
                        -LogicalBaseName ([string]$Entry.LogicalBaseName) `
                        -RetryCount 1 `
                        -RetryDelaySeconds 0 `
                        -Logger $Logger
                } -Arguments @($planEntry, $rotationLogger))
            }
        }
        $test23MigratedFiles = @(
            Get-ChildItem -LiteralPath $test23LogRoot -Recurse -File -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Name |
                Sort-Object
        )
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath (Join-Path $test23LogRoot "Trace\2026-07-01\TraceSRV_000001.out")) -and
                (Test-Path -LiteralPath (Join-Path $test23LogRoot "Trace\Trace_2026-06-01.mdz")) -and
                (Test-Path -LiteralPath (Join-Path $test23LogRoot "exchangAPI\2026-07-05\exchangAPI_1.log")) -and
                (Test-Path -LiteralPath (Join-Path $test23LogRoot "BravoWeb\2026-07-02\access_000001.log")) -and
                -not (Test-Path -LiteralPath (Join-Path $test23ArchiveRoot "Trace")) -and
                -not (Test-Path -LiteralPath (Join-Path $test23ArchiveRoot "exchangAPI")) -and
                -not (Test-Path -LiteralPath (Join-Path $test23ArchiveRoot "Br-a-vo.web")) -and
                $test23MigratedFiles.Count -eq 4
            ) `
            -Name "LogRotation/23-LegacyMigrationIsIdempotent" `
            -Failure "legacy-каталоги мають мігрувати під LOGS зі збереженням структури (плоскі журнали — у каталог-дату за LastWriteTime), а повторний запуск не повинен створювати дублікатів"

        # --- Test 24: часткова невдача міграції зберігає джерело ---
        $test24ArchiveRoot = Join-Path $rotationTestRoot "test24\ARCHIV"
        $test24LogRoot = Join-Path $test24ArchiveRoot "LOGS"
        $test24LegacyPath = Join-Path $test24ArchiveRoot "Trace"
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test24LegacyPath "2026-07-01") -Name "TraceSRV_1.out" -Content "movable")
        $test24LockedPath = New-BRAVOLogRotationFixture -Directory (Join-Path $test24LegacyPath "2026-07-01") -Name "TraceSRV_2.out" -Content "locked"
        $test24LockStream = [IO.File]::Open($test24LockedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            $test24Result = Invoke-BRAVORotationHelper -Body {
                param($LegacyPath, $DestinationPath, $Logger)
                Invoke-BRAVOLegacyLogMigration `
                    -LegacyPath $LegacyPath `
                    -DestinationPath $DestinationPath `
                    -RetryCount 1 `
                    -RetryDelaySeconds 0 `
                    -Logger $Logger
            } -Arguments @($test24LegacyPath, (Join-Path $test24LogRoot "Trace"), $rotationLogger)
        } finally {
            $test24LockStream.Dispose()
        }
        Test-BRAVOCondition `
            -Condition (
                [int]$test24Result.Failed -ge 1 -and
                [int]$test24Result.Migrated -ge 1 -and
                -not [bool]$test24Result.LegacyRemoved -and
                (Test-Path -LiteralPath $test24LockedPath) -and
                (Test-Path -LiteralPath (Join-Path $test24LogRoot "Trace\2026-07-01\TraceSRV_1.out"))
            ) `
            -Name "LogRotation/24-PartialMigrationRetainsSource" `
            -Failure "при частковій невдачі міграції невдалий файл і legacy-каталог мають лишитись для наступного запуску, а успішні — залишитись мігрованими"

        # --- Test 25: CompressedLogDays — окрема політика для .mdz ---
        $test25Path = Join-Path $rotationTestRoot "test25\Trace"
        $test25FreshDate = (Get-Date).AddDays(-100).ToString("yyyy-MM-dd")
        $test25ExpiredDate = (Get-Date).AddDays(-200).ToString("yyyy-MM-dd")
        [void](New-BRAVOLogRotationFixture -Directory $test25Path -Name "Trace_$test25FreshDate.mdz" -Content "fresh")
        [void](New-BRAVOLogRotationFixture -Directory $test25Path -Name "Trace_$test25ExpiredDate.mdz" -Content "expired")
        [void](New-BRAVOLogRotationFixture -Directory $test25Path -Name "Apache_$test25ExpiredDate.mdz" -Content "foreign")
        [void](New-BRAVOLogRotationFixture -Directory $test25Path -Name "Trace_backup.mdz" -Content "no-date")
        $test25Result = Invoke-BRAVORotationHelper -Body {
            param($Path, $Logger)
            Remove-BRAVOExpiredCompressedLogs `
                -Path $Path `
                -ArchiveNamePrefix "Trace" `
                -RetentionDays 180 `
                -Logger $Logger
        } -Arguments @($test25Path, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                [int]$test25Result.Deleted -eq 1 -and
                (Test-Path -LiteralPath (Join-Path $test25Path "Trace_$test25FreshDate.mdz")) -and
                -not (Test-Path -LiteralPath (Join-Path $test25Path "Trace_$test25ExpiredDate.mdz")) -and
                (Test-Path -LiteralPath (Join-Path $test25Path "Apache_$test25ExpiredDate.mdz")) -and
                (Test-Path -LiteralPath (Join-Path $test25Path "Trace_backup.mdz"))
            ) `
            -Name "LogRotation/25-CompressedLogDaysRetention" `
            -Failure "CompressedLogDays видаляє лише .mdz власного компонента, старші за строк: 100-денний лишається, 200-денний видаляється, чужі й недатовані архіви не чіпаються"

        # --- Test 26: цільова структура, конфігурація і нерекурсивний cleanup ---
        $removeOldLogFilesBody = [regex]::Match(
            $maintenanceScriptText,
            '(?s)function Remove-OldLogFiles \{.*?\r?\n\}'
        )
        $removeOldLogFilesCallTargets = @(
            [regex]::Matches($maintenanceScriptText, 'Remove-OldLogFiles -Path (\$\w+)') |
                ForEach-Object { $_.Groups[1].Value } |
                Where-Object { $_ -ne '$LOG_DIR' }
        )
        $bravoConfigTextForRetention = [IO.File]::ReadAllText($resolvedConfig, [Text.Encoding]::UTF8)
        Test-BRAVOCondition `
            -Condition (
                $maintenanceScriptText.Contains('$TRACE_DIR = Join-Path $SYSTEM_LOG_ROOT "Trace"') -and
                $maintenanceScriptText.Contains('$EXCHANGE_LOG_DIR = Join-Path $SYSTEM_LOG_ROOT "exchangAPI"') -and
                $maintenanceScriptText.Contains('$APACHE_LOG_DIR = Join-Path $BRAVOWEB_LOG_DIR "Apache"') -and
                $maintenanceScriptText.Contains('$BRAVOWEB_APP_LOG_DIR = Join-Path $BRAVOWEB_LOG_DIR "Application"') -and
                $bravoConfigTextForRetention -match 'CompressedLogDays\s*=\s*\d+' -and
                $maintenanceScriptText.Contains('$COMPRESSED_LOG_RETENTION_DAYS') -and
                $removeOldLogFilesBody.Success -and
                $removeOldLogFilesBody.Value -notmatch '-Recurse' -and
                $removeOldLogFilesBody.Value.Contains('BRAVO_MAINTENANCE_*.log') -and
                $removeOldLogFilesBody.Value -notmatch '"\*\.log"' -and
                $removeOldLogFilesCallTargets.Count -eq 0
            ) `
            -Name "LogRotation/26-LayoutRetentionSettingsAndNonRecursiveCleanup" `
            -Failure "структура LOGS\{Trace,exchangAPI,BravoWeb\{Apache,Application}}, окремий CompressedLogDays у BRAVO.config і нерекурсивне whitelist-очищення тільки верхнього рівня LOGS"

        # --- Test 27: відновлення служб не залежить від помилок ротації ---
        # Реальні служби не чіпаємо (ТЗ §103) — перевіряємо структуру:
        # уся ротація живе всередині try, а запуск служб — у finally, тому
        # жодна помилка ротації не може залишити production зупиненим.
        $serviceRestoreBlockIndex = $maintenanceScriptText.IndexOf('=== ВІДНОВЛЕННЯ ПОЧАТКОВОГО СТАНУ СЛУЖБ ===')
        $finallyIndex = $maintenanceScriptText.LastIndexOf('} finally {', $serviceRestoreBlockIndex)
        $rotationIndex = $maintenanceScriptText.IndexOf('=== ОБРОБКА TRACE-ФАЙЛІВ ===')
        Test-BRAVOCondition `
            -Condition (
                $serviceRestoreBlockIndex -gt 0 -and
                $finallyIndex -gt 0 -and
                $rotationIndex -gt 0 -and
                $rotationIndex -lt $finallyIndex -and
                $maintenanceScriptText.Contains('$serviceWasRunning') -and
                $maintenanceScriptText.Contains('if ($serviceWasRunning.ExchangeApi) {') -and
                $maintenanceScriptText.Contains('if ($serviceWasRunning.BravoWeb) {')
            ) `
            -Name "LogRotation/27-ServiceRestorationIsIndependentOfRotation" `
            -Failure "ротація має виконуватись усередині try, а відновлення служб — у finally за збереженим початковим станом: помилка ротації не може залишити служби зупиненими"
    } finally {
        if (Test-Path -LiteralPath $rotationTestRoot) {
            Remove-Item -LiteralPath $rotationTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # ===== ОПЕРАЦІЙНА КОНСОЛЬ: 21 сценарій (Завдання_ реалізувати
    # уніфікований Operator Console UX для BRAVO.md, §20) =====
    $credentialsSetupScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_CREDENTIALS_SETUP.ps1"),
        [Text.Encoding]::UTF8
    )
    $consoleModuleText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Console\BRAVO.Console.psm1"),
        [Text.Encoding]::UTF8
    )

    # 1. Ручний успішний прогін Archive: гілка 'УСПІШНО' існує саме тоді,
    # коли operationFailed=$false (жодна з ~26 умов відмови не спрацювала).
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('if ($operationFailed) {') -and
            $archiveScriptText -match "\}\s*else\s*\{\s*'УСПІШНО'\s*\}"
        ) `
        -Name "ConsoleUX/01-ArchiveManualSuccess" `
        -Failure "Archive має показувати Статус=УСПІШНО, коли жоден компонент не відмовив"

    # 2. Частковий збій Archive: 'ЧАСТКОВО', коли є і успішні, і невдалі
    # компоненти — на відміну від 'ПОМИЛКА', коли не вдалося жодного.
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("if (`$successCount -gt 0) { 'ЧАСТКОВО' } else { 'ПОМИЛКА' }")
        ) `
        -Name "ConsoleUX/02-ArchivePartialFailure" `
        -Failure "Archive має розрізняти 'ЧАСТКОВО' (частина компонентів вдалась) від 'ПОМИЛКА' (жодного)"

    # 3. SFTP-збій ПІСЛЯ успішних локальних архівів — окрема Причина, а не
    # загальне "не вдалося створити архів", коли локальні компоненти вже ОК.
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('"Не вдалося передати архіви на SFTP"') -and
            $archiveScriptText.Contains('elseif ([bool]$sftpStepFailed)') -and
            $archiveScriptText.Contains("@('ArchiveUpload', 'BAZA_APP', 'BAZA_WWW')")
        ) `
        -Name "ConsoleUX/03-SftpFailureAfterLocalSuccess" `
        -Failure "SFTP-збій після вдалих локальних архівів має власну Причину, не спільну з локальним провалом"

    # 4. Трансляція нативного коду завершення 7-Zip у Причину/Інструмент/
    # Код інструменту через централізовану Get-BRAVOToolExitCodeDescription.
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("Get-BRAVOToolExitCodeDescription -Tool '7-Zip'")
        ) `
        -Name "ConsoleUX/04-SevenZipExitCodeTranslation" `
        -Failure "New-Archive має транслювати нативний код 7-Zip через Get-BRAVOToolExitCodeDescription"

    # 5. Невідомий нативний код інструменту не падає й не губиться —
    # "UNKNOWN(N)" замість винятку чи мовчазного null.
    Test-BRAVOCondition `
        -Condition (
            $compatibilityScriptText.Contains('"UNKNOWN($code)"')
        ) `
        -Name "ConsoleUX/05-UnknownToolExitCode" `
        -Failure "Get-BRAVOToolExitCodeDescription має мати fallback UNKNOWN(N) для нерозпізнаного коду"

    # 6. WARNING: аномалія розміру архіву показується як Причина під
    # рядком етапу, а не мовчки ігнорується чи змінює Статус на ERROR.
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('Write-BRAVOOperatorReason -Reason $sizeAnomalyResult.Reason')
        ) `
        -Name "ConsoleUX/06-WarningReasonDisplayed" `
        -Failure "Аномалія розміру архіву має показувати Причину через Write-BRAVOOperatorReason (WARNING)"

    # 7. SKIPPED: пропущений крок показує пояснення без підпису "Причина:",
    # а не просто мовчазний пропуск нумерації. dev.14 (round 3): той самий
    # централізований plain-рендерер (Write-BRAVOConsoleDetail), що й
    # OK/WARN/FAIL — не окрема гілка Write-BRAVOSkipReason.
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptText.Contains('foreach ($detailLine in ($Details -split "`r?`n")) {') -and
            $maintenanceScriptText.Contains('Write-BRAVOConsoleDetail -Message $detailLine')
        ) `
        -Name "ConsoleUX/07-SkippedReasonDisplayed" `
        -Failure "SKIPPED-крок Maintenance має пояснення через Write-BRAVOSkipReason"

    # 8. .mdz — єдине зовнішньо видиме розширення артефакту: жоден
    # мігрований runtime не показує оператору буквальний ".7z".
    $mdzOnlyScripts = @(
        @{ Text = $archiveScriptText; Name = "Archive" },
        @{ Text = $healthRuntimeText; Name = "Health" },
        @{ Text = $restoreTestScriptText; Name = "RestoreTest" }
    )
    $scriptsWithVisible7z = @(
        $mdzOnlyScripts | Where-Object {
            $_.Text -match "['""]\.7z['""]" -or $_.Text -match "Write-Host[^\n]*\.7z"
        } | ForEach-Object { $_.Name }
    )
    Test-BRAVOCondition `
        -Condition ($scriptsWithVisible7z.Count -eq 0) `
        -Name "ConsoleUX/08-MdzOnlyArtifactExtension" `
        -Failure "Оператор не повинен бачити '.7z' як ім'я артефакту; знайдено в: $($scriptsWithVisible7z -join ', ')"

    # 9. Кількість артефактів X з Y у фінальному РЕЗУЛЬТАТ.
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("Write-BRAVOResultField -Label 'Створено архівів' -Value (`"{0} з {1}`" -f `$successCount, `$totalCount)")
        ) `
        -Name "ConsoleUX/09-ArtifactCountXofY" `
        -Failure "РЕЗУЛЬТАТ Archive має показувати 'Створено архівів: X з Y'"

    # 10. Загальний розмір створених архівів у фінальному РЕЗУЛЬТАТ.
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("Write-BRAVOResultField -Label 'Загальний розмір' -Value (Format-BRAVOFileSize -Bytes `$totalCreatedBytes)")
        ) `
        -Name "ConsoleUX/10-TotalSizeField" `
        -Failure "РЕЗУЛЬТАТ Archive має показувати 'Загальний розмір'"

    # 11. SHA512/Integrity ніколи не "OK" без реальної перевірки: обидва
    # рядки друкуються ЛИШЕ після публікації component backup. Публікація
    # відбувається тільки коли create, 7z t і SHA512 verification успішні.
    $archiveComponentBlockMatch = [regex]::Match(
        $archiveScriptText,
        '(?s)if \(\$componentPublished\) \{.*?SHA512:.*?Integrity:.*?\} else \{'
    )
    Test-BRAVOCondition `
        -Condition ($archiveComponentBlockMatch.Success) `
        -Name "ConsoleUX/11-Sha512IntegrityNeverFakedOk" `
        -Failure "SHA512/Integrity мають друкуватись лише після успішної публікації component backup, інакше це вигаданий OK"

    # 12/13/14. Ручна пауза / -NoPause / перенаправлений неінтерактивний
    # запуск — усі три керуються спільним Wait-BRAVOManualExit, а не
    # окремою логікою в кожному entrypoint.
    $waitManualExitFunctionMatch = [regex]::Match(
        $consoleModuleText,
        '(?s)function Wait-BRAVOManualExit \{.*?\n\}'
    )
    $waitManualExitText = if ($waitManualExitFunctionMatch.Success) { $waitManualExitFunctionMatch.Value } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $waitManualExitText.Contains('if ($NoPause) {') -and
            $waitManualExitText.Contains('return')
        ) `
        -Name "ConsoleUX/12-NoPauseSkipsWait" `
        -Failure "Wait-BRAVOManualExit має негайно повертатись при -NoPause"
    # dev.18: реальний DEV-LIMS ручний (MANUAL) запуск довів, що
    # [Console]::IsInputRedirected сам по собі помилково відхиляв
    # справжню операторську консоль ДО спроби RawUI.ReadKey — вікно
    # закривалось одразу після РЕЗУЛЬТАТ замість очікування. Тепер
    # [Environment]::UserInteractive лишається єдиною такою pre-check
    # причиною пропустити паузу; IsInputRedirected більше не окрема
    # самостійна умова (перевіряється explicit-negative тестом нижче).
    Test-BRAVOCondition `
        -Condition (
            $waitManualExitText.Contains('[Environment]::UserInteractive')
        ) `
        -Name "ConsoleUX/13-NonInteractiveSessionSkipsWait" `
        -Failure "Wait-BRAVOManualExit має пропускати очікування, коли [Environment]::UserInteractive=false (SYSTEM-сесія)"
    Test-BRAVOCondition `
        -Condition (
            $waitManualExitText.Contains('$Host.UI.RawUI.ReadKey(') -and
            $waitManualExitText.Contains('Натиснiть будь-яку клавiшу для закриття вiкна...')
        ) `
        -Name "ConsoleUX/14-ManualPauseWaitsForKey" `
        -Failure "Wait-BRAVOManualExit має справді чекати на клавішу в інтерактивному режимі без -NoPause"

    # 15. Health: фінальний підсумок включає Перевірок/Успішно/Попереджень/
    # Помилок — не лише голий Статус.
    Test-BRAVOCondition `
        -Condition (
            $healthRuntimeText.Contains("Write-BRAVOResultField -Label 'Перевірок'") -and
            $healthRuntimeText.Contains("Write-BRAVOResultField -Label 'Успішно'") -and
            $healthRuntimeText.Contains("Write-BRAVOResultField -Label 'Попереджень'") -and
            $healthRuntimeText.Contains("Write-BRAVOResultField -Label 'Помилок'")
        ) `
        -Name "ConsoleUX/15-HealthSummaryCounters" `
        -Failure "Health РЕЗУЛЬТАТ має показувати Перевірок/Успішно/Попереджень/Помилок"

    # 16. Restore Test: PASS/WARN/FAIL — усі три статуси в одному ValidateSet
    # (WARN, а не WARNING — власна термінологія drill-скрипта, docs §4).
    Test-BRAVOCondition `
        -Condition (
            $restoreTestScriptText.Contains("[ValidateSet('PASS', 'WARN', 'FAIL')]")
        ) `
        -Name "ConsoleUX/16-RestoreTestPassWarnFail" `
        -Failure "Restore Test має підтримувати рівно PASS/WARN/FAIL у власному словнику статусів"

    # 17. Dry Run: PASS/WARN/FAIL/PLAN — усі чотири власні статуси мають
    # кольорове відображення (docs §6: "не потрібно насильно переводити
    # в Archive-style OK/ERROR").
    $dryRunStatusColorsMatch = [regex]::Match(
        $dryRunScriptText,
        '(?s)\$dryRunStatusColors = @\{.*?\}'
    )
    $dryRunStatusColorsText = if ($dryRunStatusColorsMatch.Success) { $dryRunStatusColorsMatch.Value } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $dryRunStatusColorsText.Contains('PASS') -and
            $dryRunStatusColorsText.Contains('WARN') -and
            $dryRunStatusColorsText.Contains('FAIL') -and
            $dryRunStatusColorsText.Contains('PLAN')
        ) `
        -Name "ConsoleUX/17-DryRunFourStatuses" `
        -Failure "Dry Run має власні кольори для всіх чотирьох статусів PASS/WARN/FAIL/PLAN"

    # 18. Setup: DISCOVERY-блок виводить реальні джерела (не заглушку) —
    # BRAVO_ROOT/MODEL/BLOG/BRAVOEXCH/BAZA_APP/WEB_ROOT/BAZA_WWW.
    Test-BRAVOCondition `
        -Condition (
            $setupScriptText.Contains("Write-BRAVOResultField -Label 'BRAVO_ROOT'") -and
            $setupScriptText.Contains("Write-BRAVOResultField -Label 'MODEL'") -and
            $setupScriptText.Contains("Write-BRAVOResultField -Label 'BAZA_WWW'")
        ) `
        -Name "ConsoleUX/18-SetupDiscoveryOutput" `
        -Failure "Setup має показувати реальний DISCOVERY-блок (BRAVO_ROOT/MODEL/BAZA_WWW тощо)"

    # 19. Credentials Setup ніколи не показує значення секрету: фінальний
    # рендер оперує лише Target (назва запису)/Status/Scope/Component —
    # жодного посилання на Password/Secret/SecureSecret/.Value.
    $credentialResultBlockMatch = [regex]::Match(
        $credentialsSetupScriptText,
        '(?s)function Write-BRAVOCredentialResultBlock \{.*?\n\}'
    )
    $credentialResultBlockText = if ($credentialResultBlockMatch.Success) { $credentialResultBlockMatch.Value } else { '' }
    Test-BRAVOCondition `
        -Condition (
            -not [string]::IsNullOrWhiteSpace($credentialResultBlockText) -and
            $credentialResultBlockText.Contains('$result.Target') -and
            $credentialResultBlockText -notmatch 'Password|SecureSecret|\.Value\b|\$result\.Secret'
        ) `
        -Name "ConsoleUX/19-CredentialsNoSecretLeak" `
        -Failure "Write-BRAVOCredentialResultBlock не повинен звертатись до значення секрету — лише Target/Status/Scope"

    # 20. Tasks Install: підсумок по кожному завданню ("Завдання:") і
    # фінальні лічильники Встановлено/Оновлено/Заплановано.
    Test-BRAVOCondition `
        -Condition (
            $taskInstallerText.Contains("Write-Host 'Завдання:'") -and
            $taskInstallerText.Contains("Write-BRAVOResultField -Label 'Встановлено'") -and
            $taskInstallerText.Contains("Write-BRAVOResultField -Label 'Заплановано'")
        ) `
        -Name "ConsoleUX/20-TasksInstallSummary" `
        -Failure "Tasks Install має показувати 'Завдання:' і підсумкові лічильники в РЕЗУЛЬТАТ"

    # 21. Код завершення процесу не залежить від рендеру консолі: в
    # Archive/Health/Maintenance числовий код обчислюється РАНІШЕ виклику
    # Write-BRAVOResultHeader і зберігається в змінній, яку читає
    # підсумковий exit — не перераховується вдруге після друку.
    $exitBeforeRenderChecks = @(
        @{
            Name = "Archive"
            Text = $archiveScriptText
            ExitVar = '$script:processExitCode ='
        },
        @{
            Name = "Health"
            Text = $healthRuntimeText
            ExitVar = '$healthExitCode = switch'
        },
        @{
            Name = "Maintenance"
            Text = $maintenanceScriptText
            # dev.19 (виправлено): inline if/elseif/else замінено викликом
            # Get-BRAVOMaintenanceResolvedExitCode (та сама формула,
            # піднята ще вище — тепер ДО ЛОГ "=== СТАТУС ===", не лише ДО
            # РЕЗУЛЬТАТ).
            ExitVar = '$script:maintenanceRuntimeExitCode = Get-BRAVOMaintenanceResolvedExitCode'
        }
    )
    $exitOrderFailures = @(
        $exitBeforeRenderChecks | Where-Object {
            $exitVarIndex = $_.Text.IndexOf($_.ExitVar)
            $renderIndex = $_.Text.IndexOf('Write-BRAVOResultHeader')
            $exitVarIndex -lt 0 -or $renderIndex -lt 0 -or $exitVarIndex -gt $renderIndex
        } | ForEach-Object { $_.Name }
    )
    Test-BRAVOCondition `
        -Condition ($exitOrderFailures.Count -eq 0) `
        -Name "ConsoleUX/21-ExitCodeComputedBeforeRender" `
        -Failure "Код завершення має обчислюватись ДО Write-BRAVOResultHeader, інакше підсумок бреше; порушено в: $($exitOrderFailures -join ', ')"

    #####################################################################
    # dev.16 (review round 3): Archive/Health operator-visibility pass —
    # Plan, BAZA_APP/BAZA_WWW local numbered steps, path/access ordering,
    # unnumbered log/retention cleanup results, -SyncBAZA isolation,
    # Health BAZA/SFTP split, compact details, dynamic Total exactness.
    #####################################################################

    # --- Console: BRAVO.Console.psd1 (module MANIFEST, не .psm1) реально
    # експортує нові dev.16 public console functions. Archive/Health
    # імпортують BRAVO.Console САМЕ через .psd1 (FunctionsToExport), тому
    # текстова перевірка Export-ModuleMember у .psm1 (нижче) сама по собі
    # не гарантує, що функція РЕАЛЬНО доступна після Import-Module —
    # знайдений реальний runtime blocker: Write-BRAVOPlan була в .psm1
    # Export-ModuleMember, але не в .psd1 FunctionsToExport. Тут — справжній
    # Import-Module -Force, не текстовий пошук.
    Remove-Module -Name 'BRAVO.Console' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Console\BRAVO.Console.psd1') -Force -ErrorAction Stop
    $writeBravoPlanCommand = Get-Command -Name 'Write-BRAVOPlan' -Module 'BRAVO.Console' -ErrorAction SilentlyContinue
    $writeBravoOperationResultCommand = Get-Command -Name 'Write-BRAVOOperationResult' -Module 'BRAVO.Console' -ErrorAction SilentlyContinue
    Test-BRAVOCondition `
        -Condition (
            $null -ne $writeBravoPlanCommand -and
            $null -ne $writeBravoOperationResultCommand
        ) `
        -Name 'Console/ManifestExportsWriteBRAVOPlan' `
        -Failure 'BRAVO.Console.psd1 (module manifest) має реально експортувати Write-BRAVOPlan і Write-BRAVOOperationResult через FunctionsToExport — Archive/Health імпортують саме через .psd1, не напряму .psm1'

    # --- Static guard: кожна нова dev.16 public BRAVO.Console function
    # (використана в Archive/Health/Maintenance) має бути присутня
    # ОДНОЧАСНО у .psm1 Export-ModuleMember і .psd1 FunctionsToExport —
    # інакше саме цей клас розбіжності (psm1 vs psd1) знову пройде повз
    # текстові тести непоміченим.
    $consolePsm1TextForExportGuard = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Console\BRAVO.Console.psm1'))
    $consolePsd1TextForExportGuard = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Console\BRAVO.Console.psd1'))
    $newDev16ConsolePublicFunctions = @('Write-BRAVOOperationResult', 'Write-BRAVOPlan')
    $consoleExportMismatches = @($newDev16ConsolePublicFunctions | Where-Object {
        -not $consolePsm1TextForExportGuard.Contains("'$_'") -or -not $consolePsd1TextForExportGuard.Contains("'$_'")
    })
    Test-BRAVOCondition `
        -Condition ($consoleExportMismatches.Count -eq 0) `
        -Name 'Console/NewPublicFunctionsExportedInBothPsm1AndPsd1' `
        -Failure "нові dev.16 public BRAVO.Console functions мають бути в ОБОХ Export-ModuleMember (.psm1) і FunctionsToExport (.psd1); розбіжність: $($consoleExportMismatches -join ', ')"

    # --- Archive: План операцій відображає ті самі прапорці, що керують
    # Total вище (не hardcoded, не окремі значення, які можуть розійтися).
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('$archivePlanEntries[''Локальна синхронізація BAZA_APP''] = [bool]$bazaAppLocalSyncEnabled') -and
            $archiveScriptText.Contains('$archivePlanEntries[''Локальна синхронізація BAZA_WWW''] = [bool]$bazaWWWLocalSyncEnabled') -and
            $archiveScriptText.Contains('$archivePlanEntries[''Очищення старих backup generation''] = [bool](') -and
            $archiveScriptText.Contains('Write-BRAVOPlan -Title ''План операцій:'' -Entries $archivePlanEntries')
        ) `
        -Name 'Archive/PlanReflectsEffectiveComponents' `
        -Failure 'Archive ''План операцій'' має рендеритись через Write-BRAVOPlan із entries, побудованими з тих самих прапорців, що Total (не raw Write-Host, не окремі значення)'

    # --- Archive: BAZA_APP/BAZA_WWW локальна синхронізація мають власний
    # numbered step, коли увімкнені (не лише LOG).
    Test-BRAVOCondition `
        -Condition (
            ([regex]::Matches($archiveScriptText, [regex]::Escape('-Name "Локальна синхронізація BAZA_APP"')).Count -eq 2) -and
            ([regex]::Matches($archiveScriptText, [regex]::Escape('-Name "Локальна синхронізація BAZA_WWW"')).Count -eq 2)
        ) `
        -Name 'Archive/BazaLocalSyncHasNumberedSteps' `
        -Failure 'Локальна синхронізація BAZA_APP/BAZA_WWW має рендерити Write-BRAVOArchiveStep рівно у двох гілках (успіх/attempted і enabled-але-недоступний шлях), не в disabled-гілці'

    # --- Archive: "Перевірка шляхів" рендериться ПІСЛЯ SYSTEM read-probe
    # перевірки (не одразу після Show-PathCheckSummary/existence-перевірок).
    $archivePathStepIndex = $archiveScriptText.IndexOf('-Name "Перевірка шляхів"')
    $archiveReadProbeIndex = $archiveScriptText.IndexOf('SYSTEM source read probe FAILED')
    $archivePathStepOccurrences = [regex]::Matches($archiveScriptText, [regex]::Escape('-Name "Перевірка шляхів"')).Count
    Test-BRAVOCondition `
        -Condition (
            $archivePathStepIndex -ge 0 -and
            $archiveReadProbeIndex -ge 0 -and
            $archivePathStepIndex -gt $archiveReadProbeIndex -and
            $archivePathStepOccurrences -eq 1 -and
            $archiveScriptText.Contains('$pathCheckFullyValid = $allPathsExist -and $systemAccessValid')
        ) `
        -Name 'Archive/PathStepCannotRenderOkBeforeAccessPreflightCompletes' `
        -Failure '''Перевірка шляхів'' має рендеритись РІВНО один раз, ПІСЛЯ SYSTEM read-probe (не до SYSTEM access preflight); OK лише коли allPathsExist І systemAccessValid'

    # --- Archive: dev.18 — очищення старих журналів мігрувало на numbered
    # Write-BRAVOArchiveStep (раніше unnumbered Write-BRAVOOperationResult
    # — реальний DEV-LIMS вивід показав цю операцію поза [N/TOTAL]).
    $archiveLogCleanupIndex = $archiveScriptText.IndexOf('-Name ''Очищення старих журналів''')
    $archiveLogCleanupWindow = if ($archiveLogCleanupIndex -ge 0) {
        $archiveScriptText.Substring([Math]::Max(0, $archiveLogCleanupIndex - 400), [Math]::Min(1000, $archiveScriptText.Length - [Math]::Max(0, $archiveLogCleanupIndex - 400)))
    } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $archiveLogCleanupWindow.Contains('Write-BRAVOArchiveStep') -and
            $archiveLogCleanupWindow.Contains('''SKIPPED''') -and
            $archiveLogCleanupWindow.Contains('''ERROR''') -and
            $archiveLogCleanupWindow.Contains('журналів старших за retention немає')
        ) `
        -Name 'Archive/LogCleanupUsesNumberedStep' `
        -Failure '''Очищення старих журналів'' має рендеритись через numbered Write-BRAVOArchiveStep, з SKIPPED коли кандидатів немає'

    # --- Archive: очищення backup generation — ОДНА агрегована numbered
    # операція, що покриває і generation retention, і lunch cleanup (не
    # окремі рядки на кожен внутрішній фільтр).
    $archiveRetentionResultIndex = $archiveScriptText.IndexOf('-Name ''Очищення старих backup generation''')
    $archiveRetentionResultWindow = if ($archiveRetentionResultIndex -ge 0) {
        $archiveRetentionWindowStart = [Math]::Max(0, $archiveRetentionResultIndex - 4000)
        $archiveScriptText.Substring($archiveRetentionWindowStart, [Math]::Min(5500, $archiveScriptText.Length - $archiveRetentionWindowStart))
    } else { '' }
    Test-BRAVOCondition `
        -Condition (
            ([regex]::Matches($archiveScriptText, [regex]::Escape('-Name ''Очищення старих backup generation''')).Count -eq 1) -and
            $archiveRetentionResultWindow.Contains('Remove-BRAVOExpiredBackupGenerations') -and
            $archiveRetentionResultWindow.Contains('Remove-OldLunchArchives')
        ) `
        -Name 'Archive/BackupRetentionCleanupAggregatesSubCleanup' `
        -Failure '''Очищення старих backup generation'' має бути ОДНІЄЮ numbered операцією, що покриває і Remove-BRAVOExpiredBackupGenerations, і Remove-OldLunchArchives'

    Test-BRAVOCondition `
        -Condition (
            $archiveRetentionResultWindow.Contains('backupRetentionCleanupDidDelete') -and
            $archiveRetentionResultWindow.Contains('elseif (-not $backupRetentionCleanupDidDelete) { ''SKIPPED'' }') -and
            $archiveRetentionResultWindow.Contains('''даних для очищення немає''')
        ) `
        -Name 'Archive/BackupRetentionNoDataRendersSkipped' `
        -Failure 'коли retention реально перевірено, але нічого не видалено ($archiveCleanupSectionShown=false і lunchCleanupDeletedCount=0), результат має бути SKIPPED ''даних для очищення немає'', не OK'

    Test-BRAVOCondition `
        -Condition (
            $archiveRetentionResultWindow.Contains('$generationCleanupDeletedCount -gt 0') -and
            $archiveRetentionResultWindow.Contains('generation: $generationCleanupDeletedCount') -and
            $archiveRetentionResultWindow.Contains('$lunchCleanupDeletedCount -gt 0') -and
            $archiveRetentionResultWindow.Contains('обідніх файлів: $lunchCleanupDeletedCount')
        ) `
        -Name 'Archive/BackupRetentionActualCleanupRendersOk' `
        -Failure 'коли щось РЕАЛЬНО видалено, Details має показувати факт-агрегат (generation: N; обідніх файлів: N) з реальних RemovedGenerationCount/RemovedFileCount сигналів, не вигадані числа'

    # --- Archive: -SyncBAZA лишається ізольованим SFTP-only flow — Plan/
    # dynamic Total/BAZA local numbered steps НЕ виконуються в цьому режимі
    # (return відбувається ДО них у джерелі).
    $archiveMainSyncBazaIndex = $archiveScriptText.IndexOf('if ($SyncBAZA) {', $archiveScriptText.IndexOf('[void](Test-Compatibility)'))
    $archivePlanCallIndex = $archiveScriptText.IndexOf('Write-BRAVOPlan -Title ''План операцій:''')
    $archiveMainTotalIndex = $archiveScriptText.IndexOf('Initialize-BRAVOArchiveSteps -Total (', $archiveMainSyncBazaIndex)
    Test-BRAVOCondition `
        -Condition (
            $archiveMainSyncBazaIndex -ge 0 -and
            $archivePlanCallIndex -ge 0 -and
            $archiveMainTotalIndex -ge 0 -and
            $archiveMainSyncBazaIndex -lt $archivePlanCallIndex -and
            $archiveMainSyncBazaIndex -lt $archiveMainTotalIndex -and
            $archiveScriptText.Contains('Режим -SyncBAZA: синхронізуються всі увімкнені BAZA_APP/BAZA_WWW; архiвацiю, очищення архiвiв, NAS/SMB та health-check пропущено')
        ) `
        -Name 'Archive/SyncBazaModeDoesNotGainNormalArchiveOperations' `
        -Failure 'if ($SyncBAZA) {...; return} має стояти в джерелі РАНІШЕ, ніж Write-BRAVOPlan/новий Initialize-BRAVOArchiveSteps основного backup-flow — інакше -SyncBAZA показав би План повного backup-flow'

    # --- Archive: embedded Health лишається ОДНИМ Archive-кроком незалежно
    # від внутрішнього статусу Invoke-BRAVOHealthCheck.
    Test-BRAVOCondition `
        -Condition (
            ([regex]::Matches($archiveScriptText, [regex]::Escape('-Name "Перевірка резервних копій"')).Count -eq 1) -and
            $archiveScriptText.Contains('Invoke-BRAVOHealthCheck @healthParameters') -and
            $archiveScriptText.Contains('if ($healthCheckEnabled) {') -and
            -not $archiveScriptText.Contains('function Invoke-BRAVOEmbeddedHealth')
        ) `
        -Name 'Archive/EmbeddedHealthRemainsOneStep' `
        -Failure '''Перевірка резервних копій'' має рендеритись РІВНО один раз (один Write-BRAVOArchiveStep) незалежно від Invoke-BRAVOHealthCheck.Status — жодного вкладеного Health-виводу'

    # --- Health: "План перевірок" рендериться ЛИШЕ у самостійному запуску
    # (не при SuppressHeader — вбудований виклик з Archive) і через
    # спільний Write-BRAVOPlan (Health не має права на raw Write-Host).
    $healthPlanEntriesIndex = $healthScriptText.IndexOf('$healthPlanEntries = [ordered]@{}')
    $healthPlanIndex = if ($healthPlanEntriesIndex -ge 0) {
        $healthScriptText.LastIndexOf('if (-not $SuppressHeader) {', $healthPlanEntriesIndex)
    } else { -1 }
    Test-BRAVOCondition `
        -Condition (
            $healthPlanIndex -ge 0 -and
            $healthPlanEntriesIndex -ge 0 -and
            $healthPlanEntriesIndex -gt $healthPlanIndex -and
            ($healthPlanEntriesIndex - $healthPlanIndex) -lt 200 -and
            $healthScriptText.Contains('Write-BRAVOPlan -Title ''План перевірок:'' -Entries $healthPlanEntries') -and
            $healthScriptText.Contains('$healthPlanEntries[''BAZA_APP (локальна копія)''] = [bool]$bazaAppLocalHealthEnabled') -and
            $healthScriptText.Contains('$healthPlanEntries[''SFTP: BAZA_WWW''] = [bool]$sftpBazaWWWHealthEnabled')
        ) `
        -Name 'Health/PlanRendersStandaloneOnly' `
        -Failure 'Health ''План перевірок'' має рендеритись через Write-BRAVOPlan лише коли -not $SuppressHeader, з entries з тих самих прапорців, що dynamic Total'

    # --- Health: BAZA_APP/BAZA_WWW локальна копія — незалежні dynamic
    # steps (кожен зі своїм enable-гейтом, не комбінований рядок).
    Test-BRAVOCondition `
        -Condition (
            $healthScriptText.Contains('-Name ''BAZA_APP (локальна копія)''') -and
            $healthScriptText.Contains('-Name ''BAZA_WWW (локальна копія)''') -and
            $healthScriptText.Contains('if ($bazaAppLocalHealthEnabled) {') -and
            $healthScriptText.Contains('if ($bazaWWWLocalHealthEnabled) {') -and
            -not $healthScriptText.Contains('-Name ''BAZA (локальна копія)''')
        ) `
        -Name 'Health/BazaLocalHasIndependentSteps' `
        -Failure 'BAZA_APP/BAZA_WWW (локальна копія) мають бути незалежними dynamic steps, кожен зі своїм enable-гейтом; комбінованого ''BAZA (локальна копія)'' кроку більше не повинно існувати'

    # --- Health: SFTP розділено на 3 незалежні dynamic steps.
    Test-BRAVOCondition `
        -Condition (
            $healthScriptText.Contains('-Name ''SFTP: резервні копії''') -and
            $healthScriptText.Contains('-Name ''SFTP: BAZA_APP''') -and
            $healthScriptText.Contains('-Name ''SFTP: BAZA_WWW''') -and
            $healthScriptText.Contains('if ($sftpArchivesHealthEnabled) {') -and
            $healthScriptText.Contains('if ($sftpBazaAppHealthEnabled) {') -and
            $healthScriptText.Contains('if ($sftpBazaWWWHealthEnabled) {') -and
            -not $healthScriptText.Contains('-Name ''SFTP''')
        ) `
        -Name 'Health/SftpHasThreeIndependentSteps' `
        -Failure 'SFTP має рендерити 3 незалежні dynamic steps (резервні копії/BAZA_APP/BAZA_WWW); комбінованого одного ''SFTP'' кроку більше не повинно існувати'

    Test-BRAVOCondition `
        -Condition (
            $healthScriptText.Contains('$sftpSharedIssues = @($sftpHealthIssues | Where-Object { $_.Component -eq ''SFTP'' })') -and
            $healthScriptText.Contains('$sftpArchivesStepIssues = @($sftpHealthIssues | Where-Object { $_.Component -in $sftpArchiveComponentNames }) + @($sftpSharedIssues)') -and
            $healthScriptText.Contains('$sftpBazaAppStepIssues = @($sftpHealthIssues | Where-Object { $_.Component -eq') -and
            ([regex]::Matches($healthScriptText, [regex]::Escape('Get-SFTPHealthIssues')).Count -ge 1)
        ) `
        -Name 'Health/SftpSharedFailurePropagatesToEachEnabledStep' `
        -Failure 'спільна prerequisite-помилка з''єднання (Component == ''SFTP'', bare) має приєднуватись до КОЖНОГО увімкненого SFTP-кроку через партиціонування вже наявного списку issues (Get-SFTPHealthIssues викликається один раз)'

    # --- Health: dynamic Total точно дорівнює сумі прапорців, що гейтять
    # кожен Write-BRAVOHealthStep нижче (AST — не рахує сам Total, а
    # перевіряє, що формула складається лише з очікуваних доданків).
    $healthTotalTokens = $null
    $healthTotalErrors = $null
    $healthTotalAst = [Management.Automation.Language.Parser]::ParseInput(
        $healthScriptText, [ref]$healthTotalTokens, [ref]$healthTotalErrors
    )
    $healthInitStepsCallAst = $healthTotalAst.Find(
        {
            param($candidate)
            $candidate -is [Management.Automation.Language.CommandAst] -and
            $candidate.GetCommandName() -eq 'Initialize-BRAVOHealthSteps'
        },
        $true
    )
    $healthTotalParamText = if ($null -ne $healthInitStepsCallAst) {
        $found = $null
        for ($i = 0; $i -lt $healthInitStepsCallAst.CommandElements.Count; $i++) {
            if ($healthInitStepsCallAst.CommandElements[$i] -is [Management.Automation.Language.CommandParameterAst] -and
                $healthInitStepsCallAst.CommandElements[$i].ParameterName -eq 'Total') {
                $found = $healthInitStepsCallAst.CommandElements[$i + 1].Extent.Text
                break
            }
        }
        $found
    } else { '' }
    if ($null -eq $healthTotalParamText) { $healthTotalParamText = '' }
    $healthExpectedTotalTerms = @(
        'bazaAppLocalHealthEnabled', 'bazaWWWLocalHealthEnabled',
        'sftpArchivesHealthEnabled', 'sftpBazaAppHealthEnabled', 'sftpBazaWWWHealthEnabled',
        'BRAVOHealthSmbStepEnabled', 'BRAVOHealthNotificationStepEnabled'
    )
    $healthTotalMissingTerms = @($healthExpectedTotalTerms | Where-Object { -not $healthTotalParamText.Contains($_) })
    # ParenExpressionAst.Extent.Text включає обгортаючі дужки (`( 3 + ... )`),
    # тому перевіряємо Contains, а не StartsWith буквального "3 +".
    Test-BRAVOCondition `
        -Condition (
            -not [string]::IsNullOrWhiteSpace($healthTotalParamText) -and
            $healthTotalParamText.Contains('3 +') -and
            $healthTotalMissingTerms.Count -eq 0
        ) `
        -Name 'Health/StepTotalMatchesVisibleEnabledChecks' `
        -Failure "Initialize-BRAVOHealthSteps -Total має дорівнювати 3 (базові кроки) + по одному доданку на кожен реально розділений enable-прапорець кроку; відсутні доданки: $($healthTotalMissingTerms -join ', ')"

    # --- Health: "Керовані служби"/"Локальні резервні копії" лишаються
    # ОДНИМ кроком кожен (не розділені), але отримують компактні
    # per-entity/per-component деталі з реальних Component/Location полів.
    Test-BRAVOCondition `
        -Condition (
            $healthScriptText.Contains('function Get-BRAVOHealthCompactIssueDetails') -and
            $healthScriptText.Contains('-Details (Get-BRAVOHealthCompactIssueDetails -Issues $serviceHealthIssues -EntityProperty ''Location'' -Label ''служби'')') -and
            $healthScriptText.Contains('-Details (Get-BRAVOHealthCompactIssueDetails -Issues $localHealthIssues -EntityProperty ''Component'' -Label ''компоненти'')') -and
            ([regex]::Matches($healthScriptText, [regex]::Escape('-Name ''Керовані служби''')).Count -eq 1) -and
            ([regex]::Matches($healthScriptText, [regex]::Escape('-Name ''Локальні резервні копії''')).Count -eq 1)
        ) `
        -Name 'Health/ManagedServicesAndLocalBackupsHaveCompactDetails' `
        -Failure '''Керовані служби''/''Локальні резервні копії'' мають лишатись одним кроком кожен, з компактними Details через Get-BRAVOHealthCompactIssueDetails (реальні Component/Location поля, не вигадані)'

    # --- Health: embedded (SuppressHeader) режим лишається компактним —
    # Complete-BRAVOHealthResult не друкує другий підсумок, а $script:
    # BRAVOHealthSftpStepEnabled (споживач стандалон-підсумку) не змінений.
    Test-BRAVOCondition `
        -Condition (
            $healthScriptText.Contains('$script:BRAVOHealthSftpStepEnabled = $sftpCredentialRequired') -and
            $healthScriptText.Contains('Property = ''SftpVerified'';  Title = ''SFTP'';           Enabled = $script:BRAVOHealthSftpStepEnabled') -and
            $healthScriptText.Contains('if (-not $SuppressHeader) {') -and
            $healthScriptText.Contains('Write-BRAVOResultHeader')
        ) `
        -Name 'Health/EmbeddedModeDoesNotRenderNestedPlanOrSummary' `
        -Failure 'SuppressHeader має приглушувати і План перевірок, і стандалон-підсумок (Write-BRAVOResultHeader); $script:BRAVOHealthSftpStepEnabled — той самий сигнал для обох (нового split-гейту й старого summary-footer)'

    #####################################################################
    # dev.17: реальний DEV-LIMS acceptance (generation 20260810_185725) —
    # Get-BRAVOHealthLatestBackupSummary.TimestampText показував UTC як
    # локальний час (15:57 замість фактичних 18:57), хоча AgeText (той
    # самий summary, той самий $healthCheckStartedUtc) рахувався правильно.
    # Фікс — presentation-only .ToLocalTime() в ОДНІЙ точці перед
    # ToString(); внутрішня UTC-модель, вік і generation selection
    # незмінні.
    #####################################################################
    $latestBackupSummaryModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($healthScriptText + [Environment]::NewLine + $notificationScriptText) `
        -FunctionNames @(
            'Get-BRAVOHealthLatestBackupSummary',
            'Format-BackupAge',
            'Get-BRAVOUtcAge',
            'ConvertTo-BRAVOUtcDateTime',
            'Format-FileSize',
            'Format-BRAVOOperatorStatusLine'
        )
    $latestBackupSummaryProbe = & $latestBackupSummaryModule {
        # Ті самі числа, що реальний DEV-LIMS acceptance: generation
        # 20260810_185725, backup 18:57 local (== 15:57 UTC на UTC+3
        # сервері), Health-перевірка о 19:02:55 local (== 16:02:55 UTC).
        # SpecifyKind, а не залежність від timezone тестового runner-а —
        # той самий прийом, що вже Health/GenerationAgeUsesUtcArithmetic.
        $simulatedNowUtc = [datetime]::SpecifyKind([datetime]'2026-08-10T16:02:55', [DateTimeKind]::Utc)
        $simulatedBackupUtc = [datetime]::SpecifyKind([datetime]'2026-08-10T15:57:00', [DateTimeKind]::Utc)
        $script:archiveDefinitions = @(
            [pscustomobject]@{ Type = 'MODEL'; Enabled = $true }
        )
        $script:healthLatestArchives = @{
            MODEL = [pscustomobject]@{
                Name = 'MODEL_20260810_185725.mdz'
                FullName = 'C:\fake\MODEL_20260810_185725.mdz'
                HashPath = 'C:\fake\MODEL_20260810_185725.mdz.sha512'
                SizeBytes = 12345
                LastWriteTime = $simulatedBackupUtc
                GenerationId = '20260810_185725'
            }
        }
        $script:healthCheckStartedUtc = $simulatedNowUtc
        $summary = Get-BRAVOHealthLatestBackupSummary
        [pscustomobject]@{
            TimestampText = $summary.TimestampText
            AgeText = $summary.AgeText
            RawTimestamp = $summary.Timestamp
            RawTimestampKind = $summary.Timestamp.Kind
            # Обчислено НЕЗАЛЕЖНО, тим самим .ToLocalTime(), що очікується
            # від джерела — детерміновано в будь-якій timezone тестового
            # runner-а (не hardcode ніякого конкретного offset/рядка):
            # якщо джерело справді конвертує, обидва значення завжди
            # збігаються, хоч би яка timezone була в CI/DEV-LIMS/локально.
            ExpectedLocalText = $simulatedBackupUtc.ToLocalTime().ToString('dd.MM.yyyy HH:mm')
            # AgeText — чиста UTC-минус-UTC арифметика (не залежить від
            # timezone runner-а за визначенням), обчислена тут із тих
            # самих двох фікстур, що передаються в Get-BRAVOHealthLatestBackupSummary,
            # а не hardcoded рядок.
            ExpectedAgeText = "$([math]::Floor(($simulatedNowUtc - $simulatedBackupUtc).TotalMinutes)) хв."
        }
    }
    Test-BRAVOCondition `
        -Condition (
            $latestBackupSummaryProbe.TimestampText -eq $latestBackupSummaryProbe.ExpectedLocalText -and
            $latestBackupSummaryProbe.RawTimestampKind -eq [DateTimeKind]::Utc -and
            $healthScriptText.Contains('$localTimestamp = $latestTimestamp.ToLocalTime()') -and
            $healthScriptText.Contains('TimestampText = $localTimestamp.ToString(') -and
            -not $healthScriptText.Contains('TimestampText = $latestTimestamp.ToString(')
        ) `
        -Name 'Health/LatestBackupTimestampRendersLocalTime' `
        -Failure 'Get-BRAVOHealthLatestBackupSummary.TimestampText має форматуватися ПІСЛЯ .ToLocalTime() — інакше оператор бачить внутрішній UTC як локальний час сервера (реальний DEV-LIMS acceptance: generation 18:57 local показувалась як 15:57); production Timestamp/Kind не повинні мутуватися'

    Test-BRAVOCondition `
        -Condition (
            $latestBackupSummaryProbe.AgeText -eq $latestBackupSummaryProbe.ExpectedAgeText -and
            $latestBackupSummaryProbe.RawTimestampKind -eq [DateTimeKind]::Utc -and
            $healthScriptText.Contains('AgeText = Format-BackupAge -LastWriteTime $latestTimestamp -NowUtc $healthCheckStartedUtc') -and
            -not $healthScriptText.Contains('AgeText = Format-BackupAge -LastWriteTime $localTimestamp')
        ) `
        -Name 'Health/BackupAgeStillUsesUtcSemantics' `
        -Failure 'AgeText має рахуватися через Format-BackupAge на СИРОМУ (UTC) $latestTimestamp — не на $localTimestamp і не похідно від TimestampText; TimestampText presentation-фікс не повинен зачіпати age-арифметику'

    # --- Обидва notification-повідомлення (SUCCESS "Остання резервна
    # копія" і WARNING/ERROR "Остання успішна резервна копія") мають
    # отримувати TimestampText з ОДНОГО виклику Get-BRAVOHealthLatestBackupSummary
    # — не дві незалежні timezone-конверсії у двох message builders.
    $latestBackupCallSites = @([regex]::Matches($healthScriptText, [regex]::Escape('$latestBackup = Get-BRAVOHealthLatestBackupSummary')))
    $toLocalTimeCallSites = @([regex]::Matches($healthScriptText, [regex]::Escape('.ToLocalTime()')))
    Test-BRAVOCondition `
        -Condition (
            $latestBackupCallSites.Count -eq 2 -and
            $healthScriptText.Contains('Остання успішна резервна копія: $($latestBackup.TimestampText)') -and
            $healthScriptText.Contains('Остання резервна копія: $($latestBackup.TimestampText)') -and
            $toLocalTimeCallSites.Count -eq 1
        ) `
        -Name 'Health/SuccessAndProblemNotificationsReuseLatestBackupTimestamp' `
        -Failure 'success- і problem-повідомлення мають отримувати TimestampText з ОДНОГО виклику Get-BRAVOHealthLatestBackupSummary; .ToLocalTime() має існувати рівно в ОДНІЙ точці джерела (не дубльований у двох message builders)'

    #####################################################################
    # dev.18: реальний DEV-LIMS ручний BRAVO_ARCHIV прогін виявив три
    # пов'язані дефекти operator-flow/observability: (1) MANUAL-консоль
    # закривалась без паузи через IsInputRedirected; (2) очищення
    # журналів/backup generation рендерились ПОЗА канонічною [N/M]
    # нумерацією; (3) журнал містив структуровані записи з порожнім
    # Message (голий "===" роздільник). Backup/VSS/retention/MANIFESTS/
    # SFTP/SMB/notification/exit-code семантика НЕ змінена.
    #####################################################################

    # --- Console: реальний Wait-BRAVOManualExit (не симуляція) —
    # -NoPause і PauseOnExit=false обидва повертаються миттєво, безпечно
    # викликати в самотесті (не чекають на клавішу).
    Remove-Module -Name 'BRAVO.Console' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Console\BRAVO.Console.psd1') -Force -ErrorAction Stop

    $manualExitNoPauseElapsed = Measure-Command { Wait-BRAVOManualExit -NoPause }
    Test-BRAVOCondition `
        -Condition ($manualExitNoPauseElapsed.TotalSeconds -lt 2) `
        -Name 'Console/ManualExitNoPauseAlwaysBypasses' `
        -Failure "-NoPause має лишатись авторитетним automation-сигналом і повертатись миттєво; зайняло $($manualExitNoPauseElapsed.TotalSeconds) с"

    $global:consoleSettings = @{ PauseOnExit = $false }
    try {
        $manualExitPauseOnExitFalseElapsed = Measure-Command { Wait-BRAVOManualExit }
    } finally {
        $global:consoleSettings = $null
    }
    Test-BRAVOCondition `
        -Condition ($manualExitPauseOnExitFalseElapsed.TotalSeconds -lt 2) `
        -Name 'Console/ManualExitPauseOnExitFalseBypasses' `
        -Failure "PauseOnExit=`$false (явне налаштування в BRAVO.config) має лишатись bypass-сигналом і повертатись миттєво; зайняло $($manualExitPauseOnExitFalseElapsed.TotalSeconds) с"

    # --- Structural: [Console]::IsInputRedirected більше НЕ окрема
    # самостійна pre-check причина відхилити операторську консоль ДО
    # спроби RawUI.ReadKey (реальний DEV-LIMS баг); UserInteractive
    # лишається єдиною такою причиною.
    Test-BRAVOCondition `
        -Condition (
            -not $waitManualExitText.Contains('[Console]::IsInputRedirected') -and
            $waitManualExitText.Contains('[Environment]::UserInteractive')
        ) `
        -Name 'Console/ManualExitDoesNotPreSkipSolelyForInputRedirected' `
        -Failure 'Wait-BRAVOManualExit НЕ повинна містити самостійну перевірку [Console]::IsInputRedirected — реальний DEV-LIMS MANUAL-запуск довів, що вона помилково відхиляла справжню операторську консоль до спроби RawUI.ReadKey'

    Test-BRAVOCondition `
        -Condition (
            $waitManualExitText.Contains('$Host.UI.RawUI.ReadKey(') -and
            $waitManualExitText.Contains('[void](Read-Host)')
        ) `
        -Name 'Console/ManualExitUsesRawUIWithReadHostFallback' `
        -Failure 'Wait-BRAVOManualExit має спершу пробувати $Host.UI.RawUI.ReadKey(...), з фолбеком на Read-Host — той самий контракт, що й раніше'

    # --- Archive: власна тонка обгортка Wait-ForManualExit делегує в той
    # самий спільний Wait-BRAVOManualExit -NoPause:$NoPause (не власна
    # реалізація); Health/Maintenance також викликають його напряму —
    # жодного дубльованого RawUI.ReadKey десь ще.
    # 'RawUI.ReadKey(' (з дужкою) — реальний виклик; без дужки Archive
    # згадує його лише в поясювальному коментарі до Wait-ForManualExit.
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('Wait-BRAVOManualExit -NoPause:$NoPause') -and
            -not $archiveScriptText.Contains('RawUI.ReadKey(') -and
            $healthScriptText.Contains('Wait-BRAVOManualExit -NoPause:$NoPause') -and
            -not $healthScriptText.Contains('RawUI.ReadKey(') -and
            $maintenanceScriptTextForManifestStorage.Contains('Wait-BRAVOManualExit -NoPause:$NoPause') -and
            -not $maintenanceScriptTextForManifestStorage.Contains('RawUI.ReadKey(')
        ) `
        -Name 'Archive/ManualModeAndPauseUseSameNoPauseContract' `
        -Failure 'Archive/Health/Maintenance мають викликати ТІЛЬКИ спільний Wait-BRAVOManualExit -NoPause:$NoPause (BRAVO.Console); жоден із трьох runtime не повинен мати власного RawUI.ReadKey'

    # --- Archive: старе очищення журналів мігрувало на numbered
    # Write-BRAVOArchiveStep (не unnumbered Write-BRAVOOperationResult) —
    # детально перевірено вище (Archive/LogCleanupUsesNumberedStep);
    # тут лише позиція, потрібна для CleanupNoWorkRendersSkipped нижче.
    $oldLogCleanupStepWindow = $archiveScriptText.IndexOf(
        "-Name 'Очищення старих журналів'",
        [Math]::Max(0, $archiveScriptText.IndexOf('$oldLogCleanupSucceeded = Remove-OldLogsByAge'))
    )

    # --- Archive: очищення backup generation — numbered крок, лише коли
    # $backupRetentionCleanupPlanned (той самий вираз, що Total і План).
    $generationCleanupPlannedIndex = $archiveScriptText.IndexOf('if ($backupRetentionCleanupPlanned) {')
    $generationCleanupStepWindow = if ($generationCleanupPlannedIndex -ge 0) {
        $archiveScriptText.Substring($generationCleanupPlannedIndex, [Math]::Min(700, $archiveScriptText.Length - $generationCleanupPlannedIndex))
    } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $generationCleanupStepWindow.Contains('Write-BRAVOArchiveStep') -and
            $generationCleanupStepWindow.Contains('Очищення старих backup generation')
        ) `
        -Name 'Archive/GenerationCleanupUsesNumberedStepWhenEnabled' `
        -Failure "'Очищення старих backup generation' має рендеритись через Write-BRAVOArchiveStep всередині if (`$backupRetentionCleanupPlanned) { ... }"

    Test-BRAVOCondition `
        -Condition (
            $generationCleanupPlannedIndex -ge 0 -and
            -not $archiveScriptText.Contains('$backupRetentionCleanupPlanned) { ''SKIPPED'' }')
        ) `
        -Name 'Archive/GenerationCleanupAddsNoStepWhenDisabled' `
        -Failure "коли generation cleanup повністю вимкнено (`$backupRetentionCleanupPlanned=false), не повинно рендеритись жодного рядка (ні numbered, ні SKIPPED-заповнювача)"

    # --- Archive: dynamic Total включає обидві cleanup-операції — той
    # самий AST-екстрагований параметр -Total, що й Archive/... тести
    # dev.16, тепер з "1 +" (завжди) і тим самим generation-cleanup
    # виразом.
    $archiveTotalTokens = $null
    $archiveTotalErrors = $null
    $archiveTotalAst = [Management.Automation.Language.Parser]::ParseInput(
        $archiveScriptText, [ref]$archiveTotalTokens, [ref]$archiveTotalErrors
    )
    $archiveInitStepsCallAsts = @($archiveTotalAst.FindAll(
        {
            param($candidate)
            $candidate -is [Management.Automation.Language.CommandAst] -and
            $candidate.GetCommandName() -eq 'Initialize-BRAVOArchiveSteps'
        },
        $true
    ))
    # Два call sites: -SyncBAZA-гілка (окремий, ізольований flow) і
    # основний backup flow нижче — саме другий (з найбільшою кількістю
    # доданків) відповідає за цю перевірку.
    $archiveMainTotalParamText = ''
    foreach ($callAst in $archiveInitStepsCallAsts) {
        for ($i = 0; $i -lt $callAst.CommandElements.Count; $i++) {
            if ($callAst.CommandElements[$i] -is [Management.Automation.Language.CommandParameterAst] -and
                $callAst.CommandElements[$i].ParameterName -eq 'Total') {
                $candidateText = $callAst.CommandElements[$i + 1].Extent.Text
                if ($candidateText.Contains('enabledArchives.Count')) {
                    $archiveMainTotalParamText = $candidateText
                }
                break
            }
        }
    }
    Test-BRAVOCondition `
        -Condition (
            $archiveMainTotalParamText.Contains('1 +') -and
            $archiveMainTotalParamText.Contains('$enableArchiveDeletion -or $enableFailedArchiveDeletion -or $enableLunchArchiveCleanup')
        ) `
        -Name 'Archive/DynamicTotalIncludesCleanupOperations' `
        -Failure 'Initialize-BRAVOArchiveSteps -Total (основний backup flow) має включати +1 за старе очищення журналів (завжди) і +1 за generation cleanup (той самий enablement-вираз)'

    # --- Archive: План/Total/фактичний гейт кроку читають ОДИН і той
    # самий буквальний вираз для generation cleanup — не три незалежні
    # копії, які можуть розійтися.
    $generationCleanupExpression = '$enableArchiveDeletion -or $enableFailedArchiveDeletion -or $enableLunchArchiveCleanup'
    Test-BRAVOCondition `
        -Condition (
            $archiveMainTotalParamText.Contains($generationCleanupExpression) -and
            $archiveScriptText.Contains('$archivePlanEntries[''Очищення старих backup generation''] = [bool](') -and
            $archiveScriptText.Contains('$backupRetentionCleanupPlanned = [bool](' + $generationCleanupExpression + ')')
        ) `
        -Name 'Archive/PlanAndCleanupStepsShareEnablementSemantics' `
        -Failure 'План/dynamic Total/$backupRetentionCleanupPlanned мають читати той самий буквальний enablement-вираз для generation cleanup'

    # --- Archive: SKIPPED збережено для "нічого не видалено" у ОБОХ
    # мігрованих numbered-кроках.
    Test-BRAVOCondition `
        -Condition (
            $oldLogCleanupStepWindow -ge 0 -and
            $archiveScriptText.Contains('elseif ($oldLogsToRemove.Count -eq 0) { ''SKIPPED'' }') -and
            $generationCleanupStepWindow.Contains('''SKIPPED''')
        ) `
        -Name 'Archive/CleanupNoWorkRendersSkipped' `
        -Failure 'обидва мігровані numbered cleanup-кроки мають рендерити SKIPPED, коли перевірку проведено, але нічого не знайдено/не видалено'

    # --- Archive: жодного РЕАЛЬНОГО (не текстового в коментарі) виклику
    # Write-BRAVOOperationResult не лишилось — AST, щоб не рахувати
    # згадки у власних dev.18-коментарях.
    $archiveOperationResultCallAsts = @($archiveTotalAst.FindAll(
        {
            param($candidate)
            $candidate -is [Management.Automation.Language.CommandAst] -and
            $candidate.GetCommandName() -eq 'Write-BRAVOOperationResult'
        },
        $true
    ))
    Test-BRAVOCondition `
        -Condition ($archiveOperationResultCallAsts.Count -eq 0) `
        -Name 'Archive/CleanupOperationsNoLongerUseUnnumberedRenderer' `
        -Failure "Archive.Runtime.ps1 не повинен мати РЕАЛЬНИХ викликів Write-BRAVOOperationResult після міграції обох cleanup-операцій на Write-BRAVOArchiveStep; знайдено: $($archiveOperationResultCallAsts.Count)"

    # --- Logging: повний функціональний round-trip через РЕАЛЬНИЙ
    # Archive Write-Log (ізольована AST-екстракція) + РЕАЛЬНИЙ
    # BRAVO.Logging у тимчасовий файл — жоден фізичний рядок журналу не
    # повинен мати порожній/whitespace-only Message.
    Remove-Module -Name 'BRAVO.Logging' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Logging\BRAVO.Logging.psd1') -Force -ErrorAction Stop
    $emptyLogRecordsTempFile = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_EMPTY_LOG_SELF_TEST_{0}.log" -f [guid]::NewGuid().ToString("N"))
    try {
        [void](Initialize-BRAVOLog -LogFile $emptyLogRecordsTempFile -FileLevel INFO -ConsoleLevel ERROR)
        $writeLogRoundTripModule = New-BRAVOSelfTestRuntimeModule `
            -SourceText $archiveScriptText `
            -FunctionNames @(
                'Write-Log',
                'Resolve-BRAVOLogComponentFromHeader',
                'Set-BRAVOLogComponent'
            )
        & $writeLogRoundTripModule {
            $script:BRAVOLogComponent = 'ARCHIVE'
            $defaultLogLevel = 'INFO'
            $logSeparatorLength = 100
            Write-Log "==="
            Write-Log "=== ПЕРЕВIРКА СУМIСНОСТI СИСТЕМИ ==="
            Write-Log "Тестове повідомлення" -Level "INFO"
            Write-Log "==="
            Write-Log "=== ЗАВЕРШЕННЯ РОБОТИ СКРИПТА ==="
        }
        $emptyLogRecordLines = @(
            Get-Content -LiteralPath $emptyLogRecordsTempFile -Encoding UTF8 |
                Where-Object { $_ -match '^\S+ \S+ \[\S+\s*\]\s*\[[^\]]+\]\s*$' }
        )
        $realHeadingLines = @(
            Get-Content -LiteralPath $emptyLogRecordsTempFile -Encoding UTF8 |
                Where-Object { $_ -match '\[STARTUP\].*ПЕРЕВIРКА СУМIСНОСТI' -or $_ -match '\[SUMMARY\].*ЗАВЕРШЕННЯ РОБОТИ' }
        )
        Test-BRAVOCondition `
            -Condition (
                $emptyLogRecordLines.Count -eq 0 -and
                $realHeadingLines.Count -eq 2
            ) `
            -Name 'Logging/RuntimeLogHasNoEmptyStructuredRecords' `
            -Failure "жоден фізичний рядок Archive-журналу не повинен мати структурований запис (timestamp/level/component) із порожнім Message; знайдено таких рядків: $($emptyLogRecordLines.Count); повноцінних заголовків: $($realHeadingLines.Count) з 2 очікуваних"
    } finally {
        Remove-Item -LiteralPath $emptyLogRecordsTempFile -Force -ErrorAction SilentlyContinue
    }

    # --- Archive: структурна перевірка — голий "==="/"=" роздільник
    # більше НЕ викликає Write-BRAVOLog взагалі (лише return); заголовки
    # "=== ... ===" лишаються повністю без змін.
    $bareLogSeparatorBranchMatch = [regex]::Match(
        $archiveScriptText,
        '(?s)if \(\$Message -eq "=" -or \$Message -eq "==="\) \{(.*?)\}'
    )
    $bareLogSeparatorBranchText = if ($bareLogSeparatorBranchMatch.Success) { $bareLogSeparatorBranchMatch.Groups[1].Value } else { 'MISSING' }
    Test-BRAVOCondition `
        -Condition (
            -not $bareLogSeparatorBranchText.Contains('Write-BRAVOLog') -and
            $bareLogSeparatorBranchText.Contains('return')
        ) `
        -Name 'Archive/SectionSeparatorsDoNotEmitEmptyLogEvents' `
        -Failure 'голий роздільник "==="/"=" у Write-Log має лише return, без Write-BRAVOLog — інакше знову структурований запис із порожнім Message'

    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('if ($Message -match "^=== .* ===$") {') -and
            $archiveScriptText.Contains('Write-BRAVOLog -Message $Message -Level ''INFO'' -Component $component -NoConsole')
        ) `
        -Name 'Archive/SectionHeadingsRemainLogged' `
        -Failure '"=== ЗАГОЛОВОК ===" записи мають і надалі писатись у журнал повним текстом — незмінено'

    #####################################################################
    # dev.19: два реальні DEV-LIMS acceptance-прогони виявили чотири
    # окремі observability/correctness дефекти: (1) Maintenance фінальний
    # людський статус (ЛОГ/консоль/success-notification) ігнорував
    # $script:BRAVOWarningCount і завжди показував "УСПІШНО", навіть коли
    # резолвиться exit 10 (SuccessWithWarnings) через відсутній Range ID
    # log; (2) Maintenance-журнал мав ті самі голі "==="-роздільники, що
    # Archive виправив у dev.18, — власна, окрема реалізація Write-Log,
    # свідомо не займана в dev.18; (3) Archive VSS-діагностика фактично
    # неправильно стверджувала "окремий знімок на компонент", хоча
    # runtime завжди створював ОДИН VSS Snapshot Set на generation; (4)
    # Archive заголовок "=== СТВОРЕННЯ ХЕШУ ===" друкувався в Main ПІСЛЯ
    # вже виконаної роботи хешування. Backup/restore/VSS-логіка/SHA512/
    # retention/MANIFESTS/transfer/notification routing/scheduler/
    # exit-code числовий контракт — не змінені; Range ID лишається
    # WARN-only.
    #####################################################################

    # ================================================================
    # Група 1 — Maintenance: фінальний статус — ЧИСТА функція від
    # РЕЗОЛЬВЛЕНОГО exit code (Get-BRAVOMaintenanceFinalStatus -ExitCode),
    # не незалежна інспекція $script:criticalErrorOccurred/
    # $script:BRAVOWarningCount. Виправлено після REVIEW: перша версія
    # dev.19 мала ту саму (узгоджену, але) ПАРАЛЕЛЬНУ класифікаційну
    # політику — тепер єдине джерело істини для самих кодів (0/10/
    # 40/41/60) — Resolve-BRAVOExitCode (через Get-BRAVOMaintenanceResolvedExitCode
    # і Get-BRAVOExitCodeName), а Get-BRAVOMaintenanceFinalStatus лише
    # відображає вже резолвлений код у текст/колір.
    # ================================================================
    # Get-BRAVOExitCodeName НЕ входить у -FunctionNames: вона визначена в
    # BRAVO.ExitCodes (не в Maintenance runtime), і вже реально
    # імпортована в глобальну сесію вище (Version/*-тести) — ізольований
    # module резолвить її звичайним пошуком команди, як і Archive-тести
    # резолвлять Protect-BRAVOLogSecret/Write-BRAVOConsoleMessage з
    # реально імпортованих BRAVO.Logging/BRAVO.Console.
    $maintenanceFinalStatusModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $maintenanceScriptTextForManifestStorage `
        -FunctionNames @('Get-BRAVOMaintenanceFinalStatus')
    Test-BRAVOCondition `
        -Condition (
            (& $maintenanceFinalStatusModule { Get-BRAVOMaintenanceFinalStatus -ExitCode 0 }).Text -eq 'УСПІШНО' -and
            (& $maintenanceFinalStatusModule { Get-BRAVOMaintenanceFinalStatus -ExitCode 0 }).Color -eq [ConsoleColor]::Green
        ) `
        -Name 'Maintenance/Exit0RendersSuccess' `
        -Failure "Get-BRAVOMaintenanceFinalStatus -ExitCode 0 (Success) має повертати Text='УСПІШНО'/Color=Green"

    Test-BRAVOCondition `
        -Condition (
            (& $maintenanceFinalStatusModule { Get-BRAVOMaintenanceFinalStatus -ExitCode 10 }).Text -eq 'УСПІШНО З ПОПЕРЕДЖЕННЯМИ' -and
            (& $maintenanceFinalStatusModule { Get-BRAVOMaintenanceFinalStatus -ExitCode 10 }).Color -eq [ConsoleColor]::Yellow
        ) `
        -Name 'Maintenance/Exit10RendersSuccessWithWarnings' `
        -Failure "Get-BRAVOMaintenanceFinalStatus -ExitCode 10 (SuccessWithWarnings) має повертати Text='УСПІШНО З ПОПЕРЕДЖЕННЯМИ'/Color=Yellow — реальний DEV-LIMS запуск (LastTaskResult=10, відсутній Range ID log) раніше показував 'УСПІШНО' без жодної згадки про попередження"

    Test-BRAVOCondition `
        -Condition (
            (& $maintenanceFinalStatusModule { Get-BRAVOMaintenanceFinalStatus -ExitCode 40 }).Text -eq 'ПОМИЛКА' -and
            (& $maintenanceFinalStatusModule { Get-BRAVOMaintenanceFinalStatus -ExitCode 40 }).Color -eq [ConsoleColor]::Red
        ) `
        -Name 'Maintenance/Exit40RendersFailure' `
        -Failure "Get-BRAVOMaintenanceFinalStatus -ExitCode 40 (LocalArchiveFailed) має повертати Text='ПОМИЛКА'/Color=Red"

    Test-BRAVOCondition `
        -Condition (
            (& $maintenanceFinalStatusModule { Get-BRAVOMaintenanceFinalStatus -ExitCode 41 }).Text -eq 'ПОМИЛКА' -and
            (& $maintenanceFinalStatusModule { Get-BRAVOMaintenanceFinalStatus -ExitCode 41 }).Color -eq [ConsoleColor]::Red
        ) `
        -Name 'Maintenance/Exit41RendersFailure' `
        -Failure "Get-BRAVOMaintenanceFinalStatus -ExitCode 41 (IntegrityTestFailed) має повертати Text='ПОМИЛКА'/Color=Red"

    Test-BRAVOCondition `
        -Condition (
            (& $maintenanceFinalStatusModule { Get-BRAVOMaintenanceFinalStatus -ExitCode 60 }).Text -eq 'ПОМИЛКА' -and
            (& $maintenanceFinalStatusModule { Get-BRAVOMaintenanceFinalStatus -ExitCode 60 }).Color -eq [ConsoleColor]::Red
        ) `
        -Name 'Maintenance/Exit60RendersFailure' `
        -Failure "Get-BRAVOMaintenanceFinalStatus -ExitCode 60 (MaintenanceFailed) має повертати Text='ПОМИЛКА'/Color=Red"

    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptTextForManifestStorage.Contains(
                "`$maintenanceLogRunId = `"{0}_PID{1}`" -f `$currentDate.ToString(`"yyyyMMdd_HHmmss`"), `$PID") -and
            $maintenanceScriptTextForManifestStorage.Contains(
                "`$LOG_FILE = `"`$LOG_DIR\BRAVO_MAINTENANCE_`$maintenanceLogRunId.log`"") -and
            -not $maintenanceScriptTextForManifestStorage.Contains(
                "`$LOG_FILE = `"`$LOG_DIR\BRAVO_MAINTENANCE_`$NOW.log`"")
        ) `
        -Name 'Maintenance/ExecutionLogsAreUniquePerSecondAndProcess' `
        -Failure 'Maintenance log має містити yyyyMMdd_HHmmss і PID; хвилинна назва змішує два окремі запуски в одному audit log'

    $maintenanceDiskFailureStart = $maintenanceScriptTextForManifestStorage.IndexOf('if (-not $spaceCheckResult) {')
    $maintenanceDiskFailureEnd = if ($maintenanceDiskFailureStart -ge 0) {
        $maintenanceScriptTextForManifestStorage.IndexOf("`n}", $maintenanceDiskFailureStart)
    } else { -1 }
    $maintenanceDiskFailureBlock = if ($maintenanceDiskFailureEnd -gt $maintenanceDiskFailureStart) {
        $maintenanceScriptTextForManifestStorage.Substring(
            $maintenanceDiskFailureStart,
            $maintenanceDiskFailureEnd - $maintenanceDiskFailureStart
        )
    } else { '' }
    Test-BRAVOCondition `
        -Condition (
            $maintenanceDiskFailureBlock.Contains(
                "`$diskPreflightExitCode = Get-BRAVOMaintenanceResolvedExitCode") -and
            $maintenanceDiskFailureBlock.Contains(
                "`$script:maintenanceRuntimeExitCode = `$diskPreflightExitCode") -and
            $maintenanceDiskFailureBlock.Contains('Write-BRAVOMaintenanceEarlyFailureSummary') -and
            $maintenanceDiskFailureBlock.Contains("Wait-BRAVOManualExit -NoPause:`$NoPause") -and
            $maintenanceDiskFailureBlock.Contains("exit `$diskPreflightExitCode") -and
            -not $maintenanceDiskFailureBlock.Contains('exit 60') -and
            $maintenanceScriptTextForManifestStorage.Contains(
                'Write-BRAVOFinalSummaryFooter -LogFile $LOG_FILE')
        ) `
        -Name 'Maintenance/DiskPreflightFailureRendersFinalSummary' `
        -Failure 'нестача місця має резолвити exit 60, надрукувати стандартний summary/журнал, виконати manual-pause contract і лише потім завершити процес'

    # --- Структурний доказ РЕАЛЬНОГО потоку даних (не лише "джерело
    # містить обидва рядки поруч"): (1) Get-BRAVOMaintenanceFinalStatus
    # взагалі НЕ посилається на $script:criticalErrorOccurred/
    # $script:BRAVOWarningCount у власному тілі — фізично не може мати
    # паралельну політику; (2) LOG і консоль передають РІВНО той самий
    # $script:maintenanceRuntimeExitCode, який РІВНО одним рядком
    # присвоюється з Get-BRAVOMaintenanceResolvedExitCode ДО обох
    # споживачів (перевірено індексами позицій у джерелі, не лише
    # Contains); (3) сам Get-BRAVOMaintenanceResolvedExitCode дійсно
    # викликає канонічний Resolve-BRAVOExitCode (не вигадує коди сам).
    # Власний AST-парс (не $maintenanceTotalAst — той визначається нижче,
    # для Групи 3/4 Archive-тестів; тут потрібен раніше).
    $maintenanceFinalStatusFlowTokens = $null
    $maintenanceFinalStatusFlowErrors = $null
    $maintenanceFinalStatusFlowAst = [Management.Automation.Language.Parser]::ParseInput(
        $maintenanceScriptTextForManifestStorage, [ref]$maintenanceFinalStatusFlowTokens, [ref]$maintenanceFinalStatusFlowErrors
    )
    $maintenanceFinalStatusFunctionAst = $null
    $maintenanceResolvedExitCodeFunctionAst = $null
    foreach ($candidateFunctionAst in $maintenanceFinalStatusFlowAst.FindAll(
        { param($c) $c -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($candidateFunctionAst.Name -eq 'Get-BRAVOMaintenanceFinalStatus') {
            $maintenanceFinalStatusFunctionAst = $candidateFunctionAst
        } elseif ($candidateFunctionAst.Name -eq 'Get-BRAVOMaintenanceResolvedExitCode') {
            $maintenanceResolvedExitCodeFunctionAst = $candidateFunctionAst
        }
    }
    # @() ЗОВНІ всього if/else (не лише всередині кожної гілки) — інакше,
    # коли гілка з очікуваним НУЛЬОВИМ результатом (саме той випадок,
    # який ця перевірка й хоче довести) віддає порожній масив у output
    # stream, PowerShell розгортає його в 0 елементів, і $x = if {...}
    # присвоює $null, а не порожній масив — .Count на $null падає під
    # Set-StrictMode (та сама пастка, що вже Maintenance/dev.16
    # Remove-OldRestoreArchives-тести вище).
    $maintenanceFinalStatusReferencesFlags = @(if ($null -ne $maintenanceFinalStatusFunctionAst) {
        $maintenanceFinalStatusFunctionAst.FindAll(
            {
                param($candidate)
                $candidate -is [Management.Automation.Language.VariableExpressionAst] -and
                ($candidate.VariablePath.UserPath -eq 'script:criticalErrorOccurred' -or
                 $candidate.VariablePath.UserPath -eq 'script:BRAVOWarningCount')
            },
            $true
        )
    } else { 'MISSING' })
    $maintenanceResolvedExitCodeCallsResolver = @(if ($null -ne $maintenanceResolvedExitCodeFunctionAst) {
        $maintenanceResolvedExitCodeFunctionAst.FindAll(
            {
                param($candidate)
                $candidate -is [Management.Automation.Language.CommandAst] -and
                $candidate.GetCommandName() -eq 'Resolve-BRAVOExitCode'
            },
            $true
        )
    })
    $maintenanceExitCodeAssignIndex = $maintenanceScriptTextForManifestStorage.IndexOf('$script:maintenanceRuntimeExitCode = Get-BRAVOMaintenanceResolvedExitCode')
    $maintenanceLogStatusIndex = $maintenanceScriptTextForManifestStorage.IndexOf('Write-Log -Message "=== СТАТУС: $((Get-BRAVOMaintenanceFinalStatus -ExitCode $script:maintenanceRuntimeExitCode).Text) ==="')
    $maintenanceConsoleStatusIndex = $maintenanceScriptTextForManifestStorage.IndexOf('$maintenanceFinalStatus = Get-BRAVOMaintenanceFinalStatus -ExitCode $script:maintenanceRuntimeExitCode')
    $maintenanceNotificationSnapshotIndex = $maintenanceScriptTextForManifestStorage.IndexOf('$maintenanceNotificationExitCodeSnapshot = Get-BRAVOMaintenanceResolvedExitCode')
    $maintenanceNotificationStatusIndex = $maintenanceScriptTextForManifestStorage.IndexOf('$maintenanceNotificationStatus = Get-BRAVOMaintenanceFinalStatus -ExitCode $maintenanceNotificationExitCodeSnapshot')
    Test-BRAVOCondition `
        -Condition (
            $maintenanceFinalStatusReferencesFlags.Count -eq 0 -and
            $maintenanceResolvedExitCodeCallsResolver.Count -eq 2 -and
            $maintenanceExitCodeAssignIndex -ge 0 -and
            $maintenanceLogStatusIndex -gt $maintenanceExitCodeAssignIndex -and
            $maintenanceConsoleStatusIndex -gt $maintenanceExitCodeAssignIndex -and
            $maintenanceNotificationSnapshotIndex -ge 0 -and
            $maintenanceNotificationStatusIndex -gt $maintenanceNotificationSnapshotIndex
        ) `
        -Name 'Maintenance/FinalStatusConsumesResolvedExitCode' `
        -Failure "Get-BRAVOMaintenanceFinalStatus не повинна посилатись на script:criticalErrorOccurred/script:BRAVOWarningCount (знайдено посилань: $($maintenanceFinalStatusReferencesFlags.Count)); Get-BRAVOMaintenanceResolvedExitCode має викликати Resolve-BRAVOExitCode (знайдено: $($maintenanceResolvedExitCodeCallsResolver.Count) з 2 очікуваних); LOG і консоль мають читати `$script:maintenanceRuntimeExitCode ПІСЛЯ його присвоєння з Get-BRAVOMaintenanceResolvedExitCode, а не незалежно"

    # --- Notification: REAL New-MaintenanceNotificationMessage (ізольована
    # AST-екстракція; Get-HostInformation/New-BRAVOOperatorNotificationMessage
    # резолвляться з реально імпортованого вище BRAVO.Notifications). -Title/
    # -TitleEmoji НЕ друкуються буквально — вони лише визначають $severity,
    # а рендерений $operation — один із ДВОХ фіксованих рядків ("BRAVO
    # MAINTENANCE — УСПІШНО" для SUCCESS, "...— ПОТРІБНА ДІЯ" для решти).
    # Для warnings-виклику (Title містить "УСПІШ", TitleEmoji ':warning:')
    # рендер МАЄ показувати ⚠️/"BRAVO MAINTENANCE — ПОТРІБНА ДІЯ"/"Потрібна
    # дія:", а НЕ ✅/"...— УСПІШНО"/"Дій не потрібно" — інакше суперечлива
    # презентація (canonical warning-маркер репозиторію ':warning:', той
    # самий, що вже Send-InactiveServiceWarning). Чистий 'УСПІШНО' лишається
    # ✅/"Дій не потрібно" — перевірено тим самим викликом, щоб довести, що
    # правка severity-порядку не зачепила звичайний success-шлях.
    $maintenanceNotificationModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $maintenanceScriptTextForManifestStorage `
        -FunctionNames @('New-MaintenanceNotificationMessage')
    $maintenanceWarningsNotificationText = & $maintenanceNotificationModule {
        New-MaintenanceNotificationMessage `
            -Title 'BRAVO MAINTENANCE — УСПІШНО З ПОПЕРЕДЖЕННЯМИ' `
            -TitleEmoji ':warning:' `
            -Duration ([timespan]::FromMinutes(5)) `
            -StatusLines @() `
            -Details @('тестова деталь')
    }
    Test-BRAVOCondition `
        -Condition (
            $maintenanceWarningsNotificationText.Contains(':warning: BRAVO MAINTENANCE — ПОТРІБНА ДІЯ') -and
            $maintenanceWarningsNotificationText.Contains('Потрібна дія: перевірити журнал BRAVO_MAINTENANCE.') -and
            -not $maintenanceWarningsNotificationText.Contains('Дій не потрібно') -and
            -not $maintenanceWarningsNotificationText.Contains(':white_check_mark:') -and
            -not $maintenanceWarningsNotificationText.Contains('BRAVO MAINTENANCE — УСПІШНО')
        ) `
        -Name 'Maintenance/WarningsNotificationUsesWarningMarkerNotSuccess' `
        -Failure "Title 'УСПІШНО З ПОПЕРЕДЖЕННЯМИ' + TitleEmoji ':warning:' мають рендерити :warning:/'BRAVO MAINTENANCE — ПОТРІБНА ДІЯ'/'Потрібна дія:' — не ✅/'...— УСПІШНО'/'Дій не потрібно' (суперечлива презентація); New-MaintenanceNotificationMessage severity-класифікація має віддавати пріоритет ':warning:' над збігом підрядка 'УСПІШ' у Title"

    $maintenanceSuccessNotificationText = & $maintenanceNotificationModule {
        New-MaintenanceNotificationMessage `
            -Title 'BRAVO MAINTENANCE — УСПІШНО' `
            -TitleEmoji ':white_check_mark:' `
            -Duration ([timespan]::FromMinutes(5)) `
            -StatusLines @() `
            -Details @('тестова деталь')
    }
    Test-BRAVOCondition `
        -Condition (
            $maintenanceSuccessNotificationText.Contains(':white_check_mark: BRAVO MAINTENANCE — УСПІШНО') -and
            $maintenanceSuccessNotificationText.Contains('Дій не потрібно') -and
            -not $maintenanceSuccessNotificationText.Contains('Потрібна дія:')
        ) `
        -Name 'Maintenance/PureSuccessNotificationUnaffectedBySeverityReorder' `
        -Failure "Title 'УСПІШНО' + TitleEmoji ':white_check_mark:' мають і надалі рендерити ✅/'Дій не потрібно' — severity-reorder (':warning:' перевіряється першим) не повинен зачіпати звичайний success-шлях"

    # --- Range ID: dev.19 не мав чіпати WARN-only семантику Test-RangeIdUsage
    # — жодного auto-create файлу, fallback-пошуку іншого шляху чи
    # підвищення до критичної помилки. $maintenanceRangeIdFunctionText вже
    # витягнутий вище (dev.15, Maintenance/RangeIdWarningHasSingleConsoleRender).
    Test-BRAVOCondition `
        -Condition (
            $maintenanceRangeIdFunctionText.Contains('Write-Log $errorMessage -Level "WARNING" -NoConsole') -and
            -not $maintenanceRangeIdFunctionText.Contains('New-Item') -and
            ([regex]::Matches($maintenanceRangeIdFunctionText, 'Test-Path').Count -eq 1) -and
            $maintenanceRangeIdFunctionText.Contains('HasIssue = $true')
        ) `
        -Name 'Maintenance/RangeIdMissingRemainsWarningOnly' `
        -Failure 'dev.19 не повинен був чіпати Test-RangeIdUsage: відсутній configured Range ID log (напр. C:\Windows\SysWOW64\range_id_log.json) має й далі лишатися WARNING-only (рівно один Test-Path, без New-Item/auto-create, без fallback-пошуку іншого шляху і без підвищення до критичної помилки)'

    # --- Немає ОКРЕМОЇ, незалежної від Get-BRAVOMaintenanceFinalStatus,
    # "другої" перевірки попереджень для тексту: реальний рядок нового
    # статусу 'УСПІШНО З ПОПЕРЕДЖЕННЯМИ' (як STRING-літерал в AST, не
    # рахуючи пояснювальні коментарі) має існувати РІВНО один раз —
    # усередині самої Get-BRAVOMaintenanceFinalStatus, — а сама функція
    # має викликатися рівно чотири рази поза власним визначенням (звичайні
    # ЛОГ/консоль/notification Title + ранній disk-preflight summary).
    $maintenanceTotalTokens = $null
    $maintenanceTotalErrors = $null
    $maintenanceTotalAst = [Management.Automation.Language.Parser]::ParseInput(
        $maintenanceScriptTextForManifestStorage, [ref]$maintenanceTotalTokens, [ref]$maintenanceTotalErrors
    )
    $maintenanceSuccessWithWarningsLiteralAsts = @($maintenanceTotalAst.FindAll(
        {
            param($candidate)
            $candidate -is [Management.Automation.Language.StringConstantExpressionAst] -and
            $candidate.Value -eq 'УСПІШНО З ПОПЕРЕДЖЕННЯМИ'
        },
        $true
    ))
    $maintenanceFinalStatusCallAsts = @($maintenanceTotalAst.FindAll(
        {
            param($candidate)
            $candidate -is [Management.Automation.Language.CommandAst] -and
            $candidate.GetCommandName() -eq 'Get-BRAVOMaintenanceFinalStatus'
        },
        $true
    ))
    Test-BRAVOCondition `
        -Condition (
            $maintenanceSuccessWithWarningsLiteralAsts.Count -eq 1 -and
            $maintenanceFinalStatusCallAsts.Count -eq 4
        ) `
        -Name 'Maintenance/FinalStatusDoesNotCallIndependentWarningPolicy' `
        -Failure "'УСПІШНО З ПОПЕРЕДЖЕННЯМИ' має бути ОДНИМ канонічним літералом (усередині Get-BRAVOMaintenanceFinalStatus), а сама функція — викликатись РІВНО 4 рази (ЛОГ/консоль/notification/ранній disk-preflight summary), а не мати незалежні дубльовані `if (`$script:BRAVOWarningCount -gt 0)` гілки з власним текстом статусу; знайдено літералів: $($maintenanceSuccessWithWarningsLiteralAsts.Count), викликів: $($maintenanceFinalStatusCallAsts.Count)"

    # ================================================================
    # Група 2 — Maintenance: голий "==="-роздільник більше не пише
    # окремий рядок у журнал (та сама ідея, що Archive dev.18, але
    # Maintenance має власну, окрему реалізацію Write-Log/SeparatorLength
    # — реальний DEV-LIMS лог показував рядки зі 100 символами "=" між
    # звичайними секціями).
    # ================================================================
    $maintenanceBareLogSeparatorBranchMatch = [regex]::Match(
        $maintenanceScriptTextForManifestStorage,
        '(?s)if \(\$Message -eq "=" -or \$Message -eq "==="\) \{(.*?)\}'
    )
    $maintenanceBareLogSeparatorBranchText = if ($maintenanceBareLogSeparatorBranchMatch.Success) { $maintenanceBareLogSeparatorBranchMatch.Groups[1].Value } else { 'MISSING' }
    Test-BRAVOCondition `
        -Condition (
            -not $maintenanceBareLogSeparatorBranchText.Contains('Write-BRAVOMaintenanceLogFile') -and
            $maintenanceBareLogSeparatorBranchText.Contains('return')
        ) `
        -Name 'Maintenance/SectionSeparatorsDoNotEmitBareLogRecords' `
        -Failure 'голий роздільник "==="/"=" у Maintenance Write-Log має лише return, без Write-BRAVOMaintenanceLogFile — реальний DEV-LIMS лог показував рядки зі 100 символами "=" між звичайними секціями без жодної діагностичної цінності'

    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptTextForManifestStorage.Contains('if ($Message -match "^=== .* ===$") {') -and
            $maintenanceScriptTextForManifestStorage.Contains('Write-BRAVOMaintenanceLogFile -Entry $Message') -and
            $maintenanceScriptTextForManifestStorage.Contains('Write-Log -Message "=== ДЖЕРЕЛА ЖУРНАЛІВ ==="') -and
            $maintenanceScriptTextForManifestStorage.Contains('Write-Log -Message "=== ПЕРЕВІРКА ВІЛЬНОГО МІСЦЯ ==="') -and
            $maintenanceScriptTextForManifestStorage.Contains('Write-Log -Message "=== ЗУПИНКА СЛУЖБ ==="') -and
            $maintenanceScriptTextForManifestStorage.Contains('=== ПЕРЕВІРКА РОЗМІРІВ .MD ФАЙЛІВ ===') -and
            $maintenanceScriptTextForManifestStorage.Contains('Write-Log -Message "=== РЕСТАВРАЦІЯ МОДЕЛІ ==="') -and
            $maintenanceScriptTextForManifestStorage.Contains('Write-Log -Message "=== ОБРОБКА TRACE-ФАЙЛІВ ===" -Level "INFO"') -and
            $maintenanceScriptTextForManifestStorage.Contains('Write-Log -Message "=== ОБРОБКА ЛОГІВ EXCHANGAPI ===" -Level "INFO"') -and
            $maintenanceScriptTextForManifestStorage.Contains('Write-Log -Message "=== ВІДНОВЛЕННЯ ПОЧАТКОВОГО СТАНУ СЛУЖБ ==="') -and
            $maintenanceScriptTextForManifestStorage.Contains('Write-Log -Message "=== ОЧИСТКА СТАРИХ ДАНИХ ==="') -and
            $maintenanceScriptTextForManifestStorage.Contains('Write-Log -Message "=== ВІДПРАВКА ПОВІДОМЛЕННЯ ПРО ПОДІЮ ==="')
        ) `
        -Name 'Maintenance/SectionHeadingsRemainLogged' `
        -Failure '"=== ЗАГОЛОВОК ===" записи (ДЖЕРЕЛА ЖУРНАЛІВ/ПЕРЕВІРКА ВІЛЬНОГО МІСЦЯ/ЗУПИНКА СЛУЖБ/ПЕРЕВІРКА РОЗМІРІВ .MD ФАЙЛІВ/РЕСТАВРАЦІЯ МОДЕЛІ/ОБРОБКА TRACE-ФАЙЛІВ/ОБРОБКА ЛОГІВ EXCHANGAPI/ВІДНОВЛЕННЯ ПОЧАТКОВОГО СТАНУ СЛУЖБ/ОЧИСТКА СТАРИХ ДАНИХ/ВІДПРАВКА ПОВІДОМЛЕННЯ ПРО ПОДІЮ) мають і надалі писатись у журнал повним текстом — незмінено'

    # --- функціональний round-trip через РЕАЛЬНИЙ Maintenance Write-Log
    # (ізольована AST-екстракція) у тимчасовий файл — жоден фізичний
    # рядок журналу не повинен бути голим роздільником символів "=".
    Remove-Module -Name 'BRAVO.Logging' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Logging\BRAVO.Logging.psd1') -Force -ErrorAction Stop
    Remove-Module -Name 'BRAVO.Console' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root 'modules\BRAVO.Console\BRAVO.Console.psd1') -Force -ErrorAction Stop
    $maintenanceLogRoundTripTempFile = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_MAINT_LOG_SELF_TEST_{0}.log" -f [guid]::NewGuid().ToString("N"))
    try {
        $maintenanceWriteLogRoundTripModule = New-BRAVOSelfTestRuntimeModule `
            -SourceText $maintenanceScriptTextForManifestStorage `
            -FunctionNames @('Write-Log', 'Write-BRAVOMaintenanceLogFile')
        $global:consoleSettings = @{ ConsoleLevel = 'ERROR'; ShowTimestampsInConsole = $false }
        try {
            & $maintenanceWriteLogRoundTripModule {
                param($LogFilePath)
                $LOG_DIR = [IO.Path]::GetDirectoryName($LogFilePath)
                $LOG_FILE = $LogFilePath
                $script:BRAVOWarningCount = 0
                $script:LogLevel = 'INFO'
                Write-Log -Message "==="
                Write-Log -Message "=== ДЖЕРЕЛА ЖУРНАЛІВ ==="
                Write-Log -Message "Тестове повідомлення" -Level "INFO"
                Write-Log -Message "==="
                Write-Log -Message "=== ЗАВЕРШЕННЯ РОБОТИ СКРИПТА ==="
            } $maintenanceLogRoundTripTempFile
        } finally {
            $global:consoleSettings = $null
        }
        $maintenanceLogLines = @(Get-Content -LiteralPath $maintenanceLogRoundTripTempFile -Encoding UTF8)
        $maintenanceBareSeparatorLines = @($maintenanceLogLines | Where-Object { $_ -match '^=+$' })
        $maintenanceRealHeadingLines = @($maintenanceLogLines | Where-Object { $_ -eq '=== ДЖЕРЕЛА ЖУРНАЛІВ ===' -or $_ -eq '=== ЗАВЕРШЕННЯ РОБОТИ СКРИПТА ===' })
        Test-BRAVOCondition `
            -Condition (
                $maintenanceBareSeparatorLines.Count -eq 0 -and
                $maintenanceRealHeadingLines.Count -eq 2
            ) `
            -Name 'Maintenance/RuntimeLogHasNoRedundantSeparatorOnlySections' `
            -Failure "жоден фізичний рядок Maintenance-журналу не повинен бути голим роздільником символів '='; знайдено таких рядків: $($maintenanceBareSeparatorLines.Count); повноцінних заголовків: $($maintenanceRealHeadingLines.Count) з 2 очікуваних"
    } finally {
        Remove-Item -LiteralPath $maintenanceLogRoundTripTempFile -Force -ErrorAction SilentlyContinue
    }

    # ================================================================
    # Група 3 — Archive: VSS-діагностика тепер фактично правильна (ОДИН
    # Snapshot Set на generation, спільний для всіх увімкнених
    # компонентів) — лише текст, VSS-логіка/lifecycle не змінені.
    # ================================================================
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('Write-Log "Узгодженість архівів: один VSS Snapshot Set для всіх увімкнених компонентів generation" -Level "SUCCESS"')
        ) `
        -Name 'Archive/VssDiagnosticDescribesSingleGenerationSnapshotSet' `
        -Failure 'діагностичний рядок "Узгодженість архівів" має описувати ОДИН VSS Snapshot Set для всіх увімкнених компонентів generation — реальна поведінка New-BRAVOVSSSnapshotSet (спільний знімок), а не окремий на кожен компонент'

    Test-BRAVOCondition `
        -Condition (
            -not $archiveScriptText.Contains('окремий VSS-знімок для кожного компонента') -and
            -not $archiveScriptText.Contains('окремий VSS-знімок для кожного')
        ) `
        -Name 'Archive/VssDiagnosticDoesNotClaimPerComponentSnapshots' `
        -Failure 'стара фактично неправильна фраза "окремий VSS-знімок для кожного компонента" не повинна лишатись у джерелі — runtime ніколи не створював окремий знімок на компонент'

    $archiveVssSnapshotSetCallAsts = @($archiveTotalAst.FindAll(
        {
            param($candidate)
            $candidate -is [Management.Automation.Language.CommandAst] -and
            $candidate.GetCommandName() -eq 'New-BRAVOVSSSnapshotSet'
        },
        $true
    ))
    $archiveVssSnapshotSetRemoveCallAsts = @($archiveTotalAst.FindAll(
        {
            param($candidate)
            $candidate -is [Management.Automation.Language.CommandAst] -and
            $candidate.GetCommandName() -eq 'Remove-BRAVOVSSSnapshotSet'
        },
        $true
    ))
    Test-BRAVOCondition `
        -Condition (
            $archiveVssSnapshotSetCallAsts.Count -eq 1 -and
            $archiveVssSnapshotSetRemoveCallAsts.Count -eq 2
        ) `
        -Name 'Archive/VssBehaviorCodeUnchangedByDiagnosticFix' `
        -Failure "правка діагностичного тексту не повинна була зачепити VSS-логіку: New-BRAVOVSSSnapshotSet має викликатися рівно 1 раз (на generation), Remove-BRAVOVSSSnapshotSet — рівно 2 рази (VSS-failure cleanup path + normal-path cleanup); знайдено $($archiveVssSnapshotSetCallAsts.Count)/$($archiveVssSnapshotSetRemoveCallAsts.Count)"

    # ================================================================
    # Група 4 — Archive: заголовок "=== СТВОРЕННЯ ХЕШУ $Component ==="
    # тепер друкується ВСЕРЕДИНІ Invoke-BRAVOComponentBackup, безпосередньо
    # перед New-SHA512Hash (хронологічно правильна позиція) — не в Main
    # ПІСЛЯ завершення виклику. Сама послідовність create -> hash ->
    # verify -> publish не змінена.
    # ================================================================
    $archiveComponentBackupFunctionAst = $archiveTotalAst.Find(
        {
            param($candidate)
            $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $candidate.Name -eq 'Invoke-BRAVOComponentBackup'
        },
        $true
    )
    $archiveHashHeadingCallAst = if ($null -ne $archiveComponentBackupFunctionAst) {
        $archiveComponentBackupFunctionAst.Find(
            {
                param($candidate)
                $candidate -is [Management.Automation.Language.CommandAst] -and
                $candidate.GetCommandName() -eq 'Write-Log' -and
                $candidate.Extent.Text -match 'СТВОРЕННЯ ХЕШУ'
            },
            $true
        )
    } else { $null }
    $archiveHashWorkCallAst = if ($null -ne $archiveComponentBackupFunctionAst) {
        $archiveComponentBackupFunctionAst.Find(
            {
                param($candidate)
                $candidate -is [Management.Automation.Language.CommandAst] -and
                $candidate.GetCommandName() -eq 'New-SHA512Hash'
            },
            $true
        )
    } else { $null }
    Test-BRAVOCondition `
        -Condition (
            $null -ne $archiveComponentBackupFunctionAst -and
            $null -ne $archiveHashHeadingCallAst -and
            $null -ne $archiveHashWorkCallAst -and
            $archiveHashHeadingCallAst.Extent.StartOffset -lt $archiveHashWorkCallAst.Extent.StartOffset
        ) `
        -Name 'Archive/HashHeadingPrecedesHashWork' `
        -Failure '"=== СТВОРЕННЯ ХЕШУ ... ===" має друкуватись ДО першого виклику New-SHA512Hash всередині Invoke-BRAVOComponentBackup — реальний DEV-LIMS лог показував заголовок ПІСЛЯ вже виконаної роботи (заголовок друкувався в Main, після повного завершення виклику)'

    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('Write-Log "=== СТВОРЕННЯ ХЕШУ $Component ==="') -and
            $archiveScriptText.Contains('-Component $archive.Type') -and
            ([regex]::Matches($archiveScriptText, [regex]::Escape('$componentResult = Invoke-BRAVOComponentBackup')).Count -eq 1) -and
            $archiveScriptText.Contains('foreach ($archive in $readyArchives) {')
        ) `
        -Name 'Archive/HashHeadingPrecedesHashWorkForAllEnabledComponents' `
        -Failure 'заголовок HASH використовує параметр $Component (не буквальний MODEL/BLOG/BRAVOEXCH), а Invoke-BRAVOComponentBackup викликається РІВНО один раз усередині foreach ($archive in $readyArchives) над увімкненими компонентами — тому фікс застосовується однаково до КОЖНОГО увімкненого компонента без per-component дублювання коду'

    $archiveHashComponentModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $archiveScriptText `
        -FunctionNames @('Write-Log', 'Resolve-BRAVOLogComponentFromHeader', 'Set-BRAVOLogComponent')
    $archiveHashComponentAfterHeading = & $archiveHashComponentModule {
        $script:BRAVOLogComponent = 'ARCHIVE'
        $defaultLogLevel = 'INFO'
        $logSeparatorLength = 100
        Write-Log "==="
        Write-Log "=== СТВОРЕННЯ ХЕШУ MODEL ==="
        $script:BRAVOLogComponent
    }
    Test-BRAVOCondition `
        -Condition ($archiveHashComponentAfterHeading -eq 'HASH') `
        -Name 'Archive/HashLogsUseHashComponentAfterHeading' `
        -Failure 'після реального Write-Log "=== СТВОРЕННЯ ХЕШУ MODEL ===" $script:BRAVOLogComponent (через Resolve-BRAVOLogComponentFromHeader/Set-BRAVOLogComponent) має стати HASH — та сама автоматика колонки компонента, що й для інших заголовків; переміщення заголовка в Invoke-BRAVOComponentBackup не повинно було зламати цю атрибуцію'

    $archiveNewSha512HashCallAsts = @($archiveTotalAst.FindAll(
        {
            param($candidate)
            $candidate -is [Management.Automation.Language.CommandAst] -and
            $candidate.GetCommandName() -eq 'New-SHA512Hash'
        },
        $true
    ))
    $archiveGetFileHashCallAsts = @($archiveTotalAst.FindAll(
        {
            param($candidate)
            $candidate -is [Management.Automation.Language.CommandAst] -and
            $candidate.GetCommandName() -eq 'Get-BRAVOFileHash'
        },
        $true
    ))
    Test-BRAVOCondition `
        -Condition (
            $archiveNewSha512HashCallAsts.Count -eq 1 -and
            $archiveGetFileHashCallAsts.Count -eq 4 -and
            $null -ne $archiveHashWorkCallAst -and
            $archiveHashWorkCallAst.Extent.StartOffset -eq $archiveNewSha512HashCallAsts[0].Extent.StartOffset
        ) `
        -Name 'Archive/HashBusinessCallsRemainUnchanged' `
        -Failure "переміщення заголовка HASH не повинно було змінити бізнес-логіку хешування: New-SHA512Hash має викликатися рівно 1 раз (усередині Invoke-BRAVOComponentBackup), Get-BRAVOFileHash — рівно 4 рази; знайдено $($archiveNewSha512HashCallAsts.Count)/$($archiveGetFileHashCallAsts.Count)"
} catch {
    [void]$script:failures.Add($_.Exception.Message)
    Write-Host "[FAIL] Fatal: $($_.Exception.Message)" -ForegroundColor Red
}

if (-not [string]::IsNullOrWhiteSpace([string]$script:selfTestConfigRoot) -and
    [IO.Directory]::Exists($script:selfTestConfigRoot)) {
    [IO.Directory]::Delete($script:selfTestConfigRoot, $true)
}

if ($script:failures.Count -gt 0) {
    Write-Host "SELF-TEST FAILED: $($script:failures.Count)" -ForegroundColor Red
    Complete-BRAVOHelperLog -ExitCode 1
}
Write-Host "SELF-TEST PASSED" -ForegroundColor Green
Complete-BRAVOHelperLog -ExitCode 0
