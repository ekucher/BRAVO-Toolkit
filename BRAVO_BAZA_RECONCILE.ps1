[CmdletBinding()]
param(
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet('BAZA_APP', 'BAZA_WWW')]
    [string]$Component,

    [switch]$ListOnly,

    # Відносні шляхи мутацій (як у звіті -ListOnly), що їх оператор СВІДОМО
    # приймає: стара версія на SFTP перейменовується в *.replaced_<дата>,
    # запис прибирається зі стану, нову версію заллє наступний плановий цикл.
    [string[]]$Accept = @(),

    [switch]$AcceptAll,

    # Пропускає інтерактивне підтвердження RECONCILE для -AcceptAll
    # (скриптовані сценарії). На -Accept з явним переліком не впливає.
    [switch]$Force,

    [switch]$NoPause
)

# Пауза перед закриттям вікна — самодостатня (без BRAVO.Console): цілісність
# комплекту ще не підтверджена. Той самий блок, що в BRAVO_ARCHIV.ps1 та
# інших guarded-entrypoints.
function Wait-BRAVOEarlyManualExit {
    param([switch]$NoPause)
    if ($NoPause) { return }
    try {
        if (-not [Environment]::UserInteractive) { return }
        if ([Console]::IsInputRedirected) { return }
    } catch {
        return
    }
    Write-Host ""
    Write-Host "Натиснiть будь-яку клавiшу для закриття вiкна..." -ForegroundColor Cyan
    try {
        [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        try {
            [void](Read-Host)
        } catch {
            # Немає інтерактивного вводу — виходимо без паузи.
        }
    }
}

# Цілісність комплекту перевіряється ДО Import-Module (guard самодостатній).
$effectiveConfigPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    Join-Path $PSScriptRoot 'BRAVO.config'
} else {
    [Environment]::ExpandEnvironmentVariables($ConfigPath)
}
try {
    $effectiveConfigPath = [System.IO.Path]::GetFullPath($effectiveConfigPath)
} catch {
    $effectiveConfigPath = [string]$effectiveConfigPath
}
$ConfigPath = $effectiveConfigPath

$runtimeGuardPath = Join-Path $PSScriptRoot 'BRAVO_RUNTIME_GUARD.ps1'
if (Test-Path -LiteralPath $runtimeGuardPath -PathType Leaf) {
    try {
        . $runtimeGuardPath
    } catch {
        Write-Host "КРИТИЧНА ПОМИЛКА: не вдалося завантажити BRAVO_RUNTIME_GUARD.ps1: $($_.Exception.Message)" -ForegroundColor Red
        Wait-BRAVOEarlyManualExit -NoPause:$NoPause
        exit 33
    }
    foreach ($guardFunction in @(
        'Test-BRAVORuntimeManifestIntegrity',
        'Test-BRAVORuntimeSecuritySettings',
        'Test-BRAVOVersionDowngrade'
    )) {
        if (-not (Get-Command -Name $guardFunction -CommandType Function -ErrorAction SilentlyContinue)) {
            Write-Host "КРИТИЧНА ПОМИЛКА: BRAVO_RUNTIME_GUARD.ps1 не оголосив $guardFunction — цілісність комплекту не підтверджена" -ForegroundColor Red
            Wait-BRAVOEarlyManualExit -NoPause:$NoPause
            exit 33
        }
    }
    $runtimeIntegrityMode = if ($env:BRAVO_RUNTIME_INTEGRITY_MODE -eq 'Warn') { 'Warn' } else { 'Enforce' }
    $runtimeIntegrity = Test-BRAVORuntimeManifestIntegrity `
        -RuntimeRoot $PSScriptRoot `
        -ManifestPath (Join-Path $PSScriptRoot 'RUNTIME_MANIFEST.json') `
        -Mode $runtimeIntegrityMode
    if (-not $runtimeIntegrity.IsValid) {
        Write-Host $runtimeIntegrity.Message -ForegroundColor Red
        if ($runtimeIntegrity.ShouldBlock) { Wait-BRAVOEarlyManualExit -NoPause:$NoPause; exit 33 }
    }
    $securitySettings = Test-BRAVORuntimeSecuritySettings `
        -ConfigPath $effectiveConfigPath `
        -Mode $runtimeIntegrityMode
    if (-not $securitySettings.IsValid) {
        $securityColor = if ($securitySettings.ShouldBlock) { 'Red' } else { 'Yellow' }
        Write-Host $securitySettings.Message -ForegroundColor $securityColor
        if ($securitySettings.ShouldBlock) { Wait-BRAVOEarlyManualExit -NoPause:$NoPause; exit 34 }
    }
    $versionState = Test-BRAVOVersionDowngrade `
        -RuntimeRoot $PSScriptRoot `
        -StatePath (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'BRAVO\State\BRAVO_VERSION_STATE.json') `
        -Mode $runtimeIntegrityMode
    if (-not $versionState.IsValid) {
        $versionColor = if ($versionState.ShouldBlock) { 'Red' } else { 'Yellow' }
        Write-Host $versionState.Message -ForegroundColor $versionColor
        if ($versionState.ShouldBlock) { Wait-BRAVOEarlyManualExit -NoPause:$NoPause; exit 35 }
    }
} else {
    Write-Host "КРИТИЧНА ПОМИЛКА: відсутній BRAVO_RUNTIME_GUARD.ps1 — цілісність комплекту не підтверджена" -ForegroundColor Red
    Wait-BRAVOEarlyManualExit -NoPause:$NoPause
    exit 33
}

