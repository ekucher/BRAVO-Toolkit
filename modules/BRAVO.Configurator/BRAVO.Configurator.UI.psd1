@{
    RootModule = 'BRAVO.Configurator.UI.psm1'
    ModuleVersion = '5.3.0'
    GUID = 'f3c1a9d2-4b7e-4a2f-9c31-7d8e0f1a2b3c'
    PowerShellVersion = '5.1'
    # Залежить від усіх інших BRAVO.Configurator.* модулів (Schema/
    # Effective/Model/Validation/Persistence/Credentials/Presets/Preview).
    # RequiredModules навмисно НЕ оголошено — той самий підхід, що інші
    # BRAVO.Configurator.*.psd1 (див. пояснення в BRAVO.Configurator.Model.psd1):
    # BRAVO_CONFIGURATOR.ps1 імпортує всі модулі явно й у правильному
    # порядку залежностей ще до BRAVO.Configurator.UI.
    FunctionsToExport = @(
        'Show-BRAVOConfiguratorMainForm',
        'Get-BRAVOConfiguratorUIReachablePaths',
        'Get-BRAVOConfiguratorUIFilteredSettings',
        'Get-BRAVOConfiguratorUISearchMatches',
        'Get-BRAVOConfiguratorUICategoryTree',
        'Get-BRAVOConfiguratorUIBooleanTriState',
        'ConvertTo-BRAVOConfiguratorUIDisplayText',
        'ConvertTo-BRAVOConfiguratorUITypedValue',
        # P2-B: чисті UX-helpers (layout breakpoint/filter labels/context
        # help/startup-size/splitter clamp) — headless-тестовані, без
        # System.Windows.Forms у сигнатурі/тілі.
        'Get-BRAVOConfiguratorUILayoutMode',
        'Get-BRAVOConfiguratorUIFilterOptions',
        'Get-BRAVOConfiguratorUISettingHelpText',
        'Get-BRAVOConfiguratorUIGeneralHelpText',
        'Get-BRAVOConfiguratorUIStartupSize',
        'Get-BRAVOConfiguratorUIClampedSplitterDistance'
    )
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
