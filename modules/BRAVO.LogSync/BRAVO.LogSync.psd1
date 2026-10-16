@{
    RootModule = 'BRAVO.LogSync.psm1'
    ModuleVersion = '5.3.0'
    GUID = '8f1c6e9a-3d2b-4a7e-9c5f-6b8d2e4a1f7c'
    PowerShellVersion = '3.0'
    FunctionsToExport = @(
        'Test-BRAVOLogSyncAllowlistMatch',
        'Get-BRAVOLogSyncLocalSnapshot',
        'Get-BRAVOLogSyncLedgerPath',
        'Read-BRAVOLogSyncLedger',
        'Write-BRAVOLogSyncLedger',
        'Get-BRAVOLogSyncPlan',
        'Invoke-BRAVOLogSyncRun'
    )
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
