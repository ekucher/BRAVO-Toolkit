@{
    RootModule = 'BRAVO.System.psm1'
    ModuleVersion = '5.3.0'
    GUID = '48b4ae74-0681-4d21-a9c4-b26dd0e9330b'
    PowerShellVersion = '3.0'
    FunctionsToExport = @('Test-IsAdministrator', 'ConvertTo-BRAVOProcessArgument', 'ConvertTo-BRAVOTaskPath', 'ConvertTo-BRAVOSchedulerLogonType', 'Get-BRAVOExpectedSchedulerPrincipal', 'ConvertTo-BRAVODaysOfWeekMask', 'Format-BRAVOSchedulerNextRun', 'Get-BRAVOBackupCatchUpDecision', 'Get-BRAVOTaskRootReadinessResults', 'Get-BRAVOServiceDelayedAutoStart', 'Get-BRAVOServiceStartMode', 'Get-BRAVOManagedServiceCondition', 'Set-BRAVOBootRestoreServiceStartType', 'Get-BRAVOServiceRegistryStartMode', 'Set-BRAVOServiceStartMode', 'New-BRAVOServiceStartTypeSnapshot', 'Suspend-BRAVOServiceAutostart', 'Restore-BRAVOServiceStartTypeSnapshot', 'Repair-BRAVOOrphanedServiceStartTypes', 'Get-BRAVOForeignServiceQuiescenceContext', 'Confirm-BRAVOServicesQuiesced', 'Get-BRAVOServiceQuiescenceStatePath', 'Protect-BRAVOMachineStateRoot', 'Write-BRAVOServiceQuiescenceState', 'Read-BRAVOServiceQuiescenceState', 'Clear-BRAVOServiceQuiescenceState', 'Set-BRAVOServiceQuiescenceRestartSuppressed', 'Test-BRAVOProcessAlive', 'Write-BRAVOStateFileAtomic', 'ConvertTo-BRAVOSchedulerExecutionTimeLimit', 'Get-BRAVOOperationLockWaitBudget', 'Get-BRAVOServiceRecoveryTaskTriggerSpec', 'Initialize-BRAVOServiceRecoveryTaskDefinition', 'Test-BRAVOServiceRecoveryTaskDefinition', 'Get-BRAVOManagedServiceStartModeSummary')
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
