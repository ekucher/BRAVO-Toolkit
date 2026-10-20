[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [string]$RuntimeRoot,
    [string]$FixtureRoot
)

# #486 (VETOFFICE-DISCOVERY-0): локальна characterization чинної поведінки
# Discovery та планування trace-архіву на знеособлених фікстурах VetOffice
# (selftest\fixtures\vetoffice). Скрипт ФІКСУЄ фактичну поведінку, а не
# бажану: результат — докази для docs\BRAVO_VETOFFICE_GAP_ANALYSIS.md, тому
# розбіжність з очікуванням не є збоєм скрипта (код 0), збій самого
# harness-а — код 1.
#
# Ізоляція (read-only щодо машини):
#   - фікстури матеріалізуються ЛИШЕ під -OutputRoot (новий підкаталог
#     run-<час>); -OutputRoot не може бути всередині RuntimeRoot;
#   - служби Windows не перелічуються: Resolve-BRAVOInstallationDiscovery
#     отримує синтетичні Win32_Service-подібні об'єкти через -Services;
#   - bravo.ini читається лише з фікстурного -SystemRoot (SysWOW64), а не
#     з %SystemRoot%;
#   - Get-BRAVOTraceArchiveBacklog (BRAVO.Maintenance.Runtime.ps1) лише
#     перелічує файли; виконується у динамічному модулі з тексту функції,
#     без виконання решти Runtime-скрипта;
#   - жодних Start-/Stop-Service, Scheduled Tasks, Credential Manager,
#     %ProgramData%\BRAVO чи мережі.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    $RuntimeRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
}
$RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($FixtureRoot)) {
    $FixtureRoot = Join-Path $RuntimeRoot 'selftest\fixtures\vetoffice'
}
$FixtureRoot = [IO.Path]::GetFullPath($FixtureRoot)
if (-not [IO.Path]::IsPathRooted($OutputRoot)) {
    throw "-OutputRoot має бути абсолютним шляхом: $OutputRoot"
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
if ($OutputRoot.Equals($RuntimeRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $OutputRoot.StartsWith($RuntimeRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "-OutputRoot не може бути всередині RuntimeRoot ($RuntimeRoot): $OutputRoot"
}

$runRoot = Join-Path $OutputRoot ('run-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
if (Test-Path -LiteralPath $runRoot) {
    throw "Каталог прогону вже існує: $runRoot"
}
[void][IO.Directory]::CreateDirectory($runRoot)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$cp1251 = [Text.Encoding]::GetEncoding(1251)
$strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)

Import-Module -Name (Join-Path $RuntimeRoot 'modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1') -Force
Import-Module -Name (Join-Path $RuntimeRoot 'modules\BRAVO.Configuration\BRAVO.Configuration.psd1') -Force
Import-Module -Name (Join-Path $RuntimeRoot 'modules\BRAVO.Discovery\BRAVO.Discovery.psd1') -Force

# Кандидати Apache-служби й ім'я exchangAPI — із канонічних дефолтів, а не
# з власної копії переліку.
$defaultServices = (Get-BRAVODefaultConfiguration).maintenanceSettings.Services
$webServiceCandidates = @($defaultServices.BravoWebCandidates)
$exchangeApiServiceName = [string]$defaultServices.ExchangeApiName
$bravoServiceName = [string]$defaultServices.BravoName
$bravoDisplayNames = @($defaultServices.BravoDisplayName)

# Get-BRAVOTraceArchiveBacklog живе в Runtime-скрипті Maintenance (не в
# модулі). Беремо рівно текст функції з AST, як це робить self-test.
$maintenanceRuntimePath = Join-Path $RuntimeRoot 'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1'
$parseTokens = $null
$parseErrors = $null
$maintenanceAst = [Management.Automation.Language.Parser]::ParseFile($maintenanceRuntimePath, [ref]$parseTokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) {
    throw "Не вдалося розібрати $maintenanceRuntimePath (помилок: $(@($parseErrors).Count)): $($parseErrors[0].Message)"
}
$backlogFunctionAst = $maintenanceAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-BRAVOTraceArchiveBacklog'
    }, $true)
if ($null -eq $backlogFunctionAst) {
    throw "Get-BRAVOTraceArchiveBacklog не знайдено в $maintenanceRuntimePath"
}
$backlogModuleText = "function Get-BRAVOFiles { BRAVO.Compatibility\Get-BRAVOFiles @args }`r`n" +
    $backlogFunctionAst.Extent.Text + "`r`nExport-ModuleMember -Function Get-BRAVOTraceArchiveBacklog"
$backlogModule = New-Module -Name 'BRAVOVetOfficeTraceBacklogProbe' -ScriptBlock ([scriptblock]::Create($backlogModuleText))
Import-Module -ModuleInfo $backlogModule -Force

$scenarioDocument = [IO.File]::ReadAllText((Join-Path $FixtureRoot 'scenarios.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
$layout = $scenarioDocument.layout

function ConvertTo-VetOfficeFixtureText {
    param([string]$Text, [string]$InstallationRoot)
    return $Text.Replace('{{VETOFFICE_ROOT_FWD}}', $InstallationRoot.Replace('\', '/')).Replace('{{VETOFFICE_ROOT}}', $InstallationRoot)
}

function Get-VetOfficeRelativeName {
    param([string]$Path, [string]$Root)
    if ($Path.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($Root.Length + 1)
    }
    return $Path
}

$results = New-Object System.Collections.Generic.List[object]
foreach ($scenario in @($scenarioDocument.scenarios)) {
    $scenarioRoot = Join-Path $runRoot ([string]$scenario.id)
    # Літера диска моделюється каталогом drive-<X>: фікстура не пише на
    # справжній диск C:/D:, а Discovery працює з абсолютними шляхами без
    # прив'язки до літери.
    $installationRoot = Join-Path $scenarioRoot ('drive-' + [string]$scenario.driveLetter + '\VetOffice')
    $systemRoot = Join-Path $scenarioRoot 'Windows'
    [void][IO.Directory]::CreateDirectory($installationRoot)
    [void][IO.Directory]::CreateDirectory((Join-Path $systemRoot 'SysWOW64'))

    foreach ($relativeDirectory in @($layout.directories)) {
        [void][IO.Directory]::CreateDirectory((Join-Path $installationRoot ([string]$relativeDirectory)))
    }
    foreach ($stub in @($layout.stubFiles)) {
        [IO.File]::WriteAllText((Join-Path $installationRoot ([string]$stub.path)), [string]$stub.text, $utf8NoBom)
    }
    $traceEvidence = New-Object System.Collections.Generic.List[object]
    foreach ($traceFile in @($layout.cp1251TraceFiles)) {
        $sourceText = [IO.File]::ReadAllText((Join-Path $FixtureRoot ([string]$traceFile.source)), [Text.Encoding]::UTF8)
        $bytes = $cp1251.GetBytes($sourceText)
        $targetPath = Join-Path $installationRoot ([string]$traceFile.path)
        [IO.File]::WriteAllBytes($targetPath, $bytes)
        $isValidUtf8 = $true
        try { [void]$strictUtf8.GetString($bytes) } catch { $isValidUtf8 = $false }
        $traceEvidence.Add([ordered]@{
                Path = [string]$traceFile.path
                Bytes = $bytes.Length
                Sha256 = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
                RoundTripsAsCp1251 = ($cp1251.GetString([IO.File]::ReadAllBytes($targetPath)) -ceq $sourceText)
                DecodesAsStrictUtf8 = $isValidUtf8
            })
    }
    foreach ($legacyArchive in @($layout.legacyArchiveStubs)) {
        # Не справжній 7z: лише байти-заглушка для перевірки переліку/фільтрів.
        [IO.File]::WriteAllBytes((Join-Path $installationRoot ([string]$legacyArchive)), [byte[]](0x37, 0x7A, 0x00, 0x00))
    }

    $bravoIniTemplate = [IO.File]::ReadAllText((Join-Path $FixtureRoot ([string]$scenario.bravoIniTemplate)), [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $systemRoot 'SysWOW64\bravo.ini'), (ConvertTo-VetOfficeFixtureText -Text $bravoIniTemplate -InstallationRoot $installationRoot), $utf8NoBom)
    $httpdTemplate = [IO.File]::ReadAllText((Join-Path $FixtureRoot ([string]$scenario.httpdConfTemplate)), [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $installationRoot 'apache\conf\httpd.conf'), (ConvertTo-VetOfficeFixtureText -Text $httpdTemplate -InstallationRoot $installationRoot), $utf8NoBom)

    $services = @($scenarioDocument.services | ForEach-Object {
            [pscustomobject]@{
                Name = [string]$_.Name
                DisplayName = [string]$_.DisplayName
                State = [string]$_.State
                StartMode = [string]$_.StartMode
                PathName = (ConvertTo-VetOfficeFixtureText -Text ([string]$_.PathName) -InstallationRoot $installationRoot)
            }
        })

    $discovery = Resolve-BRAVOInstallationDiscovery `
        -BravoServiceName $bravoServiceName `
        -BravoDisplayName $bravoDisplayNames `
        -WebServiceCandidates $webServiceCandidates `
        -ExchangeApiServiceName $exchangeApiServiceName `
        -Services $services `
        -SystemRoot $systemRoot `
        -Is64BitOperatingSystem $true

    $allEnabled = @{ MODEL = $true; BLOG = $true; BRAVOEXCH = $true; BAZA_APP = $true; BAZA_WWW = $true }
    $validationErrors = @(Test-BRAVODiscoveryResult -DiscoveryResult $discovery -EnabledComponents $allEnabled)
    $scope = Resolve-BRAVOBackupComponentScope -DiscoveryResult $discovery -EnabledComponents $allEnabled

    $componentSummary = [ordered]@{}
    foreach ($componentName in @($discovery.Components.Keys)) {
        $component = $discovery.Components[$componentName]
        $componentSummary[$componentName] = [ordered]@{
            Presence = [string]$component.Presence
            Source = [string]$component.Source
            Path = $(if ($component.Path) { Get-VetOfficeRelativeName -Path ([string]$component.Path) -Root $installationRoot } else { $null })
            AbsenceKind = [string]$component.AbsenceKind
        }
    }
    $scopeSummary = [ordered]@{}
    foreach ($componentName in @($scope.Components.Keys)) {
        $scopeSummary[$componentName] = [string]$scope.Components[$componentName]
    }

    $installationBacklog = @(Get-BRAVOTraceArchiveBacklog -TraceDirectory $installationRoot)
    $legacyTraceBacklog = @(Get-BRAVOTraceArchiveBacklog -TraceDirectory (Join-Path $installationRoot 'ARCHIV\Trace'))

    $results.Add([ordered]@{
            Id = [string]$scenario.id
            Label = [string]$scenario.label
            LogicalRoot = [string]$scenario.logicalRoot
            MaterializedRoot = $installationRoot
            Discovery = [ordered]@{
                BRAVO_ROOT = $(if ($discovery.BRAVO_ROOT) { Get-VetOfficeRelativeName -Path ([string]$discovery.BRAVO_ROOT) -Root $installationRoot } else { $null })
                BravoRootIsInstallationRoot = ([string]$discovery.BRAVO_ROOT -ieq $installationRoot)
                WEB_ROOT_IsInstallationRoot = ([string]$discovery.WEB_ROOT -ieq $installationRoot)
                WebServiceName = [string]$discovery.WebServiceName
                MODEL_PROJECT_FILE = $(if ($discovery.MODEL_PROJECT_FILE) { Get-VetOfficeRelativeName -Path ([string]$discovery.MODEL_PROJECT_FILE) -Root $installationRoot } else { $null })
                TRACE_FILE = $(if ($discovery.TRACE_FILE) { Get-VetOfficeRelativeName -Path ([string]$discovery.TRACE_FILE) -Root $installationRoot } else { $null })
                TRACE_FILE_OUTSIDE_INSTALLATION = [bool]$discovery.TRACE_FILE_OUTSIDE_INSTALLATION
                ServicesMatched = @($discovery.Services | ForEach-Object { [string]$_.Name })
                ExchangeApiServiceMatched = (@($discovery.Services | Where-Object { [string]$_.Name -ieq $exchangeApiServiceName }).Count -gt 0)
                Components = $componentSummary
                ValidationErrors = $validationErrors
            }
            BackupScope = $scopeSummary
            TraceBacklog = [ordered]@{
                InstallationRoot = @($installationBacklog | ForEach-Object { [ordered]@{ ArchiveName = [string]$_.ArchiveName; Files = @($_.Files | ForEach-Object { [string]$_.Name }) } })
                LegacyArchivTrace = @($legacyTraceBacklog | ForEach-Object { [ordered]@{ ArchiveName = [string]$_.ArchiveName; Files = @($_.Files | ForEach-Object { [string]$_.Name }) } })
            }
            Cp1251Trace = $traceEvidence.ToArray()
            ServiceDependencies = @($scenarioDocument.services | ForEach-Object { [ordered]@{ Name = [string]$_.Name; DependsOn = @($_.DependsOn) } })
            DiscoveryExposesServiceDependencies = (@($discovery.Services | Where-Object { $_.PSObject.Properties.Name -contains 'DependsOn' -or $_.PSObject.Properties.Name -contains 'ServicesDependedOn' }).Count -gt 0)
        })
}

$document = [ordered]@{
    Harness = 'Invoke-BRAVOVetOfficeFixtureCharacterization'
    Issue = '#486'
    GeneratedAt = (Get-Date).ToString('o')
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    RuntimeRoot = $RuntimeRoot
    RunRoot = $runRoot
    Scenarios = $results.ToArray()
}
$resultPath = Join-Path $runRoot 'characterization.json'
[IO.File]::WriteAllText($resultPath, ($document | ConvertTo-Json -Depth 10), $utf8NoBom)

foreach ($result in $results) {
    Write-Output ("[{0}] BRAVO_ROOT={1}; TRACE_FILE={2}; ValidationErrors={3}" -f $result.Id, $result.Discovery.BRAVO_ROOT, $result.Discovery.TRACE_FILE, @($result.Discovery.ValidationErrors).Count)
    foreach ($componentName in @($result.Discovery.Components.Keys)) {
        $component = $result.Discovery.Components[$componentName]
        Write-Output ("  {0,-10} {1,-8} {2,-17} {3}" -f $componentName, $component.Presence, $component.Source, $component.Path)
    }
    Write-Output ("  BackupScope: " + (@($result.BackupScope.Keys | ForEach-Object { "$_=$($result.BackupScope[$_])" }) -join ', '))
}
Write-Output "Результат: $resultPath"
exit 0
