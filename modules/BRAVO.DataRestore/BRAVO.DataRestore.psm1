$script:runtimePath = Join-Path $PSScriptRoot 'BRAVO.DataRestore.Runtime.ps1'
if (-not (Test-Path -LiteralPath $script:runtimePath -PathType Leaf)) {
    throw "BRAVO Data Restore runtime not found: $script:runtimePath"
}

function Invoke-BRAVODataRestoreEntrypoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Parameters)

    try {
        & $script:runtimePath @Parameters | Out-Host
        return [int]$LASTEXITCODE
    } catch {
        # Runtime завершується явним Exit у штатних сценаріях (успіх і
        # оброблена помилка), тому цей catch спрацьовує лише на справді
        # непередбаченій помилці. Без цієї обгортки виняток проривався б
        # крізь return і процес завершувався б генеричним кодом самого
        # PowerShell, а не керованим значенням.
        Write-Error "Неочікувана помилка runtime Data Restore: $($_.Exception.Message)"
        return 90
    }
}

Export-ModuleMember -Function 'Invoke-BRAVODataRestoreEntrypoint'
