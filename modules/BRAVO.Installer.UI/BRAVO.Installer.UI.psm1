# BRAVO.Installer.UI — WinForms-frontend BRAVO Installer (INS-080 прототип).
# GUI не містить політики розгортання: дані беруться з read-only дій engine
# (BRAVO_UPDATE.ps1 -Action State|Preflight) у дочірньому процесі. Модуль
# складається з фокусованих частин, які dot-source-яться в явному порядку
# (як BRAVO.Update.psm1); відсутня частина — fail closed.

Set-StrictMode -Version 2.0

$script:BRAVOInstallerUIParts = @(
    'BRAVO.Installer.UI.ViewModel.ps1',
    'BRAVO.Installer.UI.WizardModel.ps1',
    'BRAVO.Installer.UI.Engine.ps1',
    'BRAVO.Installer.UI.WizardEngine.ps1',
    'BRAVO.Installer.UI.Screens.ps1',
    'BRAVO.Installer.UI.WizardScreens.ps1'
)
foreach ($part in $script:BRAVOInstallerUIParts) {
    $partPath = Join-Path $PSScriptRoot $part
    if (-not (Test-Path -LiteralPath $partPath -PathType Leaf)) {
        throw "BRAVO.Installer.UI: module part not found: $partPath"
    }
    . $partPath
}
