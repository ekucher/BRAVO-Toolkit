# BRAVO.Update.Validation — частина модуля BRAVO.Update (див. BRAVO.Update.psm1).
#
# Перевірка після розгортання / відкату / чистого встановлення / repair
# (ENGINE_DESIGN.md, розділ 6). Усі зовнішні запуски (guard, BRAVO_SETUP,
# self-test, credentials) ідуть ЛИШЕ через adapter контексту: BRAVO_SETUP
# ніколи не виконується в процесі engine (Complete-BRAVOHelperLog викликає
# exit, F4/§11). Функція нічого не змінює на диску, окрім логів дочірніх
# процесів (їх пише adapter у <OperationDirectory>\logs після маскування).

function New-BRAVOUpdateValidationItem {
    # Елемент validation[] за CONTRACTS §7: { name, status Pass|Warn|Fail|Skipped, message }.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Pass', 'Warn', 'Fail', 'Skipped')][string]$Status,
        [string]$Message = ''
    )

    return [pscustomobject][ordered]@{
        name    = $Name
        status  = $Status
        message = $Message
    }
}

function Get-BRAVOUpdateValidationAdapterCall {
    # Викликає adapter-scriptblock за ключем; будь-яка відсутність/виняток —
    # fail closed: повертає { Ok = $false; Message } (викликач робить Fail).
    # LogPath передається другим позиційним аргументом: stub-адаптери з одним
    # параметром його ігнорують, production-адаптер пише туди замаскований лог.
    [CmdletBinding()]
    param(
        [AllowNull()]$Adapter,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RuntimeRoot,
        [AllowEmptyString()][string]$LogPath = ''
    )

    $block = Get-BRAVOUpdatePropertyValue -InputObject $Adapter -Name $Key
    if ($null -eq $block -or $block -isnot [scriptblock]) {
        return [pscustomobject]@{ Ok = $false; Result = $null; Message = "adapter не надає '$Key' (fail closed)"; TreeNotContained = $false }
    }
    try {
        $result = & $block $RuntimeRoot $LogPath
    } catch {
        return [pscustomobject]@{ Ok = $false; Result = $null; Message = ("'{0}' завершився винятком: {1}" -f $Key, $_.Exception.Message); TreeNotContained = $false }
    }
    $hasExit = $null -ne $result -and (Test-BRAVOUpdateHasProperty -InputObject $result -Name 'ExitCode')
    if (-not $hasExit) {
        return [pscustomobject]@{ Ok = $false; Result = $null; Message = "'$Key' повернув результат без ExitCode (fail closed)"; TreeNotContained = $false }
    }
    return [pscustomobject]@{ Ok = $true; Result = $result; Message = ''; TreeNotContained = [bool](Get-BRAVOUpdatePropertyValue -InputObject $result -Name 'TreeNotContained' -Default $false) }
}

