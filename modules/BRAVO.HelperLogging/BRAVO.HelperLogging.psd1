@{
    RootModule = 'BRAVO.HelperLogging.psm1'
    ModuleVersion = '5.2.1'
    GUID = 'e731a176-928c-45bd-91f3-dd3baafbcacf'
    PowerShellVersion = '3.0'
    FunctionsToExport = @(
        'Start-BRAVOHelperLog',
        'Complete-BRAVOHelperLog',
        'Suspend-BRAVOHelperLog',
        'Resume-BRAVOHelperLog',
        'Test-BRAVOHelperLogSuspensionEffective'
    )
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
