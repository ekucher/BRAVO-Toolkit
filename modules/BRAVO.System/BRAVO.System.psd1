@{
    RootModule = 'BRAVO.System.psm1'
    ModuleVersion = '5.1.0'
    GUID = '48b4ae74-0681-4d21-a9c4-b26dd0e9330b'
    PowerShellVersion = '3.0'
    FunctionsToExport = @('Test-IsAdministrator', 'ConvertTo-BRAVOProcessArgument', 'ConvertTo-BRAVOTaskPath', 'ConvertTo-BRAVOSchedulerLogonType', 'Get-BRAVOExpectedSchedulerPrincipal', 'Format-BRAVOSchedulerNextRun', 'Get-BRAVOTaskRootReadinessResults')
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
