@{
    RootModule = 'BRAVO.Discovery.psm1'
    ModuleVersion = '5.0.0'
    GUID = 'a2f5c6e1-7b3d-4e9a-9c1f-2d6b8e4a5f70'
    PowerShellVersion = '3.0'
    FunctionsToExport = @('Get-BRAVOServiceExecutablePath', 'Find-BRAVOServiceByCandidates', 'ConvertFrom-BRAVOIniFile', 'Get-BRAVOIniValue', 'ConvertTo-BRAVOIniPathValue', 'Test-BRAVOAbsolutePath', 'Get-BRAVOApacheDocumentRoot', 'Get-BRAVOSystemBravoIniPath', 'Resolve-BRAVOInstallationDiscovery', 'Resolve-BRAVOEffectiveLimsRoot', 'Resolve-BRAVOEffectiveSystemLogRoot', 'Resolve-BRAVOEffectiveBackupRoot', 'Get-BRAVOEffectiveSynchronizationConfiguration', 'Test-BRAVODiscoveryResult', 'Save-BRAVODiscoveryBaseline', 'Compare-BRAVODiscoveryBaseline')
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
