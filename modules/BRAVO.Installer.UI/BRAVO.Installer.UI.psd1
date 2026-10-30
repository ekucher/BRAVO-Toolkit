@{
    RootModule = 'BRAVO.Installer.UI.psm1'
    ModuleVersion = '5.3.0'
    GUID = '4d0b6f0e-7a52-4c3e-9a71-3b8f5e2d9c14'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'ConvertTo-BRAVOInstallerHomeViewModel',
        'ConvertTo-BRAVOInstallerPreflightViewModel',
        'ConvertTo-BRAVOInstallerProgressViewModel',
        'Get-BRAVOInstallerStartupSize',
        'New-BRAVOInstallerEngineCommand',
        'New-BRAVOInstallerConfiguratorCommand',
        'New-BRAVOInstallerLogsCommand',
        'Start-BRAVOInstallerEngineJob',
        'Get-BRAVOInstallerEngineJobStatus',
        'Read-BRAVOInstallerProgress',
        'New-BRAVOInstallerScreenHome',
        'New-BRAVOInstallerScreenPreflight',
        'New-BRAVOInstallerScreenSettings',
        'New-BRAVOInstallerScreenDiagnostics',
        'New-BRAVOInstallerScreenLogs',
        'Get-BRAVOInstallerWizardStepList',
        'ConvertTo-BRAVOInstallerWizardStepViewModel',
        'Test-BRAVOInstallerSourceInput',
        'ConvertTo-BRAVOInstallerSourceViewModel',
        'ConvertTo-BRAVOInstallerDirectoriesViewModel',
        'Get-BRAVOInstallerBackupModeList',
        'ConvertTo-BRAVOInstallerBackupViewModel',
        'ConvertTo-BRAVOInstallerCredentialsViewModel',
        'ConvertTo-BRAVOInstallerScheduleViewModel',
        'Get-BRAVOInstallerPlanShortId',
        'ConvertTo-BRAVOInstallerPlanViewModel',
        'New-BRAVOInstallerExecutionRequest',
        'Test-BRAVOInstallerMutationStarted',
        'Get-BRAVOInstallerPlanSelfTest',
        'Get-BRAVOInstallerConfirmedInstallRoot',
        'Get-BRAVOInstallerCancelAction',
        'ConvertTo-BRAVOInstallerExecutionViewModel',
        'ConvertTo-BRAVOInstallerResultViewModel',
        'ConvertTo-BRAVOInstallerLogListViewModel',
        'ConvertTo-BRAVOInstallerMaintenanceViewModel',
        'New-BRAVOInstallerPlanCommand',
        'New-BRAVOInstallerExecuteCommand',
        'New-BRAVOInstallerRecoverCommand',
        'New-BRAVOInstallerCredentialsCommand',
        'New-BRAVOInstallerOpenLogCommand',
        'Write-BRAVOInstallerExecutionRequest',
        'New-BRAVOInstallerCancelRequest',
        'Read-BRAVOInstallerExecutionState',
        'New-BRAVOInstallerScreenSource',
        'New-BRAVOInstallerScreenDirectories',
        'New-BRAVOInstallerScreenBackup',
        'New-BRAVOInstallerScreenCredentials',
        'New-BRAVOInstallerScreenSchedule',
        'New-BRAVOInstallerScreenPlan',
        'New-BRAVOInstallerScreenProgress',
        'New-BRAVOInstallerScreenResult',
        'New-BRAVOInstallerMainForm',
        'Show-BRAVOInstallerMainForm'
    )
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
