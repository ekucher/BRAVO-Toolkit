# BRAVO.Configurator.Effective — обчислення Effective-значень через РЕАЛЬНИЙ
# canonical BRAVO_CONFIG_LOADER.ps1 (Import-BravoConfiguration), а не через
# переізобретену в GUI dependency-семантику.
#
# Design decision (docs/design/BRAVO_CONFIGURATOR_DESIGN.md §2): на момент
# написання цього модуля не було єдиної canonical чистої функції для
# SFTP/SMB/Health master-child ефективних значень — логіка була вбудована
# inline у кількох runtime-файлах. Цей модуль НЕ дублює ту логіку: він
# запускає справжній лоадер дочірнім процесом (Windows PowerShell 5.1, не
# pwsh) проти ІЗОЛЬОВАНОГО кандидатного BRAVO.local.config, і зчитує
# результат із тих самих $global:*Settings, які бачить production runtime.
# Це той самий підхід, що й production BRAVO_CONFIG_TEST.ps1 (-PassThru),
# лише розширений на повний набір груп налаштувань, потрібних UI.
#
# P0.7 reconciliation (5.2.2): canonical Get-BRAVOEffectiveStorageConfiguration
# / Get-BRAVOEffectiveSynchronizationConfiguration тепер існують
# (modules/BRAVO.Discovery), але обчислюють лише вузьку підмножину (SFTP/
# SMB.Enabled + 4 залежні поля) — не повний 138-шляховий effective config,
# який UI потребує для КОЖНОГО налаштування. Дочірньо-процесний підхід
# лишається канонічним механізмом отримання ПОВНОГО effective config;
# змінено лише перелік захоплюваних $global:-змінних нижче — додано
# 'storageEffective'/'bazaSyncEffective', щоб Model-шар читав СПРАВЖНІ
# effective-значення й DisabledReason для master-gated полів із canonical
# структур, а не з $componentSettings (який завжди RAW і НІКОЛИ не
# мутується master-ом за дизайном) напряму.
#
# Продакшн BRAVO.local.config НІКОЛИ не читається і не пишеться цим
# модулем — лише ізольований тимчасовий кандидатний файл.

Set-StrictMode -Version 2.0

$script:CapturedGlobalNames = @(
    'bravoSettings', 'credentialSettings', 'hostInformationSettings',
    'pathSettings', 'maintenanceSettings', 'componentSettings',
    'consoleSettings', 'progressSettings', 'backupConsistency',
    'smbSettings', 'sftpDirectories', 'backupMonitoring', 'schedulerSettings',
    'LogLevel', 'logRetentionDays', 'archiveRetentionDays',
    'enableArchiveDeletion', 'minimumRetainedVerifiedBackups',
    'failedArchiveRetentionDays', 'enableFailedArchiveDeletion',
    'enableOrphanTempCleanup', 'orphanTempRetentionHours',
    'enableLunchArchiveCleanup', 'lunchArchiveCleanupPath',
    'lunchArchiveRetentionMonths', 'sftpHostTemplate', 'sftpPort',
    'sftpHostKey', 'sftpConnectionTimeoutSeconds',
    'effectiveLimsRoot', 'systemLogRoot', 'backupRootPath',
    # 5.2.2 reconciliation: canonical storage/synchronization effective-
    # resolvers (modules/BRAVO.Discovery). componentSettings саме по собі
    # завжди RAW (master ніколи не мутує дочірні прапорці) — тому
    # componentSettings.SFTP.ArchiveUpload/SMB.ArchiveCopy/
    # Synchronization.BAZA_APP_SFTP/BAZA_WWW_SFTP не можуть дати правильне
    # Effective-значення без цих двох структур. Захоплюємо canonical
    # результат напряму (включно з DisabledReason), а не переобчислюємо
    # master AND child самостійно.
    'storageEffective', 'bazaSyncEffective'
)

function New-BRAVOConfiguratorIsolatedConfigRoot {
    <#
    .SYNOPSIS
        Створює ізольований тимчасовий каталог із копією canonical
        BRAVO.config і (опційно) кандидатним BRAVO.local.config — ніколи не
        торкається production ConfigRoot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][hashtable]$CandidateOverrides
    )

    $sourceConfigPath = Join-Path $RuntimeRoot 'BRAVO.config'
    if (-not (Test-Path -LiteralPath $sourceConfigPath -PathType Leaf)) {
        throw "BRAVO.Configurator.Effective: canonical BRAVO.config не знайдено ('$sourceConfigPath')."
    }

    $isolatedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('BRAVO_CONFIGURATOR_EFFECTIVE_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $isolatedRoot -Force | Out-Null
    Copy-Item -LiteralPath $sourceConfigPath -Destination (Join-Path $isolatedRoot 'BRAVO.config') -Force

    if ($CandidateOverrides.Count -gt 0) {
        $localConfigLines = New-Object System.Collections.Generic.List[string]
        $localConfigLines.Add('@{')
        foreach ($key in $CandidateOverrides.Keys) {
            $literalValue = ConvertTo-BRAVOConfiguratorPowerShellLiteral -Value $CandidateOverrides[$key]
            $literalKey = [string]$key
            $localConfigLines.Add("    '$literalKey' = $literalValue")
        }
        $localConfigLines.Add('}')
        $localConfigText = [string]::Join([Environment]::NewLine, $localConfigLines)
        [IO.File]::WriteAllText((Join-Path $isolatedRoot 'BRAVO.local.config'), $localConfigText, (New-Object System.Text.UTF8Encoding($false)))
    }

    return [pscustomobject]@{ IsolatedRoot = $isolatedRoot }
}

