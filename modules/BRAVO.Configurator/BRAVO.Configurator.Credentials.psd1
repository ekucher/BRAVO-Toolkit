@{
    RootModule = 'BRAVO.Configurator.Credentials.psm1'
    ModuleVersion = '5.3.0'
    GUID = 'e6f7a8b4-1c2d-4e3f-9a5b-6c7d8e9f0a1b'
    PowerShellVersion = '5.1'
    # Залежить від BRAVO.Configurator.Effective (EffectiveConfig-снімок) —
    # RequiredModules навмисно НЕ оголошено (див. пояснення в
    # BRAVO.Configurator.Model.psd1: filename-based RequiredModules ламає
    # Test-ModuleManifest поза PSModulePath).
    FunctionsToExport = @('Get-BRAVOConfiguratorCredentialRequirement', 'Invoke-BRAVOConfiguratorCredentialCheck', 'Get-BRAVOConfiguratorCredentialState', 'Invoke-BRAVOConfiguratorCredentialSetup')
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
