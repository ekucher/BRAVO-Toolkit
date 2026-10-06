function Invoke-BRAVOGitCommand {
    <#
        Єдиний запуск git для режиму Affected (VAL-05, PR2).

        Повертає {Available; ExitCode; StdOut; StdErr; StartError} і НІКОЛИ не
        кидає виняток запуску:
          * Available = $false  - команду git не знайдено (ExitCode = $null);
          * StartError          - виняток запуску процесу (Available = $true,
                                  ExitCode = $null): викликач мусить трактувати
                                  це як збій, а не як успіх.

        Чому System.Diagnostics.Process, а не `& git`: під
        $ErrorActionPreference = 'Stop' stderr нативної команди може стати
        термінальною помилкою, а змішування потоків псує розбір -z виводу.
        Тут stdout і stderr читаються окремо (stderr - асинхронно, щоб повний
        буфер одного потоку не блокував інший), вивід декодується як UTF-8 без
        BOM незалежно від кодової сторінки хоста.

        Шлях репозиторію передається лише через WorkingDirectory; аргументи -
        фіксовані прапорці, перевірені SHA і BaseRef із allowlist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$Argument,

        [Parameter()]
        [string]$GitCommandName = 'git'
    )

    $outcome = [pscustomobject]@{
        Available  = $false
        ExitCode   = $null
        StdOut     = ''
        StdErr     = ''
        StartError = $null
    }

    $found = @(Get-Command -Name $GitCommandName -CommandType Application -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) {
        return $outcome
    }
    $outcome.Available = $true

    $needsQuoting = [char[]]@([char]32, [char]9, [char]10, [char]13, [char]34)
    $quoted = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Argument) {
        if ($item.Length -gt 0 -and $item.IndexOfAny($needsQuoting) -lt 0) {
            [void]$quoted.Add($item)
        } else {
            $escaped = [regex]::Replace($item, '(\\*)"', '$1$1\"')
            $escaped = [regex]::Replace($escaped, '(\\+)\z', '$1$1')
            [void]$quoted.Add('"' + $escaped + '"')
        }
    }

    $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = [string]$found[0].Path
    $startInfo.Arguments = [string]::Join(' ', $quoted.ToArray())
    $startInfo.WorkingDirectory = $RepositoryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    # Успадковані змінні вибору репозиторію перевизначили б WorkingDirectory і зіпсували б результат.
    foreach ($inheritedName in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_COMMON_DIR')) {
        if ($startInfo.EnvironmentVariables.ContainsKey($inheritedName)) {
            $startInfo.EnvironmentVariables.Remove($inheritedName)
        }
    }
    $startInfo.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $startInfo.EnvironmentVariables['GIT_OPTIONAL_LOCKS'] = '0'

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
        $outcome.StdOut = [string]$stdout
        $outcome.StdErr = [string]$stderrTask.Result
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

