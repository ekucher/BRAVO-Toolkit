@{
    RootModule = 'BRAVO.Configurator.Presets.psm1'
    ModuleVersion = '5.3.0'
    GUID = 'f1a2b3c4-5d6e-4f7a-8b9c-0d1e2f3a4b5c'
    PowerShellVersion = '5.1'
    # Залежить від BRAVO.Configurator.Model (Set-BRAVOConfiguratorOverride)
    # — RequiredModules навмисно НЕ оголошено, див. пояснення в
    # BRAVO.Configurator.Model.psd1.
    FunctionsToExport = @('Get-BRAVOConfiguratorPresetCatalog', 'Invoke-BRAVOConfiguratorPreset')
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
