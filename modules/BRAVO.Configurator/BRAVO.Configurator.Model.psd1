@{
    RootModule = 'BRAVO.Configurator.Model.psm1'
    ModuleVersion = '5.3.0'
    GUID = 'b2f4d3e1-7c2b-4f7b-8e3f-2b3c4d5e6f70'
    PowerShellVersion = '5.1'
    # Залежить від BRAVO.Configurator.Effective (Invoke-BRAVOConfiguratorEffectiveComputation)
    # — RequiredModules навмисно НЕ оголошено: репозиторій оперує цими
    # модулями через прямий Import-Module шляху .psm1 (не .psd1/PSModulePath),
    # а бере filename-based RequiredModules ламає Test-ModuleManifest
    # (BRAVO_SELF_TEST.ps1 Version/ModuleManifests) поза PSModulePath.
    # Кожен caller (self-test, майбутній UI-entrypoint) відповідає за
    # імпорт Effective.psm1 перед цим модулем.
    FunctionsToExport = @('Get-BRAVOConfiguratorValueAtPath', 'Get-BRAVOConfiguratorModel', 'Set-BRAVOConfiguratorOverride', 'Clear-BRAVOConfiguratorOverride', 'ConvertTo-BRAVOConfiguratorOverrideHashtable', 'Test-BRAVOConfiguratorValueEquality', 'Update-BRAVOConfiguratorEffective')
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
