function ConvertTo-BRAVOAffectedPrintableText {
    <#
        Безпечний для друку текст: керувальні символи (включно з переводами
        рядка), C1, роздільники рядків і абзаців Unicode, керування
        напрямком тексту та BOM замінюються на \uXXXX.

        Навіщо: шляхи з git (-z) і рядки дочірнього процесу можуть містити
        перевід рядка. Без екранування такий шлях створив би окремий рядок
        stdout runner-а, який починається з маркера Self-Test, а саме цього
        runner не має права друкувати ніколи.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $Text.ToCharArray()) {
        $code = [int]$character
        $isControl = (
            $code -lt 32 -or $code -eq 127 -or ($code -ge 128 -and $code -le 159) -or
            $code -eq 8232 -or $code -eq 8233 -or ($code -ge 8234 -and $code -le 8238) -or
            ($code -ge 8294 -and $code -le 8297) -or $code -eq 65279)
        if ($isControl) {
            [void]$builder.Append('\u' + $code.ToString('X4'))
        } else {
            [void]$builder.Append($character)
        }
    }
    return $builder.ToString()
}

function New-BRAVOAffectedChildRequest {
    <#
        Будує запит на дочірній вибірковий прогін. Нічого не запускає.

        Команда: powershell.exe -NoLogo -NoProfile -NonInteractive
        -ExecutionPolicy <Bypass> -EncodedCommand <base64 UTF-16LE>, а тіло -
        try { [Console]::OutputEncoding = UTF-8 без BOM } catch { ... };
        & '<корінь>\BRAVO_SELF_TEST.ps1' -NoPause -Suite @('A','B'); exit $LASTEXITCODE

        Чому EncodedCommand, а не -File: у -File кома в списку suite
        розбирається як частина рядка, а не як масив. Імена suite - лише
        літери (перевіряється тут), шлях береться в одинарні лапки з
        подвоєнням усіх символів-одинарних лапок (у PowerShell ними є й
        типографські), керувальні символи в шляху відхиляються.
        Порожній -Suite не будується ніколи: порожній список - виняток.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Suite
    )

    $suiteName = [string[]]@($Suite)
    if ($suiteName.Count -eq 0) {
        throw 'Список suite порожній: прогін з порожнім -Suite не будується (порожній -Suite означав би повний прогін).'
    }
    foreach ($name in $suiteName) {
        if (-not [regex]::IsMatch([string]$name, '^[A-Za-z]+\z')) {
            throw ('Недопустиме ім''я suite (лише літери A-Z): ' + (ConvertTo-BRAVOAffectedPrintableText -Text ([string]$name)))
        }
    }
    if ([string]::IsNullOrEmpty($RepositoryRoot) -or [regex]::IsMatch($RepositoryRoot, '[\x00-\x1F\x7F]')) {
        throw 'Корінь репозиторію порожній або містить керувальні символи.'
    }

    $scriptPath = Join-Path ([IO.Path]::GetFullPath($RepositoryRoot)) 'BRAVO_SELF_TEST.ps1'
    $quotedPath = $scriptPath
    foreach ($quoteCode in @(39, 8216, 8217, 8218, 8219)) {
        $quoteText = [string][char]$quoteCode
        $quotedPath = $quotedPath.Replace($quoteText, $quoteText + $quoteText)
    }
    $suiteList = [string]::Join(',', @($suiteName | ForEach-Object { "'" + $_ + "'" }))
    # Дочірня консоль (CreateNoWindow) отримує OEM-сторінку, у якій немає
    # частини кирилиці (і, ґ), BOM і U+2028; тому дочірній процес перемикає
    # свій вивід на UTF-8 без BOM, а батько декодує потоки як UTF-8
    # (Invoke-BRAVOAffectedChildProcess). Обидва потоки перенаправлено,
    # тож WriteConsole не використовується і обмеження cp65001 на консолях
    # Windows до 10 (див. Test-BRAVOConsoleCodePageChangeSafe) тут не діє.
    # Якщо перемкнути не вдалося, вердикт не змінюється: маркер - ASCII.
    $encodingPrefix = 'try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList $false } catch { $null = $_ }; '
    $commandBody = $encodingPrefix + "& '" + $quotedPath + "' -NoPause -Suite @(" + $suiteList + "); exit `$LASTEXITCODE"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($commandBody))

    $systemRoot = [string]$env:SystemRoot
    $filePath = ''
    if ($systemRoot.Length -gt 0) {
        $filePath = Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    return [pscustomobject]@{
        FilePath       = $filePath
        Argument       = [string[]]@('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
        CommandBody    = $commandBody
        EncodedCommand = $encoded
        ScriptPath     = $scriptPath
        Suite          = $suiteName
    }
}

function Invoke-BRAVOAffectedChildProcess {
    <#
        Єдиний справжній запуск дочірнього прогону (SelfTestInvoker за
        замовчуванням). Повертає {ExitCode; Lines; ErrorLines; StartError}
        і НІКОЛИ не кидає виняток запуску: StartError заповнено, ExitCode
        $null - викликач трактує це як збій.

        stdout і stderr читаються окремо (stderr - асинхронно, щоб повний
        буфер одного потоку не блокував інший); потоки НЕ зливаються.
        Тайм-ауту немає свідомо: обрізати довгий прогін - означало б
        вигадати результат.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Request
    )

    $outcome = [pscustomobject]@{
        ExitCode   = $null
        Lines      = [string[]]@()
        ErrorLines = [string[]]@()
        StartError = $null
    }
    $filePath = [string]$Request.FilePath
    if ([string]::IsNullOrEmpty($filePath) -or -not [IO.File]::Exists($filePath)) {
        $outcome.StartError = 'Windows PowerShell 5.1 (powershell.exe) не знайдено за очікуваним шляхом: ' + $filePath
        return $outcome
    }
    if (-not [IO.File]::Exists([string]$Request.ScriptPath)) {
        $outcome.StartError = 'BRAVO_SELF_TEST.ps1 не знайдено: ' + [string]$Request.ScriptPath
        return $outcome
    }

    # Дочірній процес пише UTF-8 без BOM (див. New-BRAVOAffectedChildRequest);
    # кодування консолі батька тут не має значення.
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $filePath
    $startInfo.Arguments = [string]::Join(' ', [string[]]@($Request.Argument))
    $startInfo.WorkingDirectory = [IO.Path]::GetDirectoryName([string]$Request.ScriptPath)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $encoding
    $startInfo.StandardErrorEncoding = $encoding

    $splitLines = {
        param([string]$Text)
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($part in [regex]::Split($Text, '\r?\n')) { [void]$parts.Add([string]$part) }
        if ($parts.Count -gt 0 -and $parts[$parts.Count - 1].Length -eq 0) { $parts.RemoveAt($parts.Count - 1) }
        return , ([string[]]$parts.ToArray())
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $started = $false
    try {
        [void]$process.Start()
        $started = $true
        $process.StandardInput.Close()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stdout = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        $errorText = [string]$stderrTask.Result
        if ($errorText.StartsWith('#< CLIXML', [StringComparison]::Ordinal)) {
            # Потік помилок powershell.exe за -EncodedCommand і перенаправлених потоків приходить як CLIXML:
            # залишаємо лише тексти помилок, без службової розмітки.
            $decodedError = New-Object System.Collections.Generic.List[string]
            $unescape = [System.Text.RegularExpressions.MatchEvaluator]{ param($escaped) return [string][char][Convert]::ToInt32($escaped.Groups[1].Value, 16) }
            foreach ($errorMatch in [regex]::Matches($errorText, '<S S="Error">(.*?)</S>', [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
                $piece = [System.Net.WebUtility]::HtmlDecode($errorMatch.Groups[1].Value)
                [void]$decodedError.Add([regex]::Replace($piece, '_x([0-9A-Fa-f]{4})_', $unescape))
            }
            $errorText = [string]::Join("`n", $decodedError.ToArray())
        }
        $outcome.Lines = & $splitLines ([string]$stdout)
        $outcome.ErrorLines = & $splitLines $errorText
        $outcome.ExitCode = [int]$process.ExitCode
    } catch {
        $outcome.StartError = $_.Exception.Message
        $outcome.ExitCode = $null
        if ($started) {
            try {
                if (-not $process.HasExited) { $process.Kill() }
            } catch {
                # Процес уже завершився або недоступний; збій і так повернуто через StartError.
                $null = $_
            }
        }
    } finally {
        $process.Dispose()
    }
    return $outcome
}

function Invoke-BRAVOAffectedSelfTest {
    <#
        Runner Affected (VAL-05, PR3). Ланцюг:
          збирач шляхів -> супутник маніфесту -> план -> (лише V1/V2)
          дочірній прогін -Suite -> розбір маркера -> AFFECTED RESULT.

        Залежності (мусять бути завантажені викликачем): збирач
        (Get-BRAVOChangedPathSet), мапа й план (Get-BRAVOSelfTestAffectedPlan,
        Test-BRAVOSelfTestRuntimeManifestCompanion), канонічне рішення про
        gate паритету конфігурації (Test-BRAVOConfigParityRelevantPath).
        Жодної з цих політик тут не продубльовано.

        Результат: {ExitCode; ResultCode; Class; Suite; Line; ChildInvoked;
        ChildRequest; IsAcceptanceEvidence = $false}. ExitCode - лише 0
        (ResultCode = PARTIAL-OK) або 1; нової таблиці кодів немає. Line -
        рівно те, що надруковано оператору.

        Інваріанти:
          * клас V3 (і будь-який невідомий шлях) ніколи не запускає дочірній
            процес: ні Full, ні вибірковий прогін - runner друкує вимоги й
            AFFECTED RESULT: ESCALATED-V3;
          * збій збирача проходить без змін (той самий код), план не
            обчислюється;
          * код завершення 0 лише за коду 0 дочірнього прогону, рівно одного
            рядка маркера вибіркового прогону з очікуваним переліком і
            жодного іншого рядка з маркером Self-Test;
          * жоден рядок stdout runner-а не починається з маркера Self-Test:
            рядки дочірнього процесу друкуються з префіксом "child| ", а
            рядки-маркери - лише розібраними;
          * план - не acceptance: runner не друкує маркера повного прогону.

        -GitInvoker передається збирачу; -SelfTestInvoker отримує запит
        (New-BRAVOAffectedChildRequest) і повертає {ExitCode; Lines}.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$BaseRef,

        [Parameter()]
        [scriptblock]$GitInvoker,

        [Parameter()]
        [scriptblock]$SelfTestInvoker
    )

    foreach ($requiredFunction in @('Get-BRAVOChangedPathSet', 'Get-BRAVOSelfTestAffectedPlan', 'Test-BRAVOSelfTestRuntimeManifestCompanion', 'Test-BRAVOConfigParityRelevantPath')) {
        if ($null -eq (Get-Command -Name $requiredFunction -CommandType Function -ErrorAction SilentlyContinue)) {
            throw ('Не завантажено залежність runner-а Affected: ' + $requiredFunction)
        }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $emit = {
        param([string]$Text)
        [void]$lines.Add($Text)
        Write-Host $Text
    }
    $safe = {
        param($Value)
        return (ConvertTo-BRAVOAffectedPrintableText -Text ([string]$Value))
    }
    $shown = {
        param($Value)
        if ([string]::IsNullOrEmpty([string]$Value)) { return 'n/a' }
        return (& $safe $Value)
    }
    $member = {
        param($Object, [string]$Name)
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return , $Object[$Name] }
            return $null
        }
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return , $property.Value }
        return $null
    }

    $planClass = $null
    $planSuite = [string[]]@()
    $childInvoked = $false
    $childRequest = $null
    $finish = {
        param([string]$Code)
        & $emit ('AFFECTED RESULT: ' + $Code)
        $exitCode = 1
        if ($Code -ceq 'PARTIAL-OK') { $exitCode = 0 }
        return [pscustomobject]@{
            ExitCode             = $exitCode
            ResultCode           = $Code
            Class                = $planClass
            Suite                = [string[]]@($planSuite)
            Line                 = [string[]]@($lines.ToArray())
            ChildInvoked         = $childInvoked
            ChildRequest         = $childRequest
            IsAcceptanceEvidence = $false
        }
    }

    & $emit ('AFFECTED POWERSHELL: ' + $PSVersionTable.PSVersion.ToString())

    # --- 1. збирач шляхів ------------------------------------------------------
    $collectorArgument = @{ RepositoryRoot = $RepositoryRoot; BaseRef = $BaseRef }
    if ($null -ne $GitInvoker) { $collectorArgument['GitInvoker'] = $GitInvoker }
    $changeSet = $null
    $collectorError = ''
    try {
        $changeSet = @(Get-BRAVOChangedPathSet @collectorArgument)
    } catch {
        $collectorError = $_.Exception.Message
    }
    $failureCodes = @('BASE-MISSING', 'BASE-INVALID', 'BASE-EQUALS-HEAD', 'EMPTY-DIFF', 'GIT-MISSING', 'GIT-FAILED', 'NOT-A-REPOSITORY', 'ROOT-MISMATCH', 'SHALLOW-REPOSITORY', 'NO-MERGE-BASE')
    if ($null -eq $changeSet -or $changeSet.Count -ne 1 -or $null -eq $changeSet[0]) {
        & $emit 'AFFECTED BASE: n/a'
        & $emit 'AFFECTED MERGE-BASE: n/a'
        & $emit 'AFFECTED HEAD: n/a'
        & $emit 'AFFECTED DIRTY: n/a'
        & $emit ('AFFECTED ERROR: збирач шляхів не повернув результат: ' + (& $safe $collectorError))
        return (& $finish 'GIT-FAILED')
    }
    $changeSet = $changeSet[0]
    $dirtyText = 'false'
    if ($changeSet.Dirty -eq $true) { $dirtyText = 'true' }
    & $emit ('AFFECTED BASE: ' + (& $shown $changeSet.BaseSha))
    & $emit ('AFFECTED MERGE-BASE: ' + (& $shown $changeSet.MergeBaseSha))
    & $emit ('AFFECTED HEAD: ' + (& $shown $changeSet.HeadSha))
    & $emit ('AFFECTED DIRTY: ' + $dirtyText)

    $status = [string]$changeSet.Status
    if ($status -cne 'Ok') {
        $failureCode = $status
        if ($failureCodes -cnotcontains $status) { $failureCode = 'GIT-FAILED' }
        & $emit ('AFFECTED ERROR: ' + $failureCode + ': ' + (& $safe $changeSet.Message))
        return (& $finish $failureCode)
    }
    $changed = [string[]]@($changeSet.ChangedPath)
    $deleted = [string[]]@($changeSet.DeletedPath)
    if ($changed.Count -eq 0) {
        & $emit 'AFFECTED ERROR: збирач повернув Ok без жодного шляху: порожній набір не є планом.'
        return (& $finish 'GIT-FAILED')
    }

    # --- 2. план -----------------------------------------------------------------
    $plan = $null
    $planError = ''
    try {
        $companion = Test-BRAVOSelfTestRuntimeManifestCompanion -BaseText $changeSet.RuntimeManifestBaseText -CurrentText $changeSet.RuntimeManifestCurrentText -ChangedPath $changed
        $plan = Get-BRAVOSelfTestAffectedPlan -ChangedPath $changed -DeletedPath $deleted -RuntimeManifestCompanion $companion
    } catch {
        $planError = $_.Exception.Message
    }
    $planUsable = ($null -ne $plan -and [string]$plan.Status -ceq 'Planned' -and @('V1', 'V2', 'V3') -ccontains [string]$plan.Class)
    $effectiveClass = 'V3'
    $effectiveSuite = [string[]]@()
    if ($planUsable -and [string]$plan.Class -cne 'V3') {
        $effectiveClass = [string]$plan.Class
        $effectiveSuite = [string[]]@($plan.Suite)
        if ($effectiveSuite.Count -eq 0) {
            # Клас V1/V2 без жодного suite не може бути запуском: fail closed до V3.
            $effectiveClass = 'V3'
            $planError = 'план нижчого за V3 класу не містить жодного suite'
        }
    }
    $planClass = $effectiveClass
    $planSuite = $effectiveSuite

    $label = ''
    if ($null -ne $plan) { $label = [string]$plan.ClassLabel }
    $classLine = 'AFFECTED CLASS: ' + $effectiveClass
    if ($label.Length -gt 0) { $classLine = $classLine + ' (' + (& $safe $label) + ')' }
    & $emit $classLine
    $suiteText = '(немає)'
    if ($effectiveSuite.Count -gt 0) { $suiteText = [string]::Join(',', $effectiveSuite) }
    & $emit ('AFFECTED SUITES: ' + (& $safe $suiteText))
    & $emit ('AFFECTED PATHS: ' + $changed.Count + ' (видалено: ' + $deleted.Count + ')')
    if ($planError.Length -gt 0) {
        & $emit ('AFFECTED ERROR: план не є придатним для запуску: ' + (& $safe $planError))
    }

    # --- 3. метадані gate-ів і нагадування --------------------------------------
    $gates = New-Object System.Collections.Generic.List[string]
    if ($planUsable) {
        foreach ($planGate in @($plan.RequiredGate)) {
            if (-not $gates.Contains([string]$planGate)) { [void]$gates.Add([string]$planGate) }
        }
    }
    # Рішення про gate паритету конфігурації належить канонічній функції; збій рішення - вважати релевантним.
    $parityRelevant = $true
    try {
        $parity = Test-BRAVOConfigParityRelevantPath -ChangedPath ([string[]]@($changed + $deleted))
        $parityRelevant = ([bool]$parity.IsRelevant)
    } catch {
        $parityRelevant = $true
    }
    if ($parityRelevant -and -not $gates.Contains('Config parity')) { [void]$gates.Add('Config parity') }
    foreach ($gateName in $gates) {
        & $emit ('AFFECTED GATE: ' + (& $safe $gateName))
    }
    & $emit "AFFECTED NOTICE: Класифікація PR на рівні рев'ю все одно обов'язкова: тригери V3 (security/integrity, trust boundary, credentials, harness, config contract, packaging/release, широкий граф) можуть підвищити клас"
    & $emit 'AFFECTED NOTICE: Affected не є acceptance: вибірковий прогін не замінює Full Self-Test'

    # --- 4. клас V3: вимоги без запуску ----------------------------------------
    if ($effectiveClass -ceq 'V3') {
        & $emit 'AFFECTED REQUIRE: Full Self-Test REQUIRED before acceptance: .\BRAVO_SELF_TEST.ps1 -NoPause'
        & $emit "AFFECTED REQUIRE: Критерій Full: код завершення 0, дослівний маркер повного прогону з RELEASE_CHECKLIST.md і жодного рядка [НЕДОСТУПНО]"
        & $emit "AFFECTED REQUIRE: Обов'язкові перевірки CI з RELEASE_POLICY.md §13.3 - за посиланням; runner їх не виконує і не підтверджує"
        & $emit "AFFECTED REQUIRE: Незалежне рев'ю обов'язкове для класу V3"
        & $emit 'AFFECTED REQUIRE: Runner НЕ запускає Full і НЕ запускає вибірковий -Suite для класу V3'
        if ($planUsable) {
            foreach ($row in @($plan.Decision)) {
                if ([string]$row.Class -ceq 'V3') {
                    & $emit ('AFFECTED UNKNOWN PATH: ' + (& $safe $row.Path) + ' - ' + (& $safe $row.Reason))
                }
            }
        }
        return (& $finish 'ESCALATED-V3')
    }
    if ($effectiveClass -ceq 'V2') {
        & $emit 'AFFECTED REQUIRE: Full Self-Test REQUIRED before acceptance: .\BRAVO_SELF_TEST.ps1 -NoPause'
    } else {
        & $emit 'AFFECTED NOTICE: Full Self-Test не звільняється цим runner-ом; рішення - за класифікацією PR (docs/design/BRAVO_VALIDATION_ARCHITECTURE.md)'
    }

    # --- 5. дочірній вибірковий прогін ------------------------------------------
    try {
        $childRequest = New-BRAVOAffectedChildRequest -RepositoryRoot $RepositoryRoot -Suite $effectiveSuite
    } catch {
        & $emit ('AFFECTED ERROR: запит на дочірній прогін не побудовано: ' + (& $safe $_.Exception.Message))
        return (& $finish 'CHILD-FAILED')
    }
    $childInvoked = $true
    & $emit ('AFFECTED CHILD: вибірковий прогін -Suite ' + [string]::Join(',', $effectiveSuite))
    $answer = $null
    $childProblem = ''
    $raw = @()
    try {
        if ($null -ne $SelfTestInvoker) {
            $raw = @(& $SelfTestInvoker $childRequest)
        } else {
            $raw = @(Invoke-BRAVOAffectedChildProcess -Request $childRequest)
        }
        if ($raw.Count -ne 1 -or $null -eq $raw[0]) {
            $childProblem = 'виклик дочірнього прогону мусить повернути рівно один об''єкт {ExitCode; Lines}'
        } else {
            $answer = $raw[0]
        }
    } catch {
        $childProblem = $_.Exception.Message
    }
    $childExit = $null
    $childLines = @()
    $childErrorLines = @()
    if ($childProblem.Length -eq 0) {
        $startError = & $member $answer 'StartError'
        $childExit = & $member $answer 'ExitCode'
        $linesValue = & $member $answer 'Lines'
        $errorValue = & $member $answer 'ErrorLines'
        if (-not [string]::IsNullOrEmpty([string]$startError)) {
            $childProblem = 'дочірній прогін не стартував: ' + [string]$startError
        } elseif (-not ($childExit -is [int])) {
            $childProblem = 'відповідь дочірнього прогону без цілочисельного ExitCode'
        }
        if ($null -ne $linesValue) { $childLines = @(@($linesValue) | ForEach-Object { [string]$_ }) }
        if ($null -ne $errorValue) { $childErrorLines = @(@($errorValue) | ForEach-Object { [string]$_ }) }
    }
    if ($childProblem.Length -gt 0) {
        & $emit ('AFFECTED ERROR: ' + (& $safe $childProblem))
        return (& $finish 'CHILD-FAILED')
    }

    # Відлуння: звичайні рядки - з префіксом; рядки-маркери - лише розібраними.
    $partialList = New-Object System.Collections.Generic.List[string]
    $otherMarkers = 0
    foreach ($element in $childLines) {
        foreach ($physical in [regex]::Split([string]$element, '\r\n|\n|\r')) {
            $text = [string]$physical
            if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
            # Маркером вважається будь-який рядок, що після пробілів починається з
            # SELF-TEST у будь-якому регістрі: інакше "  self-test passed" пройшов би
            # як шум. PARTIAL зараховується лише в точній канонічній формі.
            if ([regex]::IsMatch($text, '(?i)^\s*SELF-TEST')) {
                $partial = [regex]::Match($text, '^SELF-TEST PARTIAL: ([A-Za-z]+(,[A-Za-z]+)*)\z')
                if ($partial.Success) {
                    [void]$partialList.Add($partial.Groups[1].Value)
                    & $emit ('AFFECTED CHILD MARKER: PARTIAL ' + $partial.Groups[1].Value)
                } else {
                    $kind = [regex]::Match($text, '(?i)^\s*SELF-TEST ([A-Z]{1,16})\b')
                    $kindText = 'OTHER'
                    if ($kind.Success) { $kindText = $kind.Groups[1].Value.ToUpperInvariant() }
                    $otherMarkers++
                    & $emit ('AFFECTED CHILD MARKER: UNEXPECTED (' + $kindText + ')')
                }
            } else {
                & $emit ('child| ' + (& $safe $text))
            }
        }
    }
    foreach ($element in $childErrorLines) {
        foreach ($physical in [regex]::Split([string]$element, '\r\n|\n|\r')) {
            & $emit ('child!| ' + (& $safe $physical))
        }
    }

    # --- 6. вердикт -----------------------------------------------------------------
    if ([int]$childExit -ne 0) {
        & $emit ('AFFECTED ERROR: дочірній прогін завершився з кодом ' + [int]$childExit)
        return (& $finish 'CHILD-FAILED')
    }
    $expectedList = [string]::Join(',', $effectiveSuite)
    if ($partialList.Count -eq 1 -and $otherMarkers -eq 0 -and $partialList[0] -ceq $expectedList) {
        & $emit 'AFFECTED NOTICE: Вибірковий прогін завершено; це не acceptance, Full Self-Test лишається окремою вимогою класифікації PR'
        return (& $finish 'PARTIAL-OK')
    }
    if ($partialList.Count -eq 0 -and $otherMarkers -eq 0) {
        & $emit 'AFFECTED CHILD MARKER: NONE'
    }
    & $emit ('AFFECTED ERROR: маркер дочірнього прогону не збігається з очікуваним: потрібен рівно один PARTIAL ' + $expectedList + ' і жодного іншого маркера')
    return (& $finish 'MARKER-MISMATCH')
}
