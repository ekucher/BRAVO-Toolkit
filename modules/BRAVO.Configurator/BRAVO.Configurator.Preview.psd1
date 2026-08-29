@{
    RootModule = 'BRAVO.Configurator.Preview.psm1'
    ModuleVersion = '5.3.0'
    GUID = 'a2b3c4d5-6e7f-4a8b-9c0d-1e2f3a4b5c6d'
    PowerShellVersion = '5.1'
    # Залежить від BRAVO.Configurator.Model (Test-BRAVOConfiguratorValueEquality)
    # і BRAVO.Configurator.Validation (Invoke-BRAVOConfiguratorValidation) —
    # RequiredModules навмисно НЕ оголошено, див. пояснення в
    # BRAVO.Configurator.Model.psd1.
    FunctionsToExport = @('Get-BRAVOConfiguratorPreview')
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
