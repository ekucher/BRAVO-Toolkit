@{
    RootModule = 'BRAVO.ServiceRecovery.psm1'
    ModuleVersion = '5.3.0'
    GUID = '1070c750-b961-4189-9a71-1752263b28e6'
    PowerShellVersion = '3.0'
    FunctionsToExport = @(
        'Get-BRAVOServiceRecoveryPolicy',
        'Test-BRAVOServiceRecoveryFailed',
        'Test-BRAVOServiceRecoveryStartModeUnknown',
        'Get-BRAVOServiceRecoveryStatePath',
        'Read-BRAVOServiceRecoveryState',
        'Write-BRAVOServiceRecoveryState',
        'Get-BRAVOServiceRecoveryAttemptDecision',
        'Register-BRAVOServiceRecoveryAttempt',
        'Register-BRAVOServiceRecoveryCriticalSent',
        'Register-BRAVOServiceRecoveryStableObservation',
        'Remove-BRAVOServiceRecoveryExpiredAttempts',
        'New-BRAVOServiceRecoveryNotificationText',
        'Get-BRAVOServiceRecoveryConditions',
        'Get-BRAVOServiceRecoveryChainPlan',
        'Select-BRAVOServiceRecoveryScmEvents',
        'Get-BRAVOServiceRecoveryScmEvents',
        'Add-BRAVOServiceRecoverySummaryLine',
        'Add-BRAVOServiceRecoveryTaskTriggers',
        'Test-BRAVOServiceRecoveryTaskDefinition'
    )
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
