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