function Get-BRAVOChangedPathSet {
    <#
        Канонічний git-збирач змінених шляхів для режиму Affected (VAL-05, PR2).

        Порівнює merge-base(BaseRef, HEAD) з РОБОЧИМ деревом: tracked-зміни
        (staged і unstaged), untracked-файли без gitignored, видалення окремо,
        rename - обидва шляхи (--no-renames). Шляхи повертаються дослівно (без
        обрізання), без дублів, у порядку Ordinal.

        Контракт результату:
          Status, BaseSha, HeadSha, MergeBaseSha, Dirty, ChangedPath,
          DeletedPath, RuntimeManifestBaseText, RuntimeManifestCurrentText,
          FailedCommand, ExitCode, Message.

        Status: Ok | BASE-MISSING | BASE-INVALID | BASE-EQUALS-HEAD | EMPTY-DIFF |
                GIT-MISSING | GIT-FAILED | NOT-A-REPOSITORY | ROOT-MISMATCH |
                SHALLOW-REPOSITORY | NO-MERGE-BASE.
        Усе, крім Ok, - НЕ набір для планування. Збій git НІКОЛИ не стає
        порожнім набором: ненульова відповідь, виняток запуску чи невірна
        форма виводу повертаються до збирання шляхів зі статусом GIT-FAILED.

        -GitInvoker (для тестів) - scriptblock, що отримує масив аргументів git
        і повертає {ExitCode; StdOut; StdErr} (за бажанням Available,
        StartError) або кидає виняток. Без нього викликається
        Invoke-BRAVOGitCommand.

        ExitCode у результаті - код git тієї команди, на якій збирач зупинився
        ($null, якщо команда не стартувала або збору нічого не заважало).
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
        [string]$GitCommandName = 'git'
    )

    $manifestName = 'RUNTIME_MANIFEST.json'
    $baseSha = $null
    $headSha = $null
    $mergeBaseSha = $null
    $dirty = $false

    $newResult = {
        param(
            [string]$Status,
            $Run = $null,
            [string]$Message = '',
            [string[]]$Changed = @(),
            [string[]]$Deleted = @(),
            $ManifestBase = $null,
            $ManifestCurrent = $null
        )
        $failedCommand = $null
        $exitCode = $null
        if ($null -ne $Run) {
            $failedCommand = [string]$Run.Command
            $exitCode = $Run.ExitCode
        }
        return [pscustomobject]@{
            Status                     = $Status
            BaseSha                    = $baseSha
            HeadSha                    = $headSha
            MergeBaseSha               = $mergeBaseSha
            Dirty                      = $dirty
            ChangedPath                = $Changed
            DeletedPath                = $Deleted
            RuntimeManifestBaseText    = $ManifestBase
            RuntimeManifestCurrentText = $ManifestCurrent
            FailedCommand              = $failedCommand
            ExitCode                   = $exitCode
            Message                    = $Message
        }
    }

    # Один виклик git. Invocation: Ok | GIT-MISSING | GIT-FAILED (збій запуску чи
    # зіпсована відповідь invoker-а). Код виходу команди перевіряє викликач.
    $runGit = {
        param([string[]]$GitArgument)
        $run = [pscustomobject]@{
            Invocation = 'Ok'
            Command    = 'git ' + [string]::Join(' ', $GitArgument)
            ExitCode   = $null
            StdOut     = ''
            StdErr     = ''
            Detail     = ''
        }
        $raw = @()
        try {
            if ($null -ne $GitInvoker) {
                $raw = @(& $GitInvoker $GitArgument)
            } else {
                $raw = @(Invoke-BRAVOGitCommand -RepositoryRoot $RepositoryRoot -Argument $GitArgument -GitCommandName $GitCommandName)
            }
        } catch {
            $run.Invocation = 'GIT-FAILED'
            $run.Detail = $_.Exception.Message
            return $run
        }
        if ($raw.Count -ne 1 -or $null -eq $raw[0]) {
            $run.Invocation = 'GIT-FAILED'
            $run.Detail = 'виклик git мусить повернути рівно один об''єкт {ExitCode; StdOut; StdErr}'
            return $run
        }
        $answer = $raw[0]
        $members = @{}
        foreach ($memberName in @('Available', 'ExitCode', 'StdOut', 'StdErr', 'StartError')) {
            if ($answer -is [System.Collections.IDictionary]) {
                if ($answer.Contains($memberName)) { $members[$memberName] = $answer[$memberName] }
            } else {
                $property = $answer.PSObject.Properties[$memberName]
                if ($null -ne $property) { $members[$memberName] = $property.Value }
            }
        }
        if ($members.ContainsKey('Available') -and -not [bool]$members['Available']) {
            $run.Invocation = 'GIT-MISSING'
            return $run
        }
        if ($members.ContainsKey('StartError') -and -not [string]::IsNullOrEmpty([string]$members['StartError'])) {
            $run.Invocation = 'GIT-FAILED'
            $run.Detail = [string]$members['StartError']
            return $run
        }
        if (-not $members.ContainsKey('ExitCode') -or -not ($members['ExitCode'] -is [int])) {
            $run.Invocation = 'GIT-FAILED'
            $run.Detail = 'відповідь git без цілочисельного ExitCode'
            return $run
        }
        $run.ExitCode = [int]$members['ExitCode']
        if ($members.ContainsKey('StdOut') -and $null -ne $members['StdOut']) { $run.StdOut = [string]$members['StdOut'] }
        if ($members.ContainsKey('StdErr') -and $null -ne $members['StdErr']) { $run.StdErr = [string]$members['StdErr'] }
        return $run
    }

    # Прибирає лише завершальні символи кінця рядка (пробіли шляху не чіпає).
    $lineOf = {
        param([string]$Text)
        return [regex]::Replace($Text, '[\r\n]+\z', '')
    }

    # Ordinal-сортування та дедуплікація; завжди повертає [string[]].
    $sortedUnique = {
        param([System.Collections.Generic.List[string]]$List)
        $List.Sort([StringComparer]::Ordinal)
        $unique = New-Object System.Collections.Generic.List[string]
        foreach ($entry in $List) {
            if ($unique.Count -eq 0 -or -not [string]::Equals($unique[$unique.Count - 1], $entry, [StringComparison]::Ordinal)) {
                [void]$unique.Add($entry)
            }
        }
        return , ([string[]]$unique.ToArray())
    }

    # --- 1. BaseRef: чиста перевірка, жодного виклику git ----------------------
    if ([string]::IsNullOrWhiteSpace($BaseRef)) {
        return (& $newResult 'BASE-MISSING' $null 'BaseRef порожній: без бази порівняння набір шляхів не будується.')
    }
    if ($BaseRef.StartsWith('-', [StringComparison]::Ordinal) -or -not [regex]::IsMatch($BaseRef, '^[A-Za-z0-9._/@{}~^-]+\z')) {
        return (& $newResult 'BASE-INVALID' $null 'BaseRef містить недопустимі символи або починається з ''-''.')
    }

    # --- 2. Репозиторій і збіг кореня -----------------------------------------
    $run = & $runGit @('rev-parse', '--show-toplevel')
    if ($run.Invocation -cne 'Ok') {
        return (& $newResult $run.Invocation $run ('Не вдалося виконати git: ' + $run.Detail))
    }
    if ($run.ExitCode -ne 0) {
        $message = 'Каталог не є репозиторієм git (код ' + $run.ExitCode + ').'
        if ([regex]::IsMatch($run.StdErr, 'dubious ownership|safe\.directory')) {
            $message = 'Git відмовився відкрити каталог через власника (dubious ownership). Якщо каталог довірений, додайте його: ' +
                'git config --global --add safe.directory <шлях до репозиторію>. Статус лишається NOT-A-REPOSITORY (fail closed).'
        }
        return (& $newResult 'NOT-A-REPOSITORY' $run $message)
    }
    $reportedRoot = & $lineOf $run.StdOut
    $reportedFull = $null
    $expectedFull = $null
    try {
        if ($reportedRoot.Length -eq 0) { throw 'git повернув порожній корінь репозиторію' }
        $reportedFull = [regex]::Replace([IO.Path]::GetFullPath($reportedRoot), '[\\/]+\z', '')
        $expectedFull = [regex]::Replace([IO.Path]::GetFullPath($RepositoryRoot), '[\\/]+\z', '')
    } catch {
        return (& $newResult 'GIT-FAILED' $run ('Не вдалося нормалізувати корінь репозиторію: ' + $_.Exception.Message))
    }
    if (-not [string]::Equals($reportedFull, $expectedFull, [StringComparison]::OrdinalIgnoreCase)) {
        return (& $newResult 'ROOT-MISMATCH' $run ('Корінь git (' + $reportedFull + ') не збігається з RepositoryRoot (' + $expectedFull + ').'))
    }

    # --- 3. Shallow -------------------------------------------------------------
    $run = & $runGit @('rev-parse', '--is-shallow-repository')
    if ($run.Invocation -cne 'Ok') {
        return (& $newResult $run.Invocation $run ('Не вдалося виконати git: ' + $run.Detail))
    }
    if ($run.ExitCode -ne 0) {
        return (& $newResult 'GIT-FAILED' $run ('git завершився з кодом ' + $run.ExitCode + '.'))
    }
    $shallow = & $lineOf $run.StdOut
    if ($shallow -ceq 'true') {
        return (& $newResult 'SHALLOW-REPOSITORY' $run 'Репозиторій неповний (shallow): merge-base недостовірний.')
    }
    if ($shallow -cne 'false') {
        return (& $newResult 'GIT-FAILED' $run 'Вивід --is-shallow-repository не є true чи false.')
    }

    # --- 4. База ----------------------------------------------------------------
    $run = & $runGit @('rev-parse', '--verify', '--quiet', ($BaseRef + '^{commit}'))
    if ($run.Invocation -cne 'Ok') {
        return (& $newResult $run.Invocation $run ('Не вдалося виконати git: ' + $run.Detail))
    }
    if ($run.ExitCode -eq 1) {
        return (& $newResult 'BASE-INVALID' $run 'BaseRef не розв''язується в commit.')
    }
    if ($run.ExitCode -ne 0) {
        return (& $newResult 'GIT-FAILED' $run ('git завершився з кодом ' + $run.ExitCode + '.'))
    }
    $candidate = & $lineOf $run.StdOut
    if (-not [regex]::IsMatch($candidate, '^[0-9a-f]{40}\z')) {
        return (& $newResult 'GIT-FAILED' $run 'Вивід rev-parse для бази не є 40-символьним SHA.')
    }
    $baseSha = $candidate

    # --- 5. HEAD ----------------------------------------------------------------
    $run = & $runGit @('rev-parse', '--verify', '--quiet', 'HEAD^{commit}')
    if ($run.Invocation -cne 'Ok') {
        return (& $newResult $run.Invocation $run ('Не вдалося виконати git: ' + $run.Detail))
    }
    if ($run.ExitCode -ne 0) {
        return (& $newResult 'GIT-FAILED' $run ('git завершився з кодом ' + $run.ExitCode + '.'))
    }
    $candidate = & $lineOf $run.StdOut
    if (-not [regex]::IsMatch($candidate, '^[0-9a-f]{40}\z')) {
        return (& $newResult 'GIT-FAILED' $run 'Вивід rev-parse для HEAD не є 40-символьним SHA.')
    }
    $headSha = $candidate

    # --- 6. merge-base ----------------------------------------------------------
    $run = & $runGit @('merge-base', $baseSha, $headSha)
    if ($run.Invocation -cne 'Ok') {
        return (& $newResult $run.Invocation $run ('Не вдалося виконати git: ' + $run.Detail))
    }
    $candidate = & $lineOf $run.StdOut
    if ($run.ExitCode -eq 1 -and $candidate.Length -eq 0) {
        return (& $newResult 'NO-MERGE-BASE' $run 'У бази та HEAD немає спільного предка.')
    }
    if ($run.ExitCode -ne 0) {
        return (& $newResult 'GIT-FAILED' $run ('git завершився з кодом ' + $run.ExitCode + '.'))
    }
    if (-not [regex]::IsMatch($candidate, '^[0-9a-f]{40}\z')) {
        return (& $newResult 'GIT-FAILED' $run 'Вивід merge-base не є 40-символьним SHA.')
    }
    $mergeBaseSha = $candidate

    # --- 7. tracked-зміни: merge-base -> робоче дерево --------------------------
    $run = & $runGit @('-c', 'core.quotepath=off', 'diff', '--no-renames', '--name-status', '-z', '--no-ext-diff', $mergeBaseSha, '--')
    if ($run.Invocation -cne 'Ok') {
        return (& $newResult $run.Invocation $run ('Не вдалося виконати git: ' + $run.Detail))
    }
    if ($run.ExitCode -ne 0) {
        return (& $newResult 'GIT-FAILED' $run ('git завершився з кодом ' + $run.ExitCode + '.'))
    }
    $tokens = @($run.StdOut.Split([char[]]@([char]0), [StringSplitOptions]::RemoveEmptyEntries))
    if (($tokens.Count % 2) -ne 0) {
        return (& $newResult 'GIT-FAILED' $run 'Непарна кількість NUL-токенів у виводі name-status.')
    }
    $changed = New-Object System.Collections.Generic.List[string]
    $deleted = New-Object System.Collections.Generic.List[string]
    for ($tokenIndex = 0; $tokenIndex -lt $tokens.Count; $tokenIndex += 2) {
        $statusToken = $tokens[$tokenIndex]
        if (-not [regex]::IsMatch($statusToken, '^[ADMTUXB]\z')) {
            return (& $newResult 'GIT-FAILED' $run ('Неочікуваний статус у виводі name-status: ' + $statusToken))
        }
        $pathToken = $tokens[$tokenIndex + 1]
        [void]$changed.Add($pathToken)
        if ($statusToken -ceq 'D') { [void]$deleted.Add($pathToken) }
    }

    # --- 8. untracked (без gitignored) -----------------------------------------
    $run = & $runGit @('ls-files', '--others', '--exclude-standard', '-z')
    if ($run.Invocation -cne 'Ok') {
        return (& $newResult $run.Invocation $run ('Не вдалося виконати git: ' + $run.Detail))
    }
    if ($run.ExitCode -ne 0) {
        return (& $newResult 'GIT-FAILED' $run ('git завершився з кодом ' + $run.ExitCode + '.'))
    }
    foreach ($untrackedPath in @($run.StdOut.Split([char[]]@([char]0), [StringSplitOptions]::RemoveEmptyEntries))) {
        [void]$changed.Add($untrackedPath)
    }

    # --- 9. супутній RUNTIME_MANIFEST.json --------------------------------------
    $manifestBaseText = $null
    $manifestCurrentText = $null
    if ($changed.Contains($manifestName)) {
        $run = & $runGit @('show', ($mergeBaseSha + ':' + $manifestName))
        if ($run.Invocation -cne 'Ok') {
            return (& $newResult $run.Invocation $run ('Не вдалося виконати git: ' + $run.Detail))
        }
        if ($run.ExitCode -eq 0) {
            $manifestBaseText = $run.StdOut
        }
        $manifestPath = Join-Path $RepositoryRoot $manifestName
        if ([IO.File]::Exists($manifestPath)) {
            try {
                $manifestCurrentText = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8)
            } catch {
                $manifestCurrentText = $null
            }
        }
    }

    # --- 10. чистота дерева (лише інформація; збій статусу - GIT-FAILED) ---------
    $run = & $runGit @('status', '--porcelain=v1', '-z', '--untracked-files=all')
    if ($run.Invocation -cne 'Ok') {
        return (& $newResult $run.Invocation $run ('Не вдалося виконати git: ' + $run.Detail))
    }
    if ($run.ExitCode -ne 0) {
        return (& $newResult 'GIT-FAILED' $run ('git завершився з кодом ' + $run.ExitCode + '.'))
    }
    $dirty = ($run.StdOut.Length -gt 0)

    # --- 11. union, дедуплікація Ordinal, класифікація порожнього набору --------
    $changedFinal = & $sortedUnique $changed
    $deletedFinal = & $sortedUnique $deleted
    if ($changedFinal.Count -eq 0) {
        if ($baseSha -ceq $headSha) {
            return (& $newResult 'BASE-EQUALS-HEAD' $null 'База збігається з HEAD і робоче дерево без змін.' $changedFinal $deletedFinal $manifestBaseText $manifestCurrentText)
        }
        return (& $newResult 'EMPTY-DIFF' $null 'Між merge-base і робочим деревом змін немає.' $changedFinal $deletedFinal $manifestBaseText $manifestCurrentText)
    }
    return (& $newResult 'Ok' $null '' $changedFinal $deletedFinal $manifestBaseText $manifestCurrentText)
}
