[CmdletBinding()]
param(
    # База порівняння (ref або SHA). Порожня база - AFFECTED RESULT: BASE-MISSING.
    [string]$BaseRef = '',

    # Корінь репозиторію; за замовчуванням - батьківський каталог цього скрипту.
    [string]$RepositoryRoot = ''
)

# VAL-05 (Affected), PR3: тонкий CLI. Уся логіка - у ci\BRAVOAffectedSelfTest.ps1
# (за прецедентом ci\Test-BRAVOConfigV2CutoverGatesOnPullRequest.ps1). Це
# локальний інструмент розробника, а не acceptance: код завершення лише
# 0 (вибірковий прогін підтверджено маркером) або 1 (усе інше, зокрема V3).
# Нової таблиці exit-кодів немає.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    $repositoryPath = $RepositoryRoot
    if ([string]::IsNullOrEmpty($repositoryPath)) {
        $repositoryPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    }
    . (Join-Path $PSScriptRoot 'BRAVOChangedPath.ps1')
    . (Join-Path $PSScriptRoot 'Test-BRAVOConfigParityRelevantPath.ps1')
    . (Join-Path $PSScriptRoot 'BRAVOAffectedSelfTest.ps1')
    . (Join-Path (Join-Path $PSScriptRoot '..') 'selftest\BRAVOSelfTestSuiteMap.ps1')
    $result = Invoke-BRAVOAffectedSelfTest -RepositoryRoot $repositoryPath -BaseRef $BaseRef
} catch {
    # Повідомлення винятку може містити переводи рядка; друкуємо його одним
    # рядком, щоб жоден рядок stdout не почався з маркера Self-Test.
    $errorText = [regex]::Replace([string]$_.Exception.Message, '[\x00-\x1F\x7F-\x9F\u2028\u2029]', ' ')
    Write-Host ('AFFECTED ERROR: ' + $errorText)
    Write-Host 'AFFECTED RESULT: RUNNER-FAILED'
    exit 1
}

if ($result.ExitCode -eq 0) {
    exit 0
}
exit 1
