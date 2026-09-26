[CmdletBinding()]
param(
    # Корінь дерева для перевірки — на PR-шляху це просто checked-out repo
    # tree (обидва гейти в BRAVOConfigV2CutoverGates.ps1 — чисто текстові
    # перевірки; staging-каталог release-artifact-збірки їм не потрібен).
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

# Issue #216, H-1: до цього скрипту гейти LEGACY_CONFIG_REMOVED/AUTOEXEC
# виконувались ЛИШЕ всередині ci\New-BRAVOReleaseArtifact.ps1, який
# запускається виключно при push тега чи workflow_dispatch (release-artifact.yml)
# — НІКОЛИ на pull_request. Регресія (production entrypoint втратив
# -DisallowLegacyPrimaryAutoDetect, чи хтось повернув BRAVO.config у
# git tracking) залишалась б непоміченою аж до наступного релізу. Цей
# тонкий CLI-wrapper дає той самий канонічний гейт PR-рівня видимість,
# без побудови повного release-артефакту.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'BRAVOConfigV2CutoverGates.ps1')

$result = Test-BRAVOConfigV2CutoverGates -Root $RepositoryRoot

if (-not $result.Passed) {
    foreach ($failureMessage in $result.Failures) {
        Write-Host "::error::$failureMessage"
    }
    exit 1
}

Write-Host 'Config V2 cutover gates (LEGACY_CONFIG_REMOVED / LEGACY_CONFIG_AUTOEXEC): PASS.'
exit 0
