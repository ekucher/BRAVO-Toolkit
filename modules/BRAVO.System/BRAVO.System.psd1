@{
    RootModule = 'BRAVO.System.psm1'
    ModuleVersion = '5.2.2'
    GUID = '48b4ae74-0681-4d21-a9c4-b26dd0e9330b'
    PowerShellVersion = '3.0'
    FunctionsToExport = @('Test-IsAdministrator', 'ConvertTo-BRAVOProcessArgument', 'ConvertTo-BRAVOTaskPath', 'ConvertTo-BRAVOSchedulerLogonType', 'Get-BRAVOExpectedSchedulerPrincipal', 'Format-BRAVOSchedulerNextRun', 'Get-BRAVOTaskRootReadinessResults', 'Get-BRAVOServiceDelayedAutoStart', 'Set-BRAVOBootRestoreServiceStartType', 'Get-BRAVOServiceQuiescenceStatePath', 'Protect-BRAVOMachineStateRoot', 'Write-BRAVOServiceQuiescenceState', 'Read-BRAVOServiceQuiescenceState', 'Clear-BRAVOServiceQuiescenceState', 'Set-BRAVOServiceQuiescenceRestartSuppressed', 'Test-BRAVOProcessAlive')
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
