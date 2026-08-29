@{
    RootModule = 'BRAVO.ArchiveRuntime.psm1'
    ModuleVersion = '5.2.2'
    GUID = '87e36322-a799-4d2e-a050-f5d4744b1dcf'
    PowerShellVersion = '3.0'
    FunctionsToExport = @('Enter-BRAVOWinSCPProcessLock', 'Test-BRAVOWinSCPAvailable', 'Get-BRAVOWinSCPBusyMessage', 'Get-BRAVOWinSCPDotNetComponents', 'Get-SanitizedWinSCPDiagnostic', 'Get-BRAVOBazaSyncModeEffective', 'Test-BRAVOBazaIncrementalModeEnabled', 'Get-BRAVOBazaSettingsEffective', 'Remove-BRAVOWinSCPSensitiveTemporaryScript', 'Clear-BRAVOStaleWinSCPSensitiveTemporaryScripts', 'New-BRAVOWinSCPTemporaryScriptPath')
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