$ErrorActionPreference = 'Stop'

$helperLoggingPath = Join-Path $PSScriptRoot 'modules\BRAVO.HelperLogging\BRAVO.HelperLogging.psd1'
Import-Module -Name $helperLoggingPath -ErrorAction Stop
$null = Start-BRAVOHelperLog -ScriptPath $PSCommandPath -ConfigPath $ConfigPath

function Exit-BRAVOBazaReconcile {
    # Єдина точка завершення: пауза для інтерактивного вікна + transcript +
    # exit із категоризованим кодом (Complete-BRAVOHelperLog сам викликає exit).
    param([Parameter(Mandatory = $true)][int]$ExitCode)
    Wait-BRAVOEarlyManualExit -NoPause:$NoPause
    Complete-BRAVOHelperLog -ExitCode $ExitCode
}

try {
    foreach ($moduleRelativePath in @(
        'modules\BRAVO.Console\BRAVO.Console.psd1',
        'modules\BRAVO.ExitCodes\BRAVO.ExitCodes.psd1',
        'modules\BRAVO.Credentials\BRAVO.Credentials.psd1',
        'modules\BRAVO.ArchiveRuntime\BRAVO.ArchiveRuntime.psd1',
        'modules\BRAVO.BazaSync\BRAVO.BazaSync.psd1'
    )) {
        Import-Module -Name (Join-Path $PSScriptRoot $moduleRelativePath) -ErrorAction Stop
    }

    $configurationLoaderPath = Join-Path $PSScriptRoot 'BRAVO_CONFIG_LOADER.ps1'
    . $configurationLoaderPath
    Import-BravoConfiguration `
        -ConfigRoot (Split-Path -Path $ConfigPath -Parent) `
        -ConfigPath $ConfigPath `
        -RuntimeRoot $PSScriptRoot

    Initialize-BRAVOConsole
    Initialize-BRAVOProgress -Enabled $false
    Write-BRAVOHeader `
        -Title ("BRAVO BAZA Reconcile {0}" -f $global:ScriptVersion) `
        -Institution ([string]$bravoSettings.InstitutionName) `
        -InstitutionCode ([string]$bravoSettings.InstitutionCode) `
        -Mode $(if ($ListOnly -or ($Accept.Count -eq 0 -and -not $AcceptAll)) { 'LIST-ONLY' } else { 'RECONCILE' })

    # Компонентні шляхи — рівно ті самі canonical-джерела, що використовує
    # Invoke-BRAVOBazaIncrementalSync (Archive): local Source з discovery,
    # remote root з sftpDirectories.
    $componentLocalDirectory = if ($Component -eq 'BAZA_APP') { [string]$global:bazaAppPaths.Source } else { [string]$global:bazaWWWPaths.Source }
    $componentRemoteDirectory = if ($Component -eq 'BAZA_APP') { [string]$global:sftpDirectories.BAZA } else { [string]$global:sftpDirectories.BAZAWWW }
    if ([string]::IsNullOrWhiteSpace($componentLocalDirectory)) {
        throw "локальне джерело $Component не визначено (discovery/config) — reconcile неможливий"
    }
    $normalizedRemoteDirectory = $componentRemoteDirectory.Replace('\', '/').Trim('/')
    $remoteRootPath = if ([string]::IsNullOrWhiteSpace($normalizedRemoteDirectory)) { '/' } else { "/$normalizedRemoteDirectory" }
    $bazaSettingsEffective = Get-BRAVOBazaSettingsEffective
    $stateRootPath = [string]$bazaSettingsEffective.StateRoot

    Write-BRAVOResultField -Label 'Компонент' -Value $Component
    Write-BRAVOResultField -Label 'Локальне джерело' -Value $componentLocalDirectory
    Write-BRAVOResultField -Label 'SFTP-каталог' -Value $remoteRootPath

    $mutationReport = Get-BRAVOBazaMutationReport `
        -Component $Component `
        -LocalDirectory $componentLocalDirectory `
        -StateRoot $stateRootPath
    if (-not $mutationReport.Success) {
        throw $mutationReport.Error
    }
    $mutations = @($mutationReport.Mutations)

    Write-BRAVOSeparator
    if ($mutations.Count -eq 0) {
        Write-BRAVOResultNote -Text 'Append-only мутацій немає — стан і локальне дерево узгоджені.'
        Exit-BRAVOBazaReconcile -ExitCode 0
    }
    Write-BRAVOResultNote -Text ("Мутацій (Verified-файл змінено локально після передачі): {0}" -f $mutations.Count)
    foreach ($mutation in $mutations) {
        Write-BRAVOResultNote -Text ("  {0}" -f $mutation.RelativePath)
        Write-BRAVOResultNote -Text ("    в хмарі: {0:N0} B, mtime {1}, залито {2}" -f [int64]$mutation.PreviousSize, $mutation.PreviousLastWriteTimeUtc, $mutation.UploadedUtc)
        Write-BRAVOResultNote -Text ("    локально: {0:N0} B, mtime {1}" -f [int64]$mutation.CurrentSize, $mutation.CurrentLastWriteTimeUtc)
    }
    Write-BRAVOResultNote -Text 'Перед прийняттям звірте легітимність за трейсом застосунку (ASCII-частина імені; байт-суми sp_filewrite = локальний розмір):'
    Write-BRAVOResultNote -Text ("  Select-String -Path '<BRAVO_ROOT>\TraceSRV.out' -Pattern '<фрагмент_імені>'")

    $acceptRequested = ($AcceptAll -or $Accept.Count -gt 0)
    if ($ListOnly -or -not $acceptRequested) {
        Write-BRAVOSeparator
        Write-BRAVOResultNote -Text 'Режим перегляду. Для розв''язання: -Accept <шлях[,шлях]> або -AcceptAll.'
        Exit-BRAVOBazaReconcile -ExitCode 0
    }

    $acceptList = if ($AcceptAll) { @($mutations | ForEach-Object { $_.RelativePath }) } else { @($Accept) }
    if ($AcceptAll -and -not $Force) {
        Write-Host ''
        Write-Host ("УВАГА: буде прийнято ВСІ {0} мутацій — старі версії на SFTP перейменуються у *.replaced_*, нові заллє наступний цикл." -f $acceptList.Count) -ForegroundColor Yellow
        $confirmation = Read-Host 'Для підтвердження введіть RECONCILE'
        if ($confirmation -cne 'RECONCILE') {
            Write-BRAVOResultNote -Text 'Скасовано оператором — жодних змін не виконано.'
            Exit-BRAVOBazaReconcile -ExitCode 0
        }
    }

    # SFTP-креденшли: той самий канонічний шлях, що Health/DataRestore —
    # Credential Manager -> Resolve-BRAVOSftpHostName -> New-BRAVOSftpUrl.
    $sftpLoginTarget = [string]$credentialSettings.Targets.SFTPLogin
    $sftpPasswordTarget = [string]$credentialSettings.Targets.SFTPPassword
    if ([string]::IsNullOrWhiteSpace($sftpLoginTarget)) { $sftpLoginTarget = 'BRAVO_SFTP_LOGIN' }
    if ([string]::IsNullOrWhiteSpace($sftpPasswordTarget)) { $sftpPasswordTarget = 'BRAVO_SFTP_PASSWORD' }
    $storedSftpLogin = Get-BRAVOCredentialSecret -Target $sftpLoginTarget
    $storedSftpPassword = Get-BRAVOCredentialSecret -Target $sftpPasswordTarget
    if ([string]::IsNullOrWhiteSpace($storedSftpLogin) -or [string]::IsNullOrWhiteSpace($storedSftpPassword)) {
        Write-Host "Записи Credential Manager '$sftpLoginTarget'/'$sftpPasswordTarget' недоступні для поточного облікового запису" -ForegroundColor Red
        Exit-BRAVOBazaReconcile -ExitCode (Resolve-BRAVOExitCode -CredentialsUnavailable)
    }
    $sftpLogin = ([string]$storedSftpLogin).Trim()
    $resolvedSftpHost = Resolve-BRAVOSftpHostName `
        -UserName $sftpLogin `
        -HostTemplate ([string]$global:sftpHostTemplate) `
        -FallbackHostName $(if ($null -ne (Get-Variable -Name 'sftpHost' -Scope Global -ErrorAction SilentlyContinue)) { [string]$global:sftpHost } else { $null })
    $repositorySftpUrl = New-BRAVOSftpUrl `
        -HostName $resolvedSftpHost `
        -Port ([int]$global:sftpPort) `
        -UserName $sftpLogin `
        -Password ([string]$storedSftpPassword)
    $storedSftpLogin = $null
    $storedSftpPassword = $null

    $winSCPComponents = Get-BRAVOWinSCPDotNetComponents -WinSCPPath ([string]$global:winSCPPath)
    if ($null -eq $winSCPComponents) {
        throw 'WinSCP .NET-компоненти (WinSCPnet.dll + winscp.exe) не знайдено — див. Get-BRAVOWinSCPDotNetComponents'
    }
    if ($null -eq ('WinSCP.Session' -as [type])) {
        Add-Type -Path $winSCPComponents.AssemblyPath -ErrorAction Stop
    }
    $sessionOptions = New-Object WinSCP.SessionOptions
    $sessionOptions.ParseUrl($repositorySftpUrl)
    $sessionOptions.SshHostKeyFingerprint = ([string]$global:sftpHostKey).Trim().Trim('"')
    $sessionOptions.Timeout = [timespan]::FromSeconds(30)
    $session = New-Object WinSCP.Session
    $session.ExecutablePath = $winSCPComponents.ExecutablePath
    $session.Timeout = [timespan]::FromSeconds(300)

    $reconcileResult = $null
    try {
        $session.Open($sessionOptions)
        $reconcileResult = Invoke-BRAVOBazaMutationReconciliation `
            -Component $Component `
            -LocalDirectory $componentLocalDirectory `
            -StateRoot $stateRootPath `
            -RemoteRootPath $remoteRootPath `
            -Session $session `
            -AcceptRelativePaths $acceptList
    } finally {
        try { $session.Dispose() } catch {
            # Сесія вже віддала результат; збій Dispose не критичний.
        }
    }

    Write-BRAVOSeparator
    Write-BRAVOResultField -Label 'Прийнято' -Value ("{0} з {1}" -f @($reconcileResult.Accepted).Count, $acceptList.Count)
    foreach ($renamed in @($reconcileResult.RenamedRemote)) {
        Write-BRAVOResultNote -Text ("  стару версію перейменовано: {0} -> {1}" -f $renamed.RemotePath, $renamed.RenamedTo)
    }
    foreach ($absentPath in @($reconcileResult.RemoteAbsent)) {
        Write-BRAVOResultNote -Text ("  на SFTP не було: {0} (rename не потрібен)" -f $absentPath)
    }
    foreach ($failure in @($reconcileResult.Failures)) {
        Write-BRAVOResultNote -Text ("  ПОМИЛКА [{0}] {1}: {2}" -f $failure.Stage, $failure.RelativePath, $failure.Error)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$reconcileResult.Error)) {
        Write-BRAVOResultNote -Text ("  ПОМИЛКА: {0}" -f $reconcileResult.Error)
    }
    if ($reconcileResult.Success) {
        Write-BRAVOResultNote -Text 'Нові версії заллє наступний плановий цикл BRAVO_ARCHIV; контроль — ранковий Health.'
        Exit-BRAVOBazaReconcile -ExitCode 0
    }
    Exit-BRAVOBazaReconcile -ExitCode (Resolve-BRAVOExitCode -SftpFailed)
} catch {
    Write-Host ("ПОМИЛКА: {0}" -f $_.Exception.Message) -ForegroundColor Red
    $failureExitCode = 90
    try { $failureExitCode = Resolve-BRAVOExitCode -InternalError } catch { $failureExitCode = 90 }
    Wait-BRAVOEarlyManualExit -NoPause:$NoPause
    Complete-BRAVOHelperLog -ExitCode $failureExitCode
}
