[CmdletBinding()]
param(
    [string]$Root
)

# Ранній fail-fast гейт: у продуктовому дереві немає файлів AI-агентів
# (.claude/, .codex/, AGENTS.md, CLAUDE.md, .mcp.json). Те саме перевіряє
# self-test Governance/NoAgentFilesInTree.RealTreeHasNoAgentFiles, але він
# виконується лише в кінці довгого прогону BRAVO_SELF_TEST.ps1. Цей крок
# падає за секунди в static-checks. Політика й скан - єдина реалізація
# ci\BRAVOAgentFilePolicy.ps1 (Get-BRAVOAgentFileScan).
#
# Окремий файл, а не `run:` у ci.yml, з тієї ж причини, що й
# ci\Test-BRAVOForbiddenPattern.ps1: `run:` записується без BOM, і Windows
# PowerShell 5.1 ламає кириличні рядки.

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
if (-not (Test-Path -LiteralPath (Join-Path $Root 'BRAVO_SELF_TEST.ps1') -PathType Leaf)) {
    Write-Host "::error::Не схоже на корінь репозиторію BRAVO (немає BRAVO_SELF_TEST.ps1): $Root"
    exit 1
}

. (Join-Path $PSScriptRoot 'BRAVOAgentFilePolicy.ps1')

$scan = Get-BRAVOAgentFileScan -TreeRoot $Root
Write-Host "Режим перевірки: $($scan.Mode)"
if ($scan.Error -ne '') {
    # Неперевірене дерево не вважається чистим (fail closed).
    Write-Host "::error::AGENT_FILES_SCAN_FAILED: $($scan.Error)"
    exit 1
}
$violations = @($scan.Violations)
if ($violations.Count -gt 0) {
    foreach ($violation in $violations) {
        Write-Host "::error::AGENT_FILES_IN_TREE: $violation"
    }
    Write-Host "Файли AI-агентів не належать продуктовому репозиторію; їх джерело - окремий репозиторій автоматизації. Порушень: $($violations.Count)."
    exit 1
}
Write-Host 'AGENT_FILES_IN_TREE (0): файлів AI-агентів у дереві немає.'
exit 0
