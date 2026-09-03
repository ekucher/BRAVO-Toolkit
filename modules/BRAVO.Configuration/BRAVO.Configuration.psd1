@{
    RootModule = 'BRAVO.Configuration.psm1'
    ModuleVersion = '5.3.0'
    GUID = '89d103b4-9568-46dc-97e2-4b926984df47'
    PowerShellVersion = '3.0'
    FunctionsToExport = @(
        'Get-BRAVODefaultConfiguration',
        'Merge-BRAVOConfiguration',
        'ConvertTo-BRAVONestedOverride',
        'Resolve-BRAVORawConfiguration'
    )
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
