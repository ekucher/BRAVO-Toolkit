@{
    RootModule = 'BRAVO.Operations.psm1'
    ModuleVersion = '5.3.0'
    GUID = '119410a4-eef0-4c7c-a575-2f4ef1b409be'
    PowerShellVersion = '3.0'
    FunctionsToExport = @(
        'Get-BRAVOOperationsServerId',
        'Invoke-BRAVOOperationsEnrollment',
        'Send-BRAVOOperationsEvent',
        'Send-BRAVOOperationsHeartbeat'
    )
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
