@{
    RootModule = 'BRAVO.ArchiveHelpers.psm1'
    ModuleVersion = '5.2.0'
    GUID = '0a073e11-f066-4dc5-b9f7-24aae1a9b3df'
    PowerShellVersion = '3.0'
    FunctionsToExport = @('Remove-OldLogsByAge', 'Test-SevenZipArchiveIntegrity', 'Get-BRAVOValidArchiveSizeHistory', 'Test-BRAVOBackupSizeAnomaly', 'Get-BRAVOBackupManifestRoot', 'Get-BRAVOBackupGenerationManifestFiles', 'Initialize-BRAVOBackupManifestStorage', 'Get-BRAVOBackupGenerationManifestPhysicalFiles', 'Get-BRAVOBackupManifestFilenameGenerationId', 'Get-BRAVORestoreGenerationManifest', 'Get-BRAVOVerifiedGenerationArchive', 'Get-BRAVOVerifiedArtifactLeafName', 'ConvertTo-BRAVORebasedLocalGenerationManifest')
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