function ConvertTo-BRAVOConfiguratorPowerShellLiteral {
    <#
    .SYNOPSIS
        Серіалізує .NET-значення в літерал data-only PowerShell hashtable
        (той самий рестрикт-мовний контракт, що й BRAVO.local.config).
    #>
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { return $(if ($Value) { '$true' } else { '$false' }) }
    if ($Value -is [int] -or $Value -is [long]) { return [string]$Value }
    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [float]) { return [string]$Value }
    # Fail-closed, не мовчазний recurse (P2-фікс за результатами незалежного
    # review): hashtable/IDictionary теж [System.Collections.IEnumerable], і
    # раніше потрапляв у гілку нижче — але піпа хеш-таблиці через
    # ForEach-Object повертає ЇЇ Ж САМУ як єдиний елемент (не пари
    # ключ/значення), тому рекурсивний виклик отримував той самий $Value і
    # йшов у нескінченну рекурсію до "call depth overflow". Документований
    # контракт BRAVO.local.config — плаский 'dot.path' = скаляр|масив;
    # вкладена hashtable ніколи не мала тут з'являтись, але
    # Merge-BRAVOConfiguratorCandidateOverrides зберігає preserved
    # unknown-ключі без перевірки типу, тому явна відмова тут потрібна.
    if ($Value -is [System.Collections.IDictionary]) {
        throw "BRAVO.Configurator.Effective: неможливо серіалізувати hashtable-значення в data-only BRAVO.local.config літерал (очікується скаляр або масив скалярів)."
    }
    if ($Value -is [array] -or $Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @($Value | ForEach-Object { ConvertTo-BRAVOConfiguratorPowerShellLiteral -Value $_ })
        return '@(' + [string]::Join(', ', $items) + ')'
    }
    $escaped = ([string]$Value) -replace "'", "''"
    return "'$escaped'"
}

function Invoke-BRAVOConfiguratorEffectiveComputation {
    <#
    .SYNOPSIS
        Запускає canonical Import-BravoConfiguration дочірнім процесом
        Windows PowerShell 5.1 проти ізольованого кандидатного конфігу й
        повертає результуючі $global:*Settings як structured object.
    .DESCRIPTION
        Fail-closed: будь-яка помилка лоадера (invalid override key,
        parser error, unsupported environment) кидає виняток із повним
        stderr/stdout дочірнього процесу — не повертає частковий/
        замовчуваний результат.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][hashtable]$CandidateOverrides,
        [int]$TimeoutSeconds = 120
    )

    $isolated = New-BRAVOConfiguratorIsolatedConfigRoot -RuntimeRoot $RuntimeRoot -CandidateOverrides $CandidateOverrides
    $isolatedRoot = $isolated.IsolatedRoot
    $resultJsonPath = Join-Path $isolatedRoot 'effective-result.json'
    $errorJsonPath = Join-Path $isolatedRoot 'effective-error.json'

    try {
        $childScriptPath = Join-Path $isolatedRoot 'Invoke-EffectiveChild.ps1'
        $capturedNamesLiteral = '@(' + (($script:CapturedGlobalNames | ForEach-Object { "'$_'" }) -join ', ') + ')'
        # RuntimeRoot — caller-supplied шлях (реальний BRAVO install root),
        # на відміну від $isolatedRoot/$resultJsonPath/$errorJsonPath (GUID-
        # засновані, безпечні). Апостроф у шляху (легальний NTFS-символ)
        # зламав би генерований single-quoted літерал нижче — той самий
        # escaping, що ConvertTo-BRAVOConfiguratorPowerShellLiteral уже
        # застосовує для значень (P2-фікс за результатами незалежного
        # review).
        $escapedRuntimeRoot = $RuntimeRoot -replace "'", "''"

        $childScriptLines = @(
            'Set-StrictMode -Version 2.0',
            '$ErrorActionPreference = ''Stop''',
            'try {',
            "    . (Join-Path '$escapedRuntimeRoot' 'BRAVO_CONFIG_LOADER.ps1')",
            "    `$null = Import-BravoConfiguration -ConfigRoot '$isolatedRoot' -RuntimeRoot '$escapedRuntimeRoot' -PassThru",
            "    `$capturedNames = $capturedNamesLiteral",
            '    $snapshot = [ordered]@{}',
            '    foreach ($name in $capturedNames) {',
            '        $variable = Get-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue',
            '        $snapshot[$name] = if ($null -ne $variable) { $variable.Value } else { $null }',
            '    }',
            "    `$snapshot | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath '$resultJsonPath' -Encoding UTF8",
            '} catch {',
            '    $errorDetail = [pscustomobject]@{ Message = $_.Exception.Message; ScriptStackTrace = $_.ScriptStackTrace }',
            "    `$errorDetail | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath '$errorJsonPath' -Encoding UTF8",
            '    exit 1',
            '}'
        )
        [IO.File]::WriteAllText($childScriptPath, [string]::Join([Environment]::NewLine, $childScriptLines), (New-Object System.Text.UTF8Encoding($false)))

        $processArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $childScriptPath)
        # -Wait без обмеження в часі дав би незавершуваному canonical
        # loader-у (напр. Resolve-BRAVOInstallationDiscovery зависає на
        # недоступному WMI/службі) шанс заблокувати Configurator назавжди.
        # -PassThru (без -Wait) + WaitForExit(timeout) — реальний, а не
        # оманливий таймаут-контракт: TimeoutSeconds раніше приймався, але
        # ніколи не застосовувався (PSSA PSReviewUnusedParameter це виявив).
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $processArgs -NoNewWindow -PassThru `
            -RedirectStandardOutput (Join-Path $isolatedRoot 'stdout.log') `
            -RedirectStandardError (Join-Path $isolatedRoot 'stderr.log')
        # Start-Process -PassThru БЕЗ -Wait: доступ до .Handle одразу після
        # старту — задокументований обхід .NET/PS-квірку, коли пізніше
        # читання .ExitCode повертає порожнє значення без цього дотику
        # (процес технічно ще не "прив'язаний" повністю до об'єкта).
        $null = $process.Handle
        $exited = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            # taskkill /T (process tree) — не лише сам powershell.exe: якщо
            # canonical loader завис усередині виклику зовнішнього
            # інструменту (WMI/service query — саме той сценарій, що
            # мотивував timeout), $process.Kill() прибирає тільки батька й
            # лишає осиротілий дочірній процес (P2-фікс за результатами
            # незалежного review).
            try { & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null } catch { <# найкраще-зусилля cleanup: процес міг уже завершитися сам між WaitForExit і цим викликом — свідомо не логуємо, кидати тут нема чим завадити fail-closed throw нижче #> }
            try { $process.Kill() } catch { <# те саме: Kill() на вже завершеному/недоступному процесі — очікувана гонитва, не помилка, яку варто діагностувати окремо від throw нижче #> }
            throw "BRAVO.Configurator.Effective: canonical loader не завершився за $TimeoutSeconds с — процес (і дерево процесів) примусово завершено (fail-closed, timeout)."
        }

        if ($process.ExitCode -ne 0 -or (Test-Path -LiteralPath $errorJsonPath -PathType Leaf)) {
            $stderrText = if (Test-Path -LiteralPath (Join-Path $isolatedRoot 'stderr.log')) { Get-Content -LiteralPath (Join-Path $isolatedRoot 'stderr.log') -Raw } else { '' }
            $errorDetailText = if (Test-Path -LiteralPath $errorJsonPath -PathType Leaf) { Get-Content -LiteralPath $errorJsonPath -Raw -Encoding UTF8 } else { '' }
            throw "BRAVO.Configurator.Effective: canonical loader завершився з помилкою (ExitCode=$($process.ExitCode)). $errorDetailText $stderrText"
        }

        if (-not (Test-Path -LiteralPath $resultJsonPath -PathType Leaf)) {
            throw 'BRAVO.Configurator.Effective: дочірній процес завершився без помилки, але результат відсутній — fail-closed.'
        }

        $resultJson = Get-Content -LiteralPath $resultJsonPath -Raw -Encoding UTF8
        $resultObject = ConvertFrom-Json -InputObject $resultJson
        return $resultObject
    }
    finally {
        # P2 (незалежний review, Agent D): -ErrorAction SilentlyContinue тут
        # свідомо, не недбало — AV lock/ще-не-звільнений handle на щойно
        # завершеному дочірньому процесі не повинні перетворювати успішний
        # Effective-результат на помилку. Рідкісний залишений
        # BRAVO_CONFIGURATOR_EFFECTIVE_*-каталог у %TEMP% — гігієнічний
        # артефакт (унікальний GUID, ніколи не використовується повторно,
        # ніякого секрету в ньому), не функціональний дефект.
        Remove-Item -LiteralPath $isolatedRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function @(
    'New-BRAVOConfiguratorIsolatedConfigRoot',
    'ConvertTo-BRAVOConfiguratorPowerShellLiteral',
    'Invoke-BRAVOConfiguratorEffectiveComputation'
)
