@{
    RootModule = 'BRAVO.BazaSync.psm1'
    ModuleVersion = '5.1.0'
    GUID = 'c4d8e1a2-6f9b-4c3d-8a7e-1b2c3d4e5f6a'
    PowerShellVersion = '3.0'
    FunctionsToExport = @('Get-BRAVOBazaStateDirectory', 'Get-BRAVOBazaStatePath', 'Enter-BRAVOBazaSyncLock', 'New-BRAVOBazaEmptyState', 'Read-BRAVOBazaState', 'Save-BRAVOBazaState', 'New-BRAVOBazaCycleId', 'Get-BRAVOBazaLocalSnapshot', 'Get-BRAVOBazaSyncPlan', 'Test-BRAVOBazaRemoteDirectoryExists', 'New-BRAVOBazaRemoteDirectoryRecursive', 'Invoke-BRAVOBazaFileUpload', 'ConvertTo-BRAVOBazaFullAuditResult', 'New-BRAVOBazaSyncResult', 'Invoke-BRAVOBazaSynchronization', 'Get-BRAVOBazaRemoteCheckpointName', 'Write-BRAVOBazaRemoteCheckpoint', 'Update-BRAVOBazaSyncResultNewAfterCutoff', 'Test-BRAVOBazaSyncResultFresh', 'Get-BRAVOBazaFastHealthResult', 'Invoke-BRAVOBazaComponentSyncSession')
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
