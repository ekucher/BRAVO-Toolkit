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
        'New-BRAVOInstallerMainForm',
        'Show-BRAVOInstallerMainForm'
    )
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
