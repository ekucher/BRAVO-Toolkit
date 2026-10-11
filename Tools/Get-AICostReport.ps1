#requires -Version 5.1
<#
.SYNOPSIS
    Зведення фактичного використання AI-агентів BRAVO за записами
    .claude/logs/ai-cost.jsonl.

.DESCRIPTION
    Читає рядки, які дописує хук .claude/hooks/record-ai-cost.ps1, і показує
    агрегати: токени (input/output/cache), кількість сесій, розподіл викликів
    по агентах і ролях Codex, заявлені причини fallback.

    Звіт описує фактичне спостережене використання. Він не містить цін і не
    перетворює токени на гроші — тарифи тут навмисно не зашиті, щоб звіт не
    став джерелом застарілих цифр.

.PARAMETER RepoRoot
    Корінь репозиторію. Типово — батьківський каталог цього скрипта.

.PARAMETER Days
    Обмежити звіт останніми N добами за полем recordedAt. 0 = без обмеження.

.PARAMETER AsObject
    Повернути об'єкт замість друку таблиць.

.EXAMPLE
    .\Tools\Get-AICostReport.ps1

.EXAMPLE
    .\Tools\Get-AICostReport.ps1 -Days 7
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [int]$Days = 0,
    [switch]$AsObject
)

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    # Та сама причина, що й у Tools/Check-AgentPolicy.ps1: у Windows PowerShell 5.1
    # $PSScriptRoot не гарантований у default-значенні параметра.
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$ErrorActionPreference = 'Stop'

$costLog = Join-Path $RepoRoot '.claude\logs\ai-cost.jsonl'
if (-not (Test-Path -LiteralPath $costLog -PathType Leaf)) {
    Write-Host "Немає записів обліку: $costLog"
    Write-Host 'Облік створюється хуком Stop (.claude/hooks/record-ai-cost.ps1) після завершення сесії.'
    return
}

$cutoff = $null
if ($Days -gt 0) { $cutoff = (Get-Date).AddDays(-$Days) }

$records = New-Object System.Collections.Generic.List[object]
$malformed = 0

foreach ($line in [IO.File]::ReadLines($costLog)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
        $record = $line | ConvertFrom-Json
    }
    catch {
        $malformed++
        continue
    }

    if ($null -ne $cutoff) {
        try {
            if (([datetime]$record.recordedAt) -lt $cutoff) { continue }
        }
        catch {
            # запис без придатної дати лишаємо у звіті, але позначаємо нижче
        }
    }
    $records.Add($record)
}

if ($records.Count -eq 0) {
    Write-Host 'Немає записів за вказаний період.'
    return
}

$agentTotals = @{}
$codexTotals = @{}
$fallbackTotals = @{}
$modelTotals = @{}

$sumInput = 0
$sumOutput = 0
$sumCacheCreation = 0
$sumCacheRead = 0
$sumTurns = 0
$sumMinutes = 0.0

foreach ($record in $records) {
    if ($null -ne $record.inputTokens) { $sumInput += [int]$record.inputTokens }
    if ($null -ne $record.outputTokens) { $sumOutput += [int]$record.outputTokens }
    if ($null -ne $record.cacheCreationTokens) { $sumCacheCreation += [int]$record.cacheCreationTokens }
    if ($null -ne $record.cacheReadTokens) { $sumCacheRead += [int]$record.cacheReadTokens }
    if ($null -ne $record.assistantTurns) { $sumTurns += [int]$record.assistantTurns }
    if ($null -ne $record.durationMinutes) { $sumMinutes += [double]$record.durationMinutes }

    foreach ($model in @($record.models)) {
        if ([string]::IsNullOrWhiteSpace($model)) { continue }
        if ($modelTotals.ContainsKey($model)) { $modelTotals[$model]++ } else { $modelTotals[$model] = 1 }
    }

    if ($null -ne $record.agentCalls) {
        foreach ($property in $record.agentCalls.PSObject.Properties) {
            $count = [int]$property.Value
            if ($agentTotals.ContainsKey($property.Name)) { $agentTotals[$property.Name] += $count } else { $agentTotals[$property.Name] = $count }
        }
    }

    if ($null -ne $record.codexCalls) {
        foreach ($property in $record.codexCalls.PSObject.Properties) {
            $count = [int]$property.Value
            if ($codexTotals.ContainsKey($property.Name)) { $codexTotals[$property.Name] += $count } else { $codexTotals[$property.Name] = $count }
        }
    }

    foreach ($reason in @($record.fallbackReasons)) {
        if ([string]::IsNullOrWhiteSpace($reason)) { continue }
        if ($fallbackTotals.ContainsKey($reason)) { $fallbackTotals[$reason]++ } else { $fallbackTotals[$reason] = 1 }
    }
}

$summary = [ordered]@{
    Sessions            = $records.Count
    AssistantTurns      = $sumTurns
    InputTokens         = $sumInput
    OutputTokens        = $sumOutput
    CacheCreationTokens = $sumCacheCreation
    CacheReadTokens     = $sumCacheRead
    TotalMinutes        = [math]::Round($sumMinutes, 1)
    MalformedLines      = $malformed
    Models              = $modelTotals
    AgentCalls          = $agentTotals
    CodexCalls          = $codexTotals
    FallbackReasons     = $fallbackTotals
}

if ($AsObject) {
    return [pscustomobject]$summary
}

Write-Host ''
Write-Host 'Зведення використання AI (фактичні записи обліку)'
Write-Host '------------------------------------------------'
Write-Host ("Сесій:                 {0}" -f $summary.Sessions)
Write-Host ("Відповідей асистента:  {0}" -f $summary.AssistantTurns)
Write-Host ("Токени input:          {0:N0}" -f $summary.InputTokens)
Write-Host ("Токени output:         {0:N0}" -f $summary.OutputTokens)
Write-Host ("Запис кешу:            {0:N0}" -f $summary.CacheCreationTokens)
Write-Host ("Читання кешу:          {0:N0}" -f $summary.CacheReadTokens)
Write-Host ("Сумарна тривалість:    {0} хв" -f $summary.TotalMinutes)
if ($malformed -gt 0) {
    Write-Host ("Пошкоджених рядків:    {0}" -f $malformed)
}

function Write-Breakdown {
    param([string]$Title, [hashtable]$Totals)

    Write-Host ''
    Write-Host $Title
    if ($Totals.Count -eq 0) {
        Write-Host '  (немає)'
        return
    }
    foreach ($entry in ($Totals.GetEnumerator() | Sort-Object -Property Value -Descending)) {
        Write-Host ("  {0,-34} {1}" -f $entry.Key, $entry.Value)
    }
}

Write-Breakdown -Title 'Моделі (сесій із цією моделлю):' -Totals $modelTotals
Write-Breakdown -Title 'Делегування агентам:' -Totals $agentTotals
Write-Breakdown -Title 'Виклики Codex:' -Totals $codexTotals
Write-Breakdown -Title 'Заявлені причини fallback:' -Totals $fallbackTotals
Write-Host ''
