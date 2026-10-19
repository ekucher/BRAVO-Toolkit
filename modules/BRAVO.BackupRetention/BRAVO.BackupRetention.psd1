@{
    RootModule = 'BRAVO.BackupRetention.psm1'
    ModuleVersion = '5.3.0'
    GUID = '4b7d2c1e-9a35-4e68-b0f4-3c8a6d5e7f12'
    PowerShellVersion = '3.0'
    FunctionsToExport = @(
        'Get-BRAVOBackupRetentionPolicy',
        'Get-BRAVOBackupRetentionPlan',
        'Get-BRAVOBackupRetentionSimulation',
        'Format-BRAVOBackupRetentionPlanLines'
    )
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
