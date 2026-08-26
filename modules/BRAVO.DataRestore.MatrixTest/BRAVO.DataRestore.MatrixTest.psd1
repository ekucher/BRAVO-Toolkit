@{
    RootModule = 'BRAVO.DataRestore.MatrixTest.psm1'
    ModuleVersion = '5.2.1'
    GUID = 'b14f2951-aa96-4504-85fc-cfbd3fbda1dc'
    PowerShellVersion = '3.0'
    FunctionsToExport = @(
        'New-BRAVODataRestoreMatrixFixtureConfig',
        'New-BRAVODataRestoreMatrixFixtureGeneration',
        'Invoke-BRAVODataRestoreMatrixCombo',
        'Get-BRAVODataRestoreMatrixComboDefinitions',
        'Assert-BRAVODataRestoreMatrixComboResult',
        'Write-BRAVODataRestoreMatrixSummary'
    )
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
