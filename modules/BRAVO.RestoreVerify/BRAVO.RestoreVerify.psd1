@{
    RootModule = 'BRAVO.RestoreVerify.psm1'
    ModuleVersion = '5.3.0'
    GUID = '1da2ed3e-76d4-4be7-baeb-9ac7371efef0'
    PowerShellVersion = '3.0'
    FunctionsToExport = @(
        'Get-BRAVORestoreVerifyStatePath',
        'Get-BRAVORestoreVerifyState',
        'Save-BRAVORestoreVerifyState',
        'Get-BRAVORestoreVerifyHealthIssue'
    )
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
