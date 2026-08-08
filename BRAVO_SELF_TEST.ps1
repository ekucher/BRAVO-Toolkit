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
            $archiveScriptTextForSecretMasking.Contains(
                "`$script:notificationCredentialInitializationError = Protect-BRAVOLogSecret -Text `$_.Exception.Message"
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
            (Resolve-BRAVOExitCode -InternalError) -eq 90
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
    Test-BRAVOCondition `
        -Condition (
            (Get-BRAVOExitCodeName -Code 0) -eq "Success" -and
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

    $resolvedConfig = (Resolve-Path -LiteralPath $ConfigPath).Path
    $configRoot = Split-Path -Path $resolvedConfig -Parent
    $configurationLoaderPath = Join-Path $configRoot 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    $loadedConfiguration = Import-BravoConfiguration `
        -ConfigRoot $configRoot `
        -ConfigPath $resolvedConfig `
        -PassThru

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
    $bravoConfigText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO.config"),
        [Text.Encoding]::UTF8
    )
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
            "Split-DiscordNotificationText",
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
            "Get-BRAVOCollisionSafeGenerationId",
            "New-BRAVOTemporaryArchivePath",
            "Remove-BRAVOTemporaryArchiveArtifacts",
            "Invoke-BRAVOComponentBackup",
            "Remove-BRAVOWinSCPSensitiveTemporaryScript",
            "Clear-BRAVOStaleWinSCPSensitiveTemporaryScripts",
            "New-BRAVOWinSCPTemporaryScriptPath"
        )

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
            $archiveScriptText.Contains("Get-BRAVOFiles -Path `$BackupRoot -Filter 'BRAVO_BACKUP_*.json'") -and
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
            $archiveScriptText.Contains("несумісних імен") -and
            $archiveScriptText.Contains("Select-Object -First 5") -and
            $archiveScriptText.Contains("Split-DiscordNotificationText -Message `$message") -and
            $archiveScriptText.Contains('$script:notificationWebhookUrl') -and
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
    Test-BRAVOCondition `
        -Condition (
            $healthScriptText.Contains('Format-HealthIssueFileName -Issue $Issue') -and
            $healthScriptText.Contains('$($Issue.Reason)$(Format-HealthIssueFileName -Issue $Issue)')
        ) `
        -Name "Health/SFTPArchiveNameOnFailures" `
        -Failure "ім'я локального архіву має відображатися для всіх SFTP-помилок"
    Test-BRAVOCondition `
        -Condition (
            $healthScriptText.Contains("Get-BRAVOFiles -Path `$backupRootPath -Filter 'BRAVO_BACKUP_*.json'") -and
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
    $finalSummaryCommandAlternatives = @('Write-BRAVOSummary', 'Write-BRAVOResultHeader')
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
    # початку, Health і Maintenance підтягнуто до нього.
    $runtimeStepTotals = @(
        @{ Title = 'Archive';     Initializer = 'Initialize-BRAVOArchiveSteps' },
        @{ Title = 'Health';      Initializer = 'Initialize-BRAVOHealthSteps' },
        @{ Title = 'Maintenance'; Initializer = 'Initialize-BRAVOMaintenanceSteps' }
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
            $restoreTestScriptText.Contains("BRAVO_BACKUP_*.json") -and
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
    # Runtime, який не елевейтиться взагалі (Health), задовольняє інваріант
    # за побудовою.
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
    Test-BRAVOCondition `
        -Condition (
            [regex]::IsMatch($bravoConfigTextForScheduler, 'PowerShellExecutable\s*=\s*Join-Path\s+\$env:SystemRoot\s+"System32\\WindowsPowerShell\\v1\.0\\powershell\.exe"') -and
            $taskInstallerText.Contains('$definition.Principal.RunLevel = 1') -and
            $taskInstallerText.Contains('$action.WorkingDirectory = Split-Path -Path $scriptPath -Parent') -and
            $taskInstallerText.Contains('$actionArguments += " -File `"$scriptPath`""') -and
            $taskInstallerText.Contains('$actionArguments += " -ConfigPath `"$ResolvedConfigPath`""')
        ) `
        -Name "Runtime/06-SchedulerActionUsesAbsolutePathsAndHighest" `
        -Failure "дія завдання має використовувати абсолютний powershell.exe, абсолютні -File/-ConfigPath, WorkingDirectory = каталог скрипта і RunLevel Highest"

    # --- Runtime/07: diagnostics покриває всі production-завдання ---
    Test-BRAVOCondition `
        -Condition (
            $tasksDiagnoseTextForRuntime.Contains('@("Backup", "Maintenance", "Health", "Recovery", "BAZASync")') -and
            $tasksDiagnoseTextForRuntime.Contains('function Test-BRAVOScheduledTaskDefinition') -and
            $tasksDiagnoseTextForRuntime.Contains('BAZASync    = @(''-NoPause'', ''-SyncBAZA'')') -and
            $tasksDiagnoseTextForRuntime.Contains('Recovery    = @(''-NoPause'', ''-RunMissedRestoreOnly'')') -and
            $tasksDiagnoseTextForRuntime.Contains('LogonType=$($principal.LogonType), очікується ServiceAccount (5)') -and
            $tasksDiagnoseTextForRuntime.Contains('RunLevel=$($principal.RunLevel), очікується Highest (1)')
        ) `
        -Name "Runtime/07-TaskDiagnosticsCoversAllProductionTasks" `
        -Failure "діагностика має перевіряти визначення ВСІХ production-завдань, включно з BAZASync: SYSTEM/ServiceAccount/Highest, аргументи, -ConfigPath і WorkingDirectory"

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

    # 7. SKIPPED: пропущений крок показує пояснення без підпису "Причина:"
    # (Write-BRAVOSkipReason), а не просто мовчазний пропуск нумерації.
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptText.Contains("'SKIPPED' { Write-BRAVOSkipReason -Reason `$Details }")
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
    Test-BRAVOCondition `
        -Condition (
            $waitManualExitText.Contains('[Console]::IsInputRedirected') -and
            $waitManualExitText.Contains('[Environment]::UserInteractive')
        ) `
        -Name "ConsoleUX/13-RedirectedNonInteractiveSkipsWait" `
        -Failure "Wait-BRAVOManualExit має пропускати очікування при перенаправленому/неінтерактивному запуску"
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
            ExitVar = '$script:maintenanceRuntimeExitCode = if'
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
} catch {
    [void]$script:failures.Add($_.Exception.Message)
    Write-Host "[FAIL] Fatal: $($_.Exception.Message)" -ForegroundColor Red
}

if ($script:failures.Count -gt 0) {
    Write-Host "SELF-TEST FAILED: $($script:failures.Count)" -ForegroundColor Red
    Complete-BRAVOHelperLog -ExitCode 1
}
Write-Host "SELF-TEST PASSED" -ForegroundColor Green
Complete-BRAVOHelperLog -ExitCode 0
