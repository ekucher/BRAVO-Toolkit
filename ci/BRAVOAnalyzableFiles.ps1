function Get-BRAVOAnalyzableFile {
    <#
        Повертає PowerShell-файли, що реально належать репозиторію.

        Джерело правди — `git ls-files`, а не обхід файлової системи:
        інакше локальний запуск аналізує й каталоги, які git ігнорує
        (`local-backups/` через .git/info/exclude, `LOGS/` через
        .gitignore), і дає знахідки, яких CI ніколи не побачить — бо у
        checkout цих файлів немає. Розбіжність між локальним і CI
        результатом гірша за саму знахідку.

        Якщо git недоступний (розпакований архів дистрибутиву без
        .git), відкочується на обхід файлової системи.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $extensions = @('.ps1', '.psm1', '.psd1')

    $gitCommand = Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $gitCommand -and (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
        try {
            $tracked = & git -C $Root ls-files --cached --others --exclude-standard 2>$null
            if ($LASTEXITCODE -eq 0 -and $tracked) {
                return @(
                    $tracked |
                        Where-Object { [IO.Path]::GetExtension($_) -in $extensions } |
                        ForEach-Object { Join-Path $Root $_ } |
                        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                        ForEach-Object { Get-Item -LiteralPath $_ }
                )
            }
        } catch {
            # Свідомий fallback нижче: git є, але репозиторій у стані,
            # де ls-files не працює (пошкоджений індекс, submodule).
            Write-Host "::warning::git ls-files недоступний, аналізуємо файлову систему: $($_.Exception.Message)"
        }
    }

    return @(
        Get-ChildItem -LiteralPath $Root -Recurse -File |
            Where-Object { $_.Extension -in $extensions }
    )
}

function Get-BRAVOProductionPowerShellFile {
    <#
        Production-набір PowerShell-файлів для правил сумісності з
        задекларованою мінімальною версією PowerShell (маніфести модулів:
        PowerShellVersion = '3.0').

        Це Get-BRAVOAnalyzableFile МІНУС self-test-набір (кореневий
        BRAVO_SELF_TEST.ps1 і все під selftest\). Усе інше — кореневі
        entrypoint-и, modules\, deploy\, ci\ (включно з ci\acceptance\,
        який оператор запускає на цільовому сервері) — потрапляє в
        release-пакет (git archive усього дерева, див.
        ci\New-BRAVOReleaseArtifact.ps1) і виконується поза CI-раннером.
        Self-test виконується лише як інструмент перевірки, тож під
        ці правила не підпадає.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    # Resolve-Path, а не [IO.Path]::GetFullPath: відносний -Root має
    # розв'язуватись від поточного PowerShell-розташування (так само, як
    # Join-Path/Get-Item у Get-BRAVOAnalyzableFile), а не від робочого
    # каталогу процесу, який може з ним не збігатися.
    $rootFullPath = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).ProviderPath.TrimEnd('\', '/')
    return @(
        Get-BRAVOAnalyzableFile -Root $Root | Where-Object {
            $relativePath = $_.FullName.Substring($rootFullPath.Length).TrimStart('\', '/').Replace('/', '\')
            -not (
                $relativePath -eq 'BRAVO_SELF_TEST.ps1' -or
                $relativePath.StartsWith('selftest\', [StringComparison]::OrdinalIgnoreCase)
            )
        }
    )
}

function Find-BRAVOStaticNewInvocation {
    <#
        Повертає кожен виклик статичного конструктора `[T]::new(...)` у
        PowerShell-файлі.

        `::new()` з'явився лише в PowerShell 5.0, а маніфести модулів
        декларують PowerShellVersion = '3.0' — на PowerShell 3.0/4.0 такий
        рядок кидає "Method invocation failed" лише в момент виконання
        (не під час парсингу), тобто у рідкісній гілці він лишається
        невидимим, доки гілка не спрацює. Канонічна форма репозиторію —
        New-Object 'System.Collections.Generic.List[string]' тощо.

        Пошук — за AST (InvokeMemberExpressionAst зі Static=$true і членом
        'new'), а не регулярним виразом: згадка `[Uri]::new` у коментарі
        чи рядковому літералі не є викликом і не повинна спрацьовувати.
        Файл, що не парситься, — помилка (fail-closed), а не "0 знахідок".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($LiteralPath, [ref]$tokens, [ref]$parseErrors)
    if ($null -ne $parseErrors -and @($parseErrors).Count -gt 0) {
        throw ("Не вдалося розібрати {0}: {1}" -f $LiteralPath, (@($parseErrors | ForEach-Object { $_.Message }) -join ' | '))
    }

    return @(
        $ast.FindAll(
            {
                param($node)
                $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                $node.Static -and
                $node.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
                [string]::Equals($node.Member.Value, 'new', [StringComparison]::OrdinalIgnoreCase)
            },
            $true
        ) | ForEach-Object {
            [pscustomobject]@{
                Path = $LiteralPath
                Line = $_.Extent.StartLineNumber
                Text = $_.Extent.Text
            }
        }
    )
}
