# BRAVO.Update — канонічний власник lifecycle-операцій Installer v1
# (install / update / repair / rollback / recovery). Контракти:
# docs\installer\CONTRACTS.md. Модуль складається з фокусованих частин, які
# dot-source-яться в область модуля в явному порядку; відсутня частина —
# fail closed.
#
# Повторно використовувана політика релізу (канал, provenance) і файлові
# helper-и відкату живуть у deploy\BRAVO.Deploy.ReleaseGate.ps1 та
# deploy\BRAVO.Deploy.Rollback.ps1 і підключаються звідти без копій.

Set-StrictMode -Version 2.0

$script:BRAVOUpdateToolkitRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$script:BRAVOUpdateSharedPolicyFiles = @(
    (Join-Path $script:BRAVOUpdateToolkitRoot 'deploy\BRAVO.Deploy.ReleaseGate.ps1'),
    (Join-Path $script:BRAVOUpdateToolkitRoot 'deploy\BRAVO.Deploy.Rollback.ps1')
)
foreach ($policyFile in $script:BRAVOUpdateSharedPolicyFiles) {
    if (-not (Test-Path -LiteralPath $policyFile -PathType Leaf)) {
        throw "BRAVO.Update: shared policy file not found: $policyFile"
    }
    . $policyFile
}

# Спільні модулі toolkit, потрібні частинам (BRAVO.Logging: Protect-BRAVOLogSecret
# для звітів; BRAVO.ExitCodes: канонічні коди завершення). Імпортуються ОДИН раз
# тут, до частин, у область модуля (-Global:$false: не засмічуємо сесію
# викликача); відсутній модуль — fail closed, без «лінивих» імпортів у частинах.
foreach ($sharedModuleRelativePath in @('modules\BRAVO.Logging\BRAVO.Logging.psd1', 'modules\BRAVO.ExitCodes\BRAVO.ExitCodes.psd1')) {
    $sharedModulePath = Join-Path $script:BRAVOUpdateToolkitRoot $sharedModuleRelativePath
    if (-not (Test-Path -LiteralPath $sharedModulePath -PathType Leaf)) {
        throw "BRAVO.Update: shared module not found: $sharedModulePath"
    }
    Import-Module -Name $sharedModulePath -DisableNameChecking -Global:$false -ErrorAction Stop
}

$script:BRAVOUpdateParts = @(
    'BRAVO.Update.Paths.ps1',
    'BRAVO.Update.Contracts.ps1',
    'BRAVO.Update.Journal.ps1',
    'BRAVO.Update.Lock.ps1',
    'BRAVO.Update.Staging.ps1',
    'BRAVO.Update.Release.ps1',
    'BRAVO.Update.Discovery.ps1',
    'BRAVO.Update.Preflight.ps1',
    'BRAVO.Update.Plan.ps1',
    'BRAVO.Update.Diagnostics.ps1',
    'BRAVO.Update.Backup.ps1',
    'BRAVO.Update.Deploy.ps1',
    'BRAVO.Update.Reconcile.ps1',
    'BRAVO.Update.Validation.ps1',
    'BRAVO.Update.Rollback.ps1',
    'BRAVO.Update.Recovery.ps1',
    'BRAVO.Update.Install.ps1',
    'BRAVO.Update.Repair.ps1',
    'BRAVO.Update.Worker.ps1'
)
foreach ($part in $script:BRAVOUpdateParts) {
    $partPath = Join-Path $PSScriptRoot $part
    if (-not (Test-Path -LiteralPath $partPath -PathType Leaf)) {
        throw "BRAVO.Update: module part not found: $partPath"
    }
    . $partPath
}