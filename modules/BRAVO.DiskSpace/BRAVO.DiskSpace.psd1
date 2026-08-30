@{
    RootModule = 'BRAVO.DiskSpace.psm1'
    ModuleVersion = '5.2.2'
    GUID = 'a2f1b9d0-6e0e-4a3c-9d0a-2f7c6b1d8e4a'
    PowerShellVersion = '3.0'
    FunctionsToExport = @(
        'New-BRAVODiskSpaceResult',
        'Resolve-BRAVODiskSpaceStorageIdentity',
        'Get-BRAVODiskSpaceAccessState',
        'Get-BRAVODiskSpaceCapacityObservation',
        'Resolve-BRAVODiskSpaceGroupRequirement',
        'Test-BRAVODiskSpaceEntity',
        'Resolve-BRAVODiskSpaceGroupDecision',
        'Invoke-BRAVODiskSpaceClassifier',
        'Write-BRAVODiskSpaceDecisionLog'
    )
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