function Test-BRAVODeploymentValidation {
    <#
    .SYNOPSIS
        Перевіряє розгорнутий runtime після Deploy/Rollback/Install/Repair.
    .DESCRIPTION
        Повертає { Status Pass|Warn|Fail, Items[] }. Items — validation[] за
        CONTRACTS §7. Усі перевірки виконуються (без раннього виходу), щоб
        оператор бачив повну картину; будь-який Fail дає Status = Fail.
        Режими:
          Install  SetupValidate-збій -> Warn (credentials ще не введено);
                   додатково TestCredentialPresence (Missing/Unknown -> Warn).
          Rollback Guard порівнюється з GuardBaselineExitCode, якщо його
                   передано (на Repair-rollback guard міг бути не 0 ще до
                   операції); повний self-test не запускається.
          Deploy/Repair  Guard має бути 0.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][ValidateSet('Deploy', 'Rollback', 'Install', 'Repair')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [Parameter(Mandatory = $true)][string]$ExpectedManifestPath,
        [Parameter(Mandatory = $true)][AllowNull()]$SiteBaseline,
        [AllowNull()][object]$GuardBaselineExitCode = $null,
        # Код BRAVO_SETUP -ValidateOnly ДО операції (Repair-rollback): runtime відновлено
        # побайтово до пошкодженого стану, тож збій setup, що збігається з baseline, не є
        # збоєм відкату (як і guard).
        [AllowNull()][object]$SetupValidateBaselineExitCode = $null
    )

    $items = New-Object System.Collections.Generic.List[object]
    $treeFlags = @{ Tree = $false }
    $adapter = Get-BRAVOUpdatePropertyValue -InputObject $Context -Name 'Adapter'
    $paths = Get-BRAVOUpdatePropertyValue -InputObject $Context -Name 'Paths'
    $runtimeRoot = [string](Get-BRAVOUpdatePropertyValue -InputObject $paths -Name 'RuntimeRoot' -Default '')
    $operationDirectory = [string](Get-BRAVOUpdatePropertyValue -InputObject $Context -Name 'OperationDirectory' -Default '')
    $plan = Get-BRAVOUpdatePropertyValue -InputObject $Context -Name 'Plan'

    # Без runtime-кореня нічого перевіряти: єдиний безпечний результат — Fail.
    if ([string]::IsNullOrWhiteSpace($runtimeRoot)) {
        [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'VersionJson' -Status 'Fail' -Message 'Context.Paths.RuntimeRoot не задано.'))
        return [pscustomobject]@{ Status = 'Fail'; Items = $items.ToArray(); TreeNotContained = $false }
    }

    $logPathFor = {
        param([string]$Name)
        if ([string]::IsNullOrWhiteSpace($operationDirectory)) { return '' }
        return (Join-Path (Join-Path $operationDirectory 'logs') ('validate-' + $Name.ToLowerInvariant() + '.log'))
    }

    # --- VersionJson ---
    & {
        $versionPath = Join-Path $runtimeRoot 'VERSION.json'
        if (-not [IO.File]::Exists($versionPath)) {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'VersionJson' -Status 'Fail' -Message 'VERSION.json відсутній у runtime.'))
            return
        }
        $installed = ''
        try {
            $meta = [IO.File]::ReadAllText($versionPath) | ConvertFrom-Json
            $installed = [string](Get-BRAVOUpdatePropertyValue -InputObject $meta -Name 'packageVersion' -Default '')
        } catch {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'VersionJson' -Status 'Fail' -Message ('VERSION.json не розбирається: ' + $_.Exception.Message)))
            return
        }
        $installed = $installed.Trim()
        if ($installed -eq $ExpectedVersion) {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'VersionJson' -Status 'Pass' -Message ("Версія $installed відповідає очікуваній.")))
        } else {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'VersionJson' -Status 'Fail' -Message ("У runtime версія '$installed', очікувано '$ExpectedVersion'.")))
        }
    }

    # --- RuntimeManifest: дзеркало (хеші + сторонні скрипти), не лише код guard ---
    & {
        if (-not [IO.File]::Exists($ExpectedManifestPath)) {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'RuntimeManifest' -Status 'Fail' -Message 'Очікуваний RUNTIME_MANIFEST.json відсутній.'))
            return
        }
        try {
            # Site-owned каталоги беруться з єдиного джерела (Plan), не копіюються.
            $owned = Get-BRAVOUpdateSiteOwnedPaths
            $match = Test-BRAVODeployRuntimeMatchesManifest -RuntimeRoot $runtimeRoot -ManifestPath $ExpectedManifestPath -ExcludeDirs @($owned.Dirs)
        } catch {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'RuntimeManifest' -Status 'Fail' -Message ('Перевірку маніфесту не виконано: ' + $_.Exception.Message)))
            return
        }
        if ($match.IsMatch) {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'RuntimeManifest' -Status 'Pass' -Message 'Runtime збігається з маніфестом.'))
        } else {
            $shown = @($match.Problems | Select-Object -First 5) -join '; '
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'RuntimeManifest' -Status 'Fail' -Message ('Розбіжності з маніфестом (' + @($match.Problems).Count + '): ' + $shown)))
        }
    }

    # --- Guard ---
    & {
        $call = Get-BRAVOUpdateValidationAdapterCall -Adapter $adapter -Key 'InvokeGuard' -RuntimeRoot $runtimeRoot -LogPath (& $logPathFor 'Guard')
        if ($call.TreeNotContained) { $treeFlags.Tree = $true; [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'Guard' -Status 'Fail' -Message 'Scheduler.ProcessTreeNotContained: дерево дочірніх процесів не підтверджено завершеним, невідомий процес міг змінювати встановлення.')); return }
        if (-not $call.Ok) {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'Guard' -Status 'Fail' -Message $call.Message))
            return
        }
        $timedOut = [bool](Get-BRAVOUpdatePropertyValue -InputObject $call.Result -Name 'TimedOut' -Default $false)
        $code = [int]$call.Result.ExitCode
        if ($timedOut) {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'Guard' -Status 'Fail' -Message 'Guard не завершився за таймаут.'))
            return
        }
        $expectedCode = 0
        $baselineUsed = $false
        if ($Mode -eq 'Rollback' -and $null -ne $GuardBaselineExitCode) {
            $expectedCode = [int]$GuardBaselineExitCode
            $baselineUsed = $true
        }
        if ($code -eq $expectedCode) {
            $suffix = if ($baselineUsed) { ' (збігається з baseline до операції)' } else { '' }
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'Guard' -Status 'Pass' -Message ("Guard завершився з кодом $code$suffix.")))
        } else {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'Guard' -Status 'Fail' -Message ("Guard завершився з кодом $code, очікувано $expectedCode.")))
        }
    }

    # --- SetupValidate ---
    & {
        $call = Get-BRAVOUpdateValidationAdapterCall -Adapter $adapter -Key 'InvokeSetupValidate' -RuntimeRoot $runtimeRoot -LogPath (& $logPathFor 'SetupValidate')
        if ($call.TreeNotContained) { $treeFlags.Tree = $true; [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'SetupValidate' -Status 'Fail' -Message 'Scheduler.ProcessTreeNotContained: дерево дочірніх процесів не підтверджено завершеним, невідомий процес міг змінювати встановлення.')); return }
        # На чистому встановленні credentials ще не введено: збій — лише Warn.
        $failStatus = if ($Mode -eq 'Install') { 'Warn' } else { 'Fail' }
        if (-not $call.Ok) {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'SetupValidate' -Status $failStatus -Message $call.Message))
            return
        }
        $timedOut = [bool](Get-BRAVOUpdatePropertyValue -InputObject $call.Result -Name 'TimedOut' -Default $false)
        $code = [int]$call.Result.ExitCode
        if ($timedOut) {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'SetupValidate' -Status $failStatus -Message 'BRAVO_SETUP -ValidateOnly не завершився за таймаут.'))
            return
        }
        # Єдиний вердикт кодів BRAVO_SETUP: 0 PASS, 10 PASS_WITH_WARNING, інше FAIL.
        $verdict = Get-BRAVODeploySetupExitVerdict -ExitCode $code
        if ($verdict -eq 'PASS') {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'SetupValidate' -Status 'Pass' -Message 'BRAVO_SETUP -ValidateOnly: код 0.'))
        } elseif ($verdict -eq 'PASS_WITH_WARNING') {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'SetupValidate' -Status 'Warn' -Message 'BRAVO_SETUP -ValidateOnly: код 10 (попередження).'))
        } elseif (($Mode -eq 'Rollback') -and ($null -ne $SetupValidateBaselineExitCode) -and ($code -eq [int]$SetupValidateBaselineExitCode)) {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'SetupValidate' -Status 'Warn' -Message ("BRAVO_SETUP -ValidateOnly: код $code збігається з baseline до операції (runtime відновлено до попереднього, пошкодженого стану).")))
        } else {
            $note = if ($Mode -eq 'Install') { ' (credentials ще не введено — очікувано на чистому встановленні)' } else { '' }
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'SetupValidate' -Status $failStatus -Message ("BRAVO_SETUP -ValidateOnly: код $code$note.")))
        }
    }

    # --- SelfTest: лише якщо заплановано планом (Repair його пропускає); не для Rollback ---
    & {
        $planned = $false
        $tests = Get-BRAVOUpdatePropertyValue -InputObject $plan -Name 'tests'
        foreach ($test in @(Get-BRAVOUpdatePropertyValue -InputObject $tests -Name 'planned' -Default @())) {
            if ([string](Get-BRAVOUpdatePropertyValue -InputObject $test -Name 'id' -Default '') -eq 'SelfTest') { $planned = $true }
        }
        if ($Mode -eq 'Rollback') {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'SelfTest' -Status 'Skipped' -Message 'Після відкату повний self-test не запускається.'))
            return
        }
        if (-not $planned) {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'SelfTest' -Status 'Skipped' -Message 'Self-test не заплановано.'))
            return
        }
        $call = Get-BRAVOUpdateValidationAdapterCall -Adapter $adapter -Key 'InvokeSelfTest' -RuntimeRoot $runtimeRoot -LogPath (& $logPathFor 'SelfTest')
        if ($call.TreeNotContained) { $treeFlags.Tree = $true; [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'SelfTest' -Status 'Fail' -Message 'Scheduler.ProcessTreeNotContained: дерево дочірніх процесів не підтверджено завершеним, невідомий процес міг змінювати встановлення.')); return }
        if (-not $call.Ok) {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'SelfTest' -Status 'Fail' -Message $call.Message))
            return
        }
        $timedOut = [bool](Get-BRAVOUpdatePropertyValue -InputObject $call.Result -Name 'TimedOut' -Default $false)
        $code = [int]$call.Result.ExitCode
        if ($timedOut) {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'SelfTest' -Status 'Fail' -Message 'Self-test не завершився за таймаут.'))
        } elseif ($code -eq 0) {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'SelfTest' -Status 'Pass' -Message 'Self-test: код 0.'))
        } else {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'SelfTest' -Status 'Fail' -Message ("Self-test завершився з кодом $code.")))
        }
    }

    # --- SiteConfigPreserved: розбіжність baseline = Fail (E3) ---
    & {
        if ($null -eq (Get-Command -Name 'Test-BRAVOSiteConfigurationPreserved' -CommandType Function -ErrorAction SilentlyContinue)) {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'SiteConfigPreserved' -Status 'Fail' -Message 'Test-BRAVOSiteConfigurationPreserved недоступна (fail closed).'))
            return
        }
        try {
            $entry = Test-BRAVOSiteConfigurationPreserved -RuntimeRoot $runtimeRoot -Baseline $SiteBaseline
        } catch {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'SiteConfigPreserved' -Status 'Fail' -Message ('Перевірку конфігурації сайту не виконано: ' + $_.Exception.Message)))
            return
        }
        $entryStatus = [string](Get-BRAVOUpdatePropertyValue -InputObject $entry -Name 'status' -Default '')
        if (@('Pass', 'Warn', 'Fail', 'Skipped') -notcontains $entryStatus) {
            [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'SiteConfigPreserved' -Status 'Fail' -Message 'Test-BRAVOSiteConfigurationPreserved повернула нерозпізнаний результат.'))
            return
        }
        [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'SiteConfigPreserved' -Status $entryStatus -Message ([string](Get-BRAVOUpdatePropertyValue -InputObject $entry -Name 'message' -Default ''))))
    }

    # --- TestCredentialPresence: лише Install; секрет не читається ---
    if ($Mode -eq 'Install') {
        & {
            $probe = Get-BRAVOUpdatePropertyValue -InputObject $adapter -Name 'TestCredentialPresence'
            if ($null -eq $probe -or $probe -isnot [scriptblock]) {
                [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'TestCredentialPresence' -Status 'Warn' -Message 'adapter не надає TestCredentialPresence.'))
                return
            }
            try {
                $presence = & $probe $runtimeRoot 'Required'
            } catch {
                [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'TestCredentialPresence' -Status 'Warn' -Message ('Перевірку credentials не виконано: ' + $_.Exception.Message)))
                return
            }
            $state = [string](Get-BRAVOUpdatePropertyValue -InputObject $presence -Name 'Presence' -Default 'Unknown')
            if ($state -eq 'Found') {
                [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'TestCredentialPresence' -Status 'Pass' -Message 'Обов''язкові credentials знайдено.'))
            } else {
                [void]$items.Add((New-BRAVOUpdateValidationItem -Name 'TestCredentialPresence' -Status 'Warn' -Message ("Credentials: $state. Введіть їх інтерактивно через BRAVO_CREDENTIALS_SETUP.ps1.")))
            }
        }
    }

    $status = 'Pass'
    foreach ($item in $items) {
        if ($item.status -eq 'Fail') { $status = 'Fail'; break }
        if ($item.status -eq 'Warn') { $status = 'Warn' }
    }
    return [pscustomobject]@{ Status = $status; Items = $items.ToArray(); TreeNotContained = [bool]$treeFlags.Tree }
}
