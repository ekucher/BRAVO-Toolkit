[CmdletBinding()]
param(
    # Цільовий stable-реліз лінії 5.2. Типово — останній.
    [string]$Tag = 'v5.2.6',

    # Каталог комплекту. Типово визначається за завданнями Планувальника
    # (\BRAVO\), а якщо їх не прочитати — 'C:\Program Files\BRAVO-Toolkit'.
    [string]$RuntimeRoot,

    # Лише показати, що буде зроблено: нічого не змінює і не потребує прав
    # адміністратора.
    [switch]$CheckOnly,

    # Залишити тимчасову мітигацію #335 ('enableFailedArchiveDeletion' = $false
    # у BRAVO.local.config) після оновлення. Типово вона прибирається: у 5.2.5+
    # дефект виправлено, а мітигація зупиняє очищення невдалих комплектів.
    [switch]$KeepMitigation335,

    # Дозволити оновлення з 5.2.0–5.2.3: цей перехід не проходив acceptance.
    [switch]$AllowUntestedSource,

    [switch]$NoElevation,
    [switch]$NoPause
)

# Оновлення сервера лінії 5.2 (5.2.4 і новіші 5.2.x) до stable 5.2.5+ однією
# дією оператора: подвійний клік на UPDATE-BRAVO52.cmd і підтвердження UAC.
#
# Сам розгортанням не займається. Усю роботу з комплектом — preflight, SHA-256
# і провенанс архіву, гейт каналу, backup, копіювання поверх, гейти після
# заміни й точний відкат — виконує Update-BRAVOServer.ps1 поруч (#289, #330).
# Ця обгортка додає те, що оператор інакше робив би вручну:
#   * визначає каталог комплекту за завданнями Планувальника;
#   * перевіряє, що встановлена версія — 5.2.x, нижча за цільову;
#   * бере архів поруч зі скриптом (сервер без доступу до GitHub), а якщо його
#     немає — Update-BRAVOServer.ps1 завантажує ассети релізу сам;
#   * після успішного оновлення прибирає тимчасову мітигацію #335 з
#     BRAVO.local.config (з копією і повторною перевіркою -ValidateOnly);
#   * пише журнал і підсумок у %ProgramData%\BRAVO\Upgrade.
#
# Проміжний інструмент розкатки 5.2 по парку: у 5.3 його замінить штатне
# оновлення (ROADMAP P3.2a).
#
# Коди завершення: 0 — оновлено або вже актуально (з -CheckOnly — перевірку
# пройдено); 1 — зупинено до змін або гейт провалився і відкат успішний;
# 2 — відкат не вдався (потрібне ручне втручання, backup лишається);
# 3 — оновлено, але мітигацію #335 не прибрано (див. журнал).

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$T) Write-Host ''; Write-Host ('=== ' + $T) -ForegroundColor Cyan }
function Write-Ok   { param([string]$T) Write-Host ('  [OK]    ' + $T) -ForegroundColor Green }
function Write-Bad  { param([string]$T) Write-Host ('  [FAIL]  ' + $T) -ForegroundColor Red }
function Write-Note { param([string]$T) Write-Host ('  [..]    ' + $T) }
function Write-Warn2{ param([string]$T) Write-Host ('  [УВАГА] ' + $T) -ForegroundColor Yellow }

function Wait-BRAVO52Completion {
    # Той самий контракт, що в Update-BRAVOServer.ps1: вікно, відкрите
    # подвійним кліком, не має закритися разом із результатом.
    if ($NoPause -or -not [Environment]::UserInteractive) { return }
    try {
        if ([Console]::IsInputRedirected) { return }
        [void](Read-Host 'Натисніть Enter для завершення')
    } catch {
        # Фоновий або перенаправлений запуск не має падати через брак консолі.
    }
}

function ConvertTo-BRAVO52Version {
    # '5.2.4' / '5.2.6-rc.1' -> @{ Patch = 4; Prerelease = ''/'rc.1' }; інше -> $null.
    param([string]$Version)
    $match = [regex]::Match([string]$Version, '^5\.2\.(\d+)(?:-([0-9A-Za-z.-]+))?\z')
    if (-not $match.Success) { return $null }
    return [pscustomobject]@{
        Patch      = [int]$match.Groups[1].Value
        Prerelease = [string]$match.Groups[2].Value
    }
}

