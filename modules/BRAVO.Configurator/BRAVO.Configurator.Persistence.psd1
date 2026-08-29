@{
    RootModule = 'BRAVO.Configurator.Persistence.psm1'
    ModuleVersion = '5.3.0'
    GUID = 'd4f6f5a3-9e4d-4b9d-8a5b-4d5e6f708192'
    PowerShellVersion = '5.1'
    # Залежить від BRAVO.Configurator.Effective/Model/Validation — див.
    # пояснення відсутності RequiredModules у BRAVO.Configurator.Model.psd1.
    FunctionsToExport = @('Get-BRAVOConfiguratorProductionOverrideState', 'Merge-BRAVOConfiguratorCandidateOverrides', 'Test-BRAVOConfiguratorCandidateOverrides', 'ConvertTo-BRAVOConfiguratorLocalConfigText', 'Invoke-BRAVOConfiguratorApply')
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
