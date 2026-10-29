function Get-BRAVOAgentFilePolicyViolation {
    <#
        Єдина канонічна політика заборонених шляхів AI-агентів у продуктовому
        дереві (self-test Governance/NoAgentFilesInTree.* і гейт
        AGENT_FILES_IN_ARTIFACT у ci\New-BRAVOReleaseArtifact.ps1).

        Приймає шляхи відносно кореня (роздільник '/' або '\') і повертає
        ЛИШЕ порушні, у вигляді, в якому їх передано. Порівняння без
        урахування регістру, на будь-якій глибині:
          * будь-який сегмент шляху з іменем .claude або .codex
            (каталог; у режимі файлової системи порожній каталог теж рахується);
          * файл, ім'я якого AGENTS.md, CLAUDE.md або .mcp.json.
        Схожі імена (CLAUDE.md.example, my.claude\x, x.codex,
        docs\AGENTS-notes.md, docs\agents\...) НЕ збігаються: порівнюється
        повний сегмент, а не підрядок.

        Чиста функція: без файлової системи, git і глобального стану.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$RelativePath
    )

    $forbiddenDirectoryNames = @('.claude', '.codex')
    $forbiddenFileNames = @('AGENTS.md', 'CLAUDE.md', '.mcp.json')

    $violations = New-Object System.Collections.Generic.List[string]
    foreach ($path in $RelativePath) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $segments = @($path -split '[/\\]' | Where-Object { $_.Length -gt 0 })
        if ($segments.Count -eq 0) { continue }

        $isForbidden = $false
        foreach ($segment in $segments) {
            if ($forbiddenDirectoryNames -contains $segment) { $isForbidden = $true; break }
        }
        if (-not $isForbidden -and ($forbiddenFileNames -contains $segments[$segments.Count - 1])) {
            $isForbidden = $true
        }
        if ($isForbidden) { [void]$violations.Add($path) }
    }
    return $violations.ToArray()
}

function Get-BRAVOAgentFilePolicyTreePath {
    <#
        Усі файли І каталоги (разом із прихованими) під $Root як шляхи
        відносно $Root з роздільником '\'. Збій читання дерева - виняток
        (fail closed): неперелічене дерево не можна вважати чистим.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $rootFull = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).ProviderPath.TrimEnd([char]'\', [char]'/')
    $items = @(Get-ChildItem -LiteralPath $rootFull -Force -Recurse -ErrorAction Stop)
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($item in $items) {
        [void]$result.Add($item.FullName.Substring($rootFull.Length + 1))
    }
    return $result.ToArray()
}

function Get-BRAVOAgentFileScan {
    <#
        Скан дерева за політикою вище; спільний для self-test
        (Governance/NoAgentFilesInTree.*) і раннього CI-кроку
        ci\Test-BRAVOAgentFilePolicy.ps1, щоб правило не мало другої копії.

        Джерело істини: верх git work tree -> git-індекс (git ls-files; збій git
        - Error, fail closed); інакше файлова система під коренем. Повертає
        { Mode = 'git-index'|'filesystem'; Violations; Error } - непорожній
        Error означає, що дерево не перевірено.
    #>
    # GitCommandName існує лише для проби відсутнього git (без зміни PATH self-test).
    param([Parameter(Mandatory = $true)][string]$TreeRoot, [string]$GitCommandName = 'git')

    $scan = [pscustomobject]@{ Mode = ''; Violations = @(); Error = '' }
    $gitCommand = @(Get-Command -Name $GitCommandName -CommandType Application -ErrorAction SilentlyContinue)
    $useGit = $false
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($gitCommand.Count -gt 0) {
            $insideOutput = (& git -C $TreeRoot rev-parse --is-inside-work-tree 2>$null | Out-String).Trim()
            $insideExit = $LASTEXITCODE
            if ($insideExit -eq 0 -and $insideOutput -eq 'true') {
                $prefixOutput = (& git -C $TreeRoot rev-parse --show-prefix 2>$null | Out-String).Trim()
                if ($LASTEXITCODE -ne 0) {
                    $scan.Error = "git rev-parse --show-prefix завершився з кодом $LASTEXITCODE"
                    return $scan
                }
                $useGit = ($prefixOutput.Length -eq 0)
            } elseif (Test-Path -LiteralPath (Join-Path $TreeRoot '.git')) {
                # Є ознака репозиторію, але git його не розпізнав: не вгадуємо.
                $scan.Error = "у корені є .git, але git rev-parse завершився з кодом $insideExit (вивід: '$insideOutput')"
                return $scan
            }
        }

        if ($useGit) {
            $scan.Mode = 'git-index'
            $listing = & git -C $TreeRoot -c core.quotepath=off ls-files -z 2>$null | Out-String
            if ($LASTEXITCODE -ne 0) {
                $scan.Error = "git ls-files -z завершився з кодом $LASTEXITCODE"
                return $scan
            }
            $trackedPaths = @($listing.Split([char]0) | Where-Object { $_.Length -gt 0 })
            $scan.Violations = @(Get-BRAVOAgentFilePolicyViolation -RelativePath $trackedPaths)
        } else {
            $scan.Mode = 'filesystem'
            try {
                $scan.Violations = @(Get-BRAVOAgentFilePolicyViolation -RelativePath (Get-BRAVOAgentFilePolicyTreePath -Root $TreeRoot))
            } catch {
                $scan.Error = "не вдалося перелічити дерево: $($_.Exception.Message)"
            }
        }
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    return $scan
}