function Get-BRAVO52UpgradeDecision {
    # Чи можна оновлювати встановлену версію до цільової. Чиста функція —
    # її перевіряє self-test.
    param(
        [string]$CurrentVersion,
        [string]$TargetVersion,
        [switch]$AllowUntestedSource
    )
    $current = ConvertTo-BRAVO52Version -Version $CurrentVersion
    $target = ConvertTo-BRAVO52Version -Version $TargetVersion
    if ($null -eq $target -or $target.Prerelease -ne '' -or $target.Patch -lt 5) {
        return [pscustomobject]@{ Action = 'Stop'; Message = ('Цільова версія ' + $TargetVersion + ' — не stable 5.2.5+; цей інструмент оновлює лише до stable-релізів лінії 5.2.') }
    }
    if ($null -eq $current) {
        return [pscustomobject]@{ Action = 'Stop'; Message = ('Встановлено ' + $CurrentVersion + ' — не лінія 5.2. Цей інструмент оновлює лише 5.2.x; для інших версій див. deploy\README.md.') }
    }
    if ($current.Patch -eq $target.Patch -and $current.Prerelease -eq '') {
        return [pscustomobject]@{ Action = 'UpToDate'; Message = ('Версія ' + $TargetVersion + ' вже встановлена.') }
    }
    if ($current.Patch -gt $target.Patch) {
        return [pscustomobject]@{ Action = 'Stop'; Message = ('Встановлено ' + $CurrentVersion + ' — новіше за ' + $TargetVersion + '. Пониження версії цим інструментом не виконується.') }
    }
    if ($current.Patch -lt 4 -and -not $AllowUntestedSource) {
        return [pscustomobject]@{ Action = 'Stop'; Message = ('Встановлено ' + $CurrentVersion + '. Перехід з версій до 5.2.4 не проходив acceptance; якщо оновлення свідоме, повторіть із -AllowUntestedSource.') }
    }
    return [pscustomobject]@{ Action = 'Update'; Message = ('Оновлення ' + $CurrentVersion + ' -> ' + $TargetVersion + '.') }
}

function Find-BRAVO52RuntimeRoot {
    # Каталог комплекту за діями завдань \BRAVO\ (усі завдання запускають
    # скрипти з одного комплекту). Повертає @{ Path; Source }.
    $roots = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $taskError = ''
    try {
        foreach ($task in @(Get-ScheduledTask -TaskPath '\BRAVO\' -ErrorAction Stop)) {
            foreach ($action in @($task.Actions)) {
                $text = [string]$action.Arguments + ' ' + [string]$action.Execute
                foreach ($m in [regex]::Matches($text, '(?i)([A-Z]:\\[^"]*?)\\BRAVO_[A-Z_]+\.ps1')) {
                    [void]$roots.Add($m.Groups[1].Value)
                }
            }
        }
    } catch {
        $taskError = $_.Exception.Message
    }
    if ($roots.Count -eq 1) {
        $only = @($roots)[0]
        return [pscustomobject]@{ Path = $only; Source = 'завдання Планувальника \BRAVO\' }
    }
    if ($roots.Count -gt 1) {
        throw ('Завдання \BRAVO\ запускають скрипти з різних каталогів (' + (@($roots) -join '; ') +
            '). Вкажіть каталог комплекту явно: -RuntimeRoot.')
    }
    $note = if ($taskError) { 'завдання не прочитано (' + $taskError + '), типовий шлях' } else { 'завдань \BRAVO\ не знайдено, типовий шлях' }
    return [pscustomobject]@{ Path = $script:DefaultRuntimeRoot; Source = $note }
}

function Test-BRAVO52PathInside {
    param([string]$Path, [string]$Root)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)
}

function Get-BRAVO52Mitigation335 {
    # Шукає в BRAVO.local.config пару 'enableFailedArchiveDeletion' = $false
    # (мітигація #335 для 5.2.4). Файл не виконується — лише розбирається в AST,
    # як і в самому комплекті. Повертає @{ Status; Message; StartLine; EndLine }:
    #   Absent    — файлу або ключа немає, чи значення не $false;
    #   Removable — пара займає власні рядки й може бути безпечно видалена;
    #   Manual    — пара є, але змішана з іншим текстом у рядку / файл не розбирається.
    param([string]$LocalConfigPath)

    if (-not (Test-Path -LiteralPath $LocalConfigPath -PathType Leaf)) {
        return [pscustomobject]@{ Status = 'Absent'; Message = 'BRAVO.local.config немає'; StartLine = 0; EndLine = 0 }
    }
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($LocalConfigPath, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        return [pscustomobject]@{ Status = 'Manual'; Message = ('BRAVO.local.config не розбирається: ' + $parseErrors[0].Message); StartLine = 0; EndLine = 0 }
    }
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($hashtable in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $true))) {
        foreach ($pair in @($hashtable.KeyValuePairs)) {
            $key = $pair.Item1
            if ($key -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                [string]::Equals($key.Value, 'enableFailedArchiveDeletion', [StringComparison]::OrdinalIgnoreCase)) {
                [void]$pairs.Add($pair)
            }
        }
    }
    if ($pairs.Count -eq 0) {
        return [pscustomobject]@{ Status = 'Absent'; Message = 'ключа enableFailedArchiveDeletion у BRAVO.local.config немає'; StartLine = 0; EndLine = 0 }
    }
    if ($pairs.Count -gt 1) {
        return [pscustomobject]@{ Status = 'Manual'; Message = 'ключ enableFailedArchiveDeletion у BRAVO.local.config зустрічається кілька разів'; StartLine = 0; EndLine = 0 }
    }
    $pair = $pairs[0]
    $valueText = $pair.Item2.Extent.Text.Trim()
    if ($valueText -ne '$false') {
        return [pscustomobject]@{ Status = 'Absent'; Message = ('enableFailedArchiveDeletion = ' + $valueText + ' — не мітигація #335, не змінюється'); StartLine = 0; EndLine = 0 }
    }
    $lines = [IO.File]::ReadAllLines($LocalConfigPath)
    $startLine = $pair.Item1.Extent.StartLineNumber
    $endLine = $pair.Item2.Extent.EndLineNumber
    $before = $lines[$startLine - 1].Substring(0, $pair.Item1.Extent.StartColumnNumber - 1)
    $after = $lines[$endLine - 1].Substring($pair.Item2.Extent.EndColumnNumber - 1)
    if ($before.Trim() -ne '' -or $after -notmatch '^\s*;?\s*(#.*)?$') {
        return [pscustomobject]@{ Status = 'Manual'; Message = ('мітигація #335 у рядку ' + $startLine + ' змішана з іншим текстом — приберіть її вручну'); StartLine = $startLine; EndLine = $endLine }
    }
    return [pscustomobject]@{ Status = 'Removable'; Message = ('мітигація #335 у BRAVO.local.config, рядок ' + $startLine); StartLine = $startLine; EndLine = $endLine }
}

function Remove-BRAVO52LinesPreservingEncoding {
    # Видаляє рядки [StartLine..EndLine] (з 1), зберігаючи BOM і стиль кінця рядка.
    param([string]$Path, [int]$StartLine, [int]$EndLine)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = (New-Object Text.UTF8Encoding($false)).GetString($bytes, $(if ($hasBom) { 3 } else { 0 }), $bytes.Length - $(if ($hasBom) { 3 } else { 0 }))
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.AddRange([string[]]($text -split "`r?`n"))
    $lines.RemoveRange($StartLine - 1, $EndLine - $StartLine + 1)
    [IO.File]::WriteAllText($Path, ($lines -join $newline), (New-Object Text.UTF8Encoding($hasBom)))
}

function Invoke-BRAVO52Setup {
    # Запуск BRAVO_SETUP у каталозі комплекту; повертає код завершення.
    param([string]$Root, [string[]]$Arguments)
    Push-Location $Root
    try {
        $global:LASTEXITCODE = 0
        & (Join-Path $Root 'BRAVO_SETUP.ps1') @Arguments
        return [int]$LASTEXITCODE
    } finally {
        Pop-Location
    }
}

function Write-BRAVO52Summary {
    param([hashtable]$Summary)
    try {
        $path = Join-Path $script:UpgradeRoot ('upgrade-summary-' + $script:Stamp + '.json')
        [IO.File]::WriteAllText($path, (New-Object psobject -Property $Summary | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
        Write-Note ('підсумок: ' + $path)
    } catch {
        Write-Warn2 ('підсумок не записано: ' + $_.Exception.Message)
    }
}

# Self-test завантажує функції цього файлу без виконання основного блоку.
# Змінні $script: задаються нижче, щоб dot-source не писав у область викликача.
if ($MyInvocation.InvocationName -eq '.') { return }

$script:ExitCode = 1
$script:TranscriptStarted = $false
$script:UpdaterPath = Join-Path $PSScriptRoot 'Update-BRAVOServer.ps1'
$script:DefaultRuntimeRoot = Join-Path $env:ProgramFiles 'BRAVO-Toolkit'
$script:UpgradeRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'BRAVO\Upgrade'

function Invoke-BRAVO52Upgrade {
# Основний блок — функція: return у гілках UAC і -CheckOnly виходить з неї,
# а не зі скрипта, тож exit нижче завжди повертає $script:ExitCode.
$script:Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$summary = @{
    computer   = $env:COMPUTERNAME
    startedAt  = (Get-Date).ToString('o')
    targetTag  = $Tag
    mode       = $(if ($CheckOnly) { 'CheckOnly' } else { 'Update' })
    result     = 'NotStarted'
}

try {
    $isElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $CheckOnly -and -not $isElevated) {
        if ($NoElevation -or -not [Environment]::UserInteractive) {
            throw 'Потрібні права адміністратора. Запустіть UPDATE-BRAVO52.cmd або PowerShell від імені адміністратора.'
        }
        Write-Note 'права не підняті — запит UAC і перезапуск в елевованій консолі'
        $argumentParts = New-Object System.Collections.Generic.List[string]
        # Process-scope Bypass, як у UPDATE-BRAVO52.cmd: пакет оновлення
        # приходить з інтернету, і RemoteSigned заблокував би його скрипти.
        foreach ($fixed in @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Tag', ('"' + $Tag + '"'))) {
            [void]$argumentParts.Add($fixed)
        }
        if (-not [string]::IsNullOrWhiteSpace($RuntimeRoot)) { [void]$argumentParts.Add('-RuntimeRoot'); [void]$argumentParts.Add('"' + $RuntimeRoot + '"') }
        if ($KeepMitigation335) { [void]$argumentParts.Add('-KeepMitigation335') }
        if ($AllowUntestedSource) { [void]$argumentParts.Add('-AllowUntestedSource') }
        if ($NoPause) { [void]$argumentParts.Add('-NoPause') }
        [void]$argumentParts.Add('-NoElevation')
        $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $elevated = Start-Process -FilePath $powerShellPath -ArgumentList ($argumentParts -join ' ') -Verb RunAs -Wait -PassThru
        if ($null -eq $elevated) { throw 'UAC-перезапуск не повернув об''єкт процесу — підняття прав не відбулося.' }
        $script:ExitCode = [int]$elevated.ExitCode
        if ($script:ExitCode -eq 0) { Write-Ok 'оновлення завершилось успішно (вивід — в елевованому вікні та журналі)' }
        else { Write-Bad ('елевований прогін завершився кодом ' + $script:ExitCode + ' — див. журнал у ' + $script:UpgradeRoot) }
        $summary = $null
        return
    }

    if (-not $CheckOnly) {
        [void][IO.Directory]::CreateDirectory($script:UpgradeRoot)
        $logPath = Join-Path $script:UpgradeRoot ('upgrade-' + $script:Stamp + '.log')
        Start-Transcript -LiteralPath $logPath | Out-Null
        $script:TranscriptStarted = $true
    }

    Write-Step ('Оновлення BRAVO-Toolkit до ' + $Tag + $(if ($CheckOnly) { ' — лише перевірка, нічого не змінюється' } else { '' }))

    if (-not (Test-Path -LiteralPath $script:UpdaterPath -PathType Leaf)) {
        throw ('Поруч немає Update-BRAVOServer.ps1 (' + $script:UpdaterPath + '). Скопіюйте пакет оновлення повністю.')
    }

    # --- Каталог комплекту і встановлена версія ------------------------------
    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        $found = Find-BRAVO52RuntimeRoot
        $RuntimeRoot = $found.Path
        Write-Ok ('каталог комплекту: ' + $RuntimeRoot + ' (' + $found.Source + ')')
    } else {
        Write-Ok ('каталог комплекту: ' + $RuntimeRoot + ' (вказано явно)')
    }
    $summary.runtimeRoot = $RuntimeRoot
    $versionPath = Join-Path $RuntimeRoot 'VERSION.json'
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
        throw ('У ' + $RuntimeRoot + ' немає VERSION.json — це не каталог комплекту BRAVO. Вкажіть правильний: -RuntimeRoot.')
    }
    # Пакет оновлення всередині комплекту: його скрипти Update-BRAVOServer.ps1
    # прийняв би за сторонні (guard 33) і зупинився б.
    if (Test-BRAVO52PathInside -Path $PSScriptRoot -Root $RuntimeRoot) {
        throw ('Пакет оновлення лежить усередині каталогу комплекту (' + $PSScriptRoot + '). Перенесіть його в інше місце, напр. C:\Temp\BRAVO_UPDATE_PACK, і запустіть звідти.')
    }

    $currentVersion = [string]((Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8 | ConvertFrom-Json).packageVersion)
    $targetVersion = $Tag.TrimStart('v')
    $summary.fromVersion = $currentVersion
    Write-Ok ('встановлено: ' + $currentVersion)

    $decision = Get-BRAVO52UpgradeDecision -CurrentVersion $currentVersion -TargetVersion $targetVersion -AllowUntestedSource:$AllowUntestedSource
    if ($decision.Action -eq 'Stop') { throw $decision.Message }

    # --- Джерело архіву ------------------------------------------------------
    $localZip = Join-Path $PSScriptRoot ('BRAVO-Toolkit-' + $targetVersion + '.zip')
    $zipArguments = @{}
    if (Test-Path -LiteralPath $localZip -PathType Leaf) {
        foreach ($companion in @(($localZip + '.sha256'), (Join-Path $PSScriptRoot 'release-manifest.json'))) {
            if (-not (Test-Path -LiteralPath $companion -PathType Leaf)) {
                throw ('Поруч з архівом немає ' + (Split-Path -Leaf $companion) + ' — покладіть усі три ассети релізу (zip, .zip.sha256, release-manifest.json).')
            }
        }
        $zipArguments.ZipPath = $localZip
        Write-Ok ('архів: ' + $localZip + ' (локальний)')
    } else {
        Write-Ok ('архів: буде завантажено з GitHub Release ' + $Tag)
    }

    # --- Мітигація #335 ------------------------------------------------------
    $localConfigPath = Join-Path $RuntimeRoot 'BRAVO.local.config'
    $mitigation = Get-BRAVO52Mitigation335 -LocalConfigPath $localConfigPath
    $summary.mitigation335Before = $mitigation.Status
    switch ($mitigation.Status) {
        'Removable' { if ($KeepMitigation335) { Write-Note ($mitigation.Message + ' — лишиться (-KeepMitigation335)') } else { Write-Note ($mitigation.Message + ' — буде прибрано після оновлення') } }
        'Manual'    { Write-Warn2 $mitigation.Message }
        default     { Write-Note ('мітигація #335: ' + $mitigation.Message) }
    }

    if ($decision.Action -eq 'UpToDate') {
        Write-Ok $decision.Message
        $summary.result = 'UpToDate'
        $summary.toVersion = $currentVersion
    } elseif ($CheckOnly) {
        Write-Step 'Перевірку пройдено (-CheckOnly: нічого не змінено)'
        Write-Note $decision.Message
        Write-Note 'для оновлення запустіть UPDATE-BRAVO52.cmd (або цей скрипт без -CheckOnly)'
        $summary.result = 'CheckOnly'
        $script:ExitCode = 0
        $summary = $null
        return
    } else {
        # --- Оновлення комплекту ---------------------------------------------
        Write-Step ('Оновлення комплекту: ' + $decision.Message)
        $global:LASTEXITCODE = -1
        & $script:UpdaterPath -RuntimeRoot $RuntimeRoot -Tag $Tag -NoElevation -NoPause @zipArguments
        $updaterCode = [int]$LASTEXITCODE
        $summary.updaterExitCode = $updaterCode
        if ($updaterCode -ne 0) {
            $summary.result = $(if ($updaterCode -eq 2) { 'RollbackFailed' } else { 'StoppedOrRolledBack' })
            $script:ExitCode = $(if ($updaterCode -eq 2) { 2 } else { 1 })
            throw ('Update-BRAVOServer.ps1 завершився кодом ' + $updaterCode + $(if ($updaterCode -eq 2) { ' — ВІДКАТ НЕ ВДАВСЯ, потрібне ручне втручання' } else { ' — комплект не змінено або відкочено' }) + '.')
        }
        $newVersion = [string]((Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8 | ConvertFrom-Json).packageVersion)
        $summary.toVersion = $newVersion
        $summary.result = 'Updated'
    }

    # --- Прибирання мітигації #335 -------------------------------------------
    $script:ExitCode = 0
    if ($CheckOnly) {
        # Вже актуальна версія з -CheckOnly: нічого не змінюється, навіть мітигація.
        Write-Step 'Перевірку пройдено (-CheckOnly: нічого не змінено)'
        $script:ExitCode = 0
        $summary = $null
        return
    }
    if ($mitigation.Status -eq 'Removable' -and -not $KeepMitigation335) {
        Write-Step 'Прибирання тимчасової мітигації #335'
        $copyPath = Join-Path $script:UpgradeRoot ('BRAVO.local.config.before-335-' + $script:Stamp)
        Copy-Item -LiteralPath $localConfigPath -Destination $copyPath -Force
        Write-Note ('копія: ' + $copyPath)
        Remove-BRAVO52LinesPreservingEncoding -Path $localConfigPath -StartLine $mitigation.StartLine -EndLine $mitigation.EndLine
        $validateCode = Invoke-BRAVO52Setup -Root $RuntimeRoot -Arguments @('-ValidateOnly', '-NoPause')
        if ($validateCode -eq 0 -or $validateCode -eq 10) {
            Write-Ok ('рядок прибрано, BRAVO_SETUP -ValidateOnly: exit ' + $validateCode)
            $summary.mitigation335After = 'Removed'
        } else {
            Copy-Item -LiteralPath $copyPath -Destination $localConfigPath -Force
            Write-Bad ('BRAVO_SETUP -ValidateOnly після правки: exit ' + $validateCode + ' — BRAVO.local.config повернуто з копії')
            $summary.mitigation335After = 'RestoredAfterValidationFailure'
            $script:ExitCode = 3
        }
    } elseif ($mitigation.Status -eq 'Manual') {
        $summary.mitigation335After = 'Manual'
        $script:ExitCode = 3
    }

    Write-Step 'ГОТОВО'
    Write-Host ('  версія:  ' + $summary.fromVersion + ' -> ' + $summary.toVersion)
    if ($script:ExitCode -eq 3) {
        Write-Warn2 'Комплект оновлено, але мітигацію #335 треба прибрати вручну (див. вище).'
    }
    if ($summary.result -eq 'Updated') {
        Write-Warn2 'Перевірте перший нічний прогін: архівацію, Health і обслуговування.'
        Write-Warn2 'Backup комплекту (<каталог>.old_*) не видаляється автоматично — приберіть його після успішної доби.'
    }
} catch {
    Write-Host ''
    Write-Host ('ЗУПИНЕНО: ' + $_.Exception.Message) -ForegroundColor Red
    if ($script:ExitCode -eq 0) { $script:ExitCode = 1 }
    if ($null -ne $summary -and $summary.result -in @('NotStarted', 'Updated')) { $summary.result = 'Stopped' }
    if ($null -ne $summary) { $summary.error = $_.Exception.Message }
} finally {
    if ($null -ne $summary -and -not $CheckOnly) {
        $summary.finishedAt = (Get-Date).ToString('o')
        $summary.exitCode = $script:ExitCode
        Write-BRAVO52Summary -Summary $summary
    }
    if ($script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
    Wait-BRAVO52Completion
}
}

Invoke-BRAVO52Upgrade
exit $script:ExitCode
