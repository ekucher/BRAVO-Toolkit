<#
    validate-agent-routing.ps1
    Хук PreToolUse для Claude Code — детермінований enforcement матриці
    .claude/ai-routing.json.

    Отримує на stdin JSON із полями session_id, cwd, hook_event_name,
    tool_name, tool_input і — усередині субагента — agent_id/agent_type. Для
    інструмента делегування ("Agent", історично "Task") перевіряє делегування
    агентам BRAVO; для Write/Edit/NotebookEdit перевіряє межу запису діючої
    роли; для викликів mcp__codex-agent__* лише аудитує.

    Контракт виходу (конвенція PreToolUse у Claude Code):
        exit 0 — виклик дозволено;
        exit 2 — виклик заблоковано, текст причини йде у stderr.

    Блокує вузький закритий список порушень:
      1. модель виклику не відповідає матриці;
      2. Claude-агента брифують як формальний Codex-гейт
         (review_source: codex-*) — такий гейт закриває лише Codex;
      3. режим claude-qa-fallback без причини з трьох дозволених
         (quota | rate-limit | service-unavailable);
      4. агент documentation отримує SCOPE поза своїми межами запису
         (acceptance-докази, runbook-и, канон, код, манифести);
      5. делегований агент фактично пише поза своєю межею запису
         (Write/Edit/NotebookEdit): read-only роль — будь-який запис;
         роль із межею — цілі з writeDeny або поза writeAllow. Діюча роль
         береться з agent_type; у головній сесії цього поля немає, і вона
         не гейтиться.

    Решта викликів — у журнал .claude/logs/ai-routing.log, без блокування.
    Агенти, відсутні в матриці (Explore, general-purpose, плагінні), не
    блокуються ніколи.

    Власна помилка хука (відсутня/пошкоджена матриця, збій розбору stdin):
    fail-closed для гейт-критичних ролей reviewer/architect/security-reviewer,
    fail-open для решти — одна помилка в JSON не повинна паралізувати сесію,
    але й не повинна відкривати шлях підміненому гейту.

    Викликати обов'язково з -NoProfile: вивід профілю PowerShell ламає
    розбір stdin.
#>
$ErrorActionPreference = 'Stop'

# Гейт-критичні роли дублюються тут навмисно: цей список потрібен саме тоді,
# коли матрицю прочитати не вдалося. Test-AIRouting.ps1 звіряє його з
# enforcement.failClosedRoles у матриці.
$script:FailClosedRoles = @('reviewer', 'architect', 'security-reviewer')
$script:CodexToolPrefix = 'mcp__codex-agent__'

# Маркери «SCOPE порожній» — бриф лише на аудит, без права запису.
$script:EmptyScopeMarkers = @('none', 'n/a', 'na', 'nothing', '-')

# Інструменти запису, які гейтяться за фактичною цільовою адресою.
# Bash навмисно відсутній: інспекція довільної команди на предмет «що саме вона
# запише» — евристика з гарантованими обходами; правильна відповідь для Bash —
# не давати цей інструмент ролі з межею запису (див. ai-routing.json,
# enforcement.writeGate.bashNote).
$script:WriteTools = @('Write', 'Edit', 'NotebookEdit')

# Інструмент делегування. У Claude Code 2.1.x він називається 'Agent'; ім'я
# 'Task' лишається для сумісності з версіями, де інструмент називався так.
# Це НЕ косметика: live-прогін 2026-10-12 показав, що хук бачить саме
# tool_name='Agent', і доки в списку був лише 'Task', усі перевірки делегування
# (модель, підмінений Codex-гейт, причина fallback, SCOPE documentation) у живій
# сесії не виконувались узагалі — пропускались як «інструмент не підлягає
# політиці». Test-AIRouting.ps1 прогонить кожну з них під обома іменами.
$script:DelegationTools = @('Agent', 'Task')

$isWriteTool = $false
$writeTarget = ''
$payloadCwd = ''

function Resolve-ProjectDir {
    <#
        Корінь проєкту НЕ беремо з payload: `cwd` — це робочий каталог виклику,
        а не межа політики. Якби він ставав коренем, сесія з cwd поза
        репозиторієм знову зробила б будь-який 'docs/...' дозволеним для роли з
        allowlist (та сама вразливість, що SEC-002, лише через інший вхід).

        Власне розташування хука завжди дає правильний корінь: файл лежить у
        '<корінь>/.claude/hooks/', і саме цей корінь володіє політикою, яку хук
        виконує. CLAUDE_PROJECT_DIR лишається першим джерелом — його ставить сам
        Claude Code, а не payload інструмента.
    #>
    param([string]$CwdFromPayload)

    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PROJECT_DIR)) { return $env:CLAUDE_PROJECT_DIR }
    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Write-RoutingLog {
    param(
        [string]$ProjectDir,
        [string]$Decision,
        [string]$Tool,
        [string]$Agent,
        [string]$Model,
        [string]$Reason
    )

    # Журнал — допоміжний. Його збій не повинен впливати на рішення хука.
    try {
        $logDir = Join-Path $ProjectDir '.claude\logs'
        if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $line = '{0} | {1} | tool={2} | agent={3} | model={4} | {5}' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Decision, $Tool, $Agent, $Model, $Reason
        Add-Content -LiteralPath (Join-Path $logDir 'ai-routing.log') -Value $line -Encoding UTF8
    }
    catch {
        # свідомо проглочено
    }
}

function Deny-Call {
    param(
        [string]$ProjectDir,
        [string]$Tool,
        [string]$Agent,
        [string]$Model,
        [string]$Reason
    )

    Write-RoutingLog -ProjectDir $ProjectDir -Decision 'BLOCK' -Tool $Tool -Agent $Agent -Model $Model -Reason $Reason
    [Console]::Error.WriteLine("BRAVO routing policy blocked this call: $Reason")
    [Console]::Error.WriteLine('Canonical rules: BRAVO_AGENT_POLICY.md, matrix: .claude/ai-routing.json')
    exit 2
}

function Approve-Call {
    param(
        [string]$ProjectDir,
        [string]$Tool,
        [string]$Agent,
        [string]$Model,
        [string]$Reason
    )

    Write-RoutingLog -ProjectDir $ProjectDir -Decision 'ALLOW' -Tool $Tool -Agent $Agent -Model $Model -Reason $Reason
    exit 0
}

function Get-ScopeToken {
    <#
        Витягує шляхи з блоку SCOPE: у брифі. Продовження блоку триває до
        наступного ключа у верхньому регістрі (OBJECTIVE:, ACCEPTANCE: тощо).
    #>
    param([string]$Prompt)

    $tokens = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Prompt)) { return $tokens }

    $inScope = $false
    foreach ($rawLine in ($Prompt -split "`r?`n")) {
        $line = $rawLine.Trim()

        if ($line -match '^(?i)SCOPE\s*:\s*(.*)$') {
            $inScope = $true
            $line = $Matches[1]
        }
        # Блок SCOPE закривається наступним ключем у верхньому регістрі. Ключ
        # може містити цифри й пробіли ('STEP 1:', 'ACCEPTANCE 2:'): без цього
        # live-прогін 2026-10-12 показав, що бриф із рядком 'STEP 1: ...' не
        # закривав блок, і вся подальша проза розбиралась як перелік цілей
        # запису — першим «шляхом» виходило слово 'STEP', і легітимний бриф
        # блокувався.
        #
        # Вимога щонайменше трьох літер перед необов'язковою цифровою частиною
        # навмисна: інакше рядок на кшталт 'C:/BRAVO/docs/x.md' виглядав би
        # ключем ('C:') і передчасно закривав блок, приховавши решту цілей від
        # перевірки межі.
        elseif ($inScope -and $line -match '^[A-Z][A-Z_]{2,}(\s+[A-Z0-9_-]+)*\s*:(\s|$)') {
            $inScope = $false
            continue
        }
        elseif (-not $inScope) {
            continue
        }

        foreach ($piece in ($line -split '[,;\s]+')) {
            $token = $piece.Trim().Trim('`', '"', "'", '*', '-', '(', ')', '[', ']')
            if ([string]::IsNullOrWhiteSpace($token)) { continue }

            # Явні маркери «обсягу запису немає» (аудит без правок).
            if ($script:EmptyScopeMarkers -contains $token.ToLowerInvariant()) { continue }

            # Токени без '/' і '.' НЕ відкидаються: 'Tools' чи 'POLICY' — це
            # теж цілі запису (каталог і файл без розширення), і раніше вони
            # просто зникали перед перевіркою межі. SCOPE за канонічною
            # політикою (розділ 5) — список файлів/каталогів, а не проза, тому
            # кожен токен мусить потрапити в allowlist ролі.
            $tokens.Add((ConvertTo-NormalizedScopePath -Path $token))
        }
    }

    return $tokens
}

function ConvertTo-NormalizedScopePath {
    <#
        Нормалізує шлях зі SCOPE перед перевіркою меж запису: уніфікує
        розділювачі, прибирає './' і логічно згортає '..'.

        Без цього 'docs/../AGENTS.md' проходив би перевірку, бо літерально
        відповідає writeAllow-патерну 'docs/*' і не відповідає жодному
        writeDeny-патерну, хоча фактично вказує на канонічну політику поза
        межами запису. Згортання робиться логічно (не через Resolve-Path): шлях
        у брифі може ще не існувати на диску, а перевірка межі не повинна
        залежати від того, створений файл чи ні.

        Якщо шлях виходить за корінь (лишається провідний '..'), повертається
        рядок із провідним '../', і жоден writeAllow-патерн його не покриє —
        тобто виклик буде заблокований.
    #>
    param([string]$Path)

    $value = ($Path -replace '\\', '/')

    # Корінь визначаємо ДО згортання '..'. Інакше 'C:/../docs/x.md' згорнувся б
    # у звичайний відносний 'docs/x.md' (бо сегмент 'C:' обрізається до 'C', а
    # наступний '..' його знімає) і пройшов би allow-патерн 'docs/*', хоча
    # фактично вказує на C:\docs\x.md поза репозиторієм. Позначений коренем
    # шлях лишається з провідним '/', якого не покриває жоден allow-патерн, бо
    # межі запису documentation описані лише відносними шляхами.
    $isRooted = $value.StartsWith('/') -or
                $value.StartsWith('//') -or
                ($value -match '^[A-Za-z]:')

    $segments = New-Object System.Collections.Generic.List[string]
    foreach ($segment in ($value -split '/')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -ceq '.') { continue }
        if ($segment -ceq '..') {
            if ($segments.Count -gt 0 -and $segments[$segments.Count - 1] -cne '..') {
                $segments.RemoveAt($segments.Count - 1)
            }
            else {
                $segments.Add('..')
            }
            continue
        }

        # Windows відкидає кінцеві точки й пробіли в імені: 'source.ps1.' і
        # 'source.ps1 ' відкриють той самий файл, що 'source.ps1'. Без цього
        # зрізання 'docs/source.ps1.' проходив би межу запису, бо не відповідає
        # deny-патерну '*.ps1', хоча фактично вказує саме на такий файл.
        $trimmed = $segment.TrimEnd('.', ' ')

        # NTFS-синтаксис альтернативного потоку: 'source.ps1::$DATA' і
        # 'source.ps1:stream' звертаються до того самого файлу, але не
        # відповідають deny-патерну '*.ps1'. Лишаємо лише частину до першої
        # двокрапки. Для абсолютного шляху ('C:/...') це дає сегмент без
        # двокрапки, який однаково не покривається allow-патернами, тобто
        # абсолютні шляхи лишаються заблокованими.
        $colonIndex = $trimmed.IndexOf(':')
        if ($colonIndex -ge 0) { $trimmed = $trimmed.Substring(0, $colonIndex) }

        $trimmed = $trimmed.TrimEnd('.', ' ')
        if ([string]::IsNullOrEmpty($trimmed)) { continue }
        $segments.Add($trimmed)
    }

    $normalized = [string]::Join('/', $segments)
    if ($isRooted) { $normalized = '/' + $normalized }
    return $normalized
}

function Resolve-WriteTargetPath {
    <#
        Зводить цільовий шлях запису до шляху, відносного кореня ПРОЄКТУ, щоб
        його можна було зіставити з патернами межі запису (вони всі відносні).

        Повертає об'єкт { Status; Relative }, де Status один із:
          'inside'       — ціль під коренем проєкту, Relative придатний до
                           зіставлення з writeDeny/writeAllow;
          'outside'      — ціль поза коренем проєкту;
          'unverifiable' — форма шляху не дозволяє визначити, куда він вкаже.

        ВАЖЛИВО: $Cwd використовується ВИКЛЮЧНО для того, щоб зробити відносний
        шлях абсолютним. Він НЕ є другим дозволеним коренем. Інакше сесія з
        cwd поза репозиторієм давала б ролі з allowlist запис будь-куди: шлях
        'E:/outside/docs/x.md' зрізався б до 'docs/x.md' і проходив патерн
        'docs/*'. Дозволений корінь — лише корінь проєкту (SEC-002).

        Відносний шлях мусить бути розв'язаний ДО згортання межі: сам лише
        'ConvertTo-NormalizedScopePath' лишає провідний '..', і спелінг
        '../<repo-name>/.claude/ai-routing.json' не відповідав би deny-патерну
        '.claude/*', хоча фактично вказує саме на матрицю (SEC-001).

        Форми, які свідомо вважаються 'unverifiable', бо їхню цільову адресу
        визначає стан процесу, а не текст шляху:
          'C:file.txt'   — drive-relative (поточний каталог ТОГО диска);
          '/foo'         — корінь поточного диска;
          '//server/...' — UNC і device-простори ('//?/', '//./').
    #>
    param(
        [string]$Path,
        [string]$Cwd,
        [string]$ProjectDir
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ Status = 'unverifiable'; Relative = '' }
    }

    $raw = ($Path -replace '\\', '/')

    # Device-простори Win32 ('//?/C:/...', '//./C:/...') — це лише інший спосіб
    # написати той самий шлях, тому префікс знімаємо й розбираємо далі звичайно.
    # Без цього '//?/<корінь>/BRAVO_AGENT_POLICY.md' лишався б «неперевірним» і
    # давав би обхід deny-списку через аліас.
    #
    # Але зняти префікс можна ЛИШЕ тоді, коли залишок — drive-absolute
    # ('C:/...'). Інакше залишок виглядав би відносним шляхом і склеювався з
    # cwd: '//?/GLOBALROOT/Device/HarddiskVolume3/.../BRAVO_AGENT_POLICY.md' з
    # cwd '<корінь>/docs' дало б 'docs/GLOBALROOT/Device/.../BRAVO_AGENT_POLICY.md',
    # що проходить allow-патерн 'docs/*' і не відповідає deny-патерну на канон,
    # хоча фактично адресує саме канонічну політику. Такий залишок —
    # «неперевірний», тобто fail-closed.
    if ($raw -match '^//[?.]/') {
        $deviceRemainder = ''
        if ($raw -match '^//[?.]/UNC/') { $deviceRemainder = '//' + $raw.Substring(8) }
        else { $deviceRemainder = $raw.Substring(4) }

        if ($deviceRemainder -notmatch '^[A-Za-z]:/') {
            return [pscustomobject]@{ Status = 'unverifiable'; Relative = $raw }
        }
        $raw = $deviceRemainder
    }

    if ($raw.StartsWith('//')) {
        # UNC. Може бути аліасом того самого локального шляху
        # ('//localhost/E$/...'), тому зіставленню з коренем не піддається.
        return [pscustomobject]@{ Status = 'unverifiable'; Relative = $raw }
    }
    if ($raw.StartsWith('/')) {
        return [pscustomobject]@{ Status = 'unverifiable'; Relative = $raw }
    }

    $absolute = ''
    if ($raw -match '^[A-Za-z]:/') {
        $absolute = $raw
    }
    elseif ($raw -match '^[A-Za-z]:') {
        # 'C:file.txt' — drive-relative, цільову адресу знає лише процес.
        return [pscustomobject]@{ Status = 'unverifiable'; Relative = $raw }
    }
    else {
        $base = $Cwd
        if ([string]::IsNullOrWhiteSpace($base)) { $base = $ProjectDir }
        $base = ($base -replace '\\', '/')
        if ($base -notmatch '^[A-Za-z]:/') {
            return [pscustomobject]@{ Status = 'unverifiable'; Relative = $raw }
        }
        $absolute = $base.TrimEnd('/') + '/' + $raw
    }

    $normalizedTarget = ConvertTo-NormalizedScopePath -Path $absolute
    $normalizedRoot = ''
    if (-not [string]::IsNullOrWhiteSpace($ProjectDir)) {
        $normalizedRoot = ConvertTo-NormalizedScopePath -Path $ProjectDir
    }
    if ([string]::IsNullOrWhiteSpace($normalizedRoot)) {
        return [pscustomobject]@{ Status = 'unverifiable'; Relative = $normalizedTarget }
    }

    # Порівняння регістронезалежне: Windows-шляхи не розрізняють регістр, і
    # 'E:/GitHub/...' проти 'e:/github/...' не повинно давати іншого рішення.
    $rootPrefix = $normalizedRoot.TrimEnd('/') + '/'
    if ($normalizedTarget.Length -gt $rootPrefix.Length -and
        $normalizedTarget.Substring(0, $rootPrefix.Length).Equals($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Status = 'inside'; Relative = $normalizedTarget.Substring($rootPrefix.Length) }
    }

    return [pscustomobject]@{ Status = 'outside'; Relative = $normalizedTarget }
}

function ConvertFrom-JsonEscapedText {
    <#
        Розескейпує \uXXXX і прості \-послідовності в сирому тексті payload.

        Потрібно лише на шляху відновлення роли після збою розбору stdin:
        ConvertFrom-Json там уже впав, а порівнювати ім'я роли з літеральним
        'reviewer' доводиться по сирому тексту. Без розескейпування
        "subagent_type":"reviewer" не впізнавався б як гейт-критична роль.

        Реалізовано без MatchEvaluator-скриптблоку: у Windows PowerShell 5.1
        такий виклик [regex]::Replace поводиться непослідовно між хостами.
    #>
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return '' }

    $result = $Value
    foreach ($match in [regex]::Matches($Value, '\\u(?<code>[0-9a-fA-F]{4})')) {
        $literal = $match.Value
        $decoded = [string][char][Convert]::ToInt32($match.Groups['code'].Value, 16)
        $result = $result.Replace($literal, $decoded)
    }

    # Решта простих escape-послідовностей JSON: прибираємо зворотний слеш,
    # лишаючи сам символ, щоб "revie\wer" теж не маскувало ім'я роли.
    return ($result -replace '\\(.)', '$1')
}

function Test-PatternMatch {
    param([string]$Value, $Patterns)

    foreach ($pattern in @($Patterns)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if ($Value -like ($pattern -replace '\\', '/')) { return $true }
    }
    return $false
}

# --- stdin ---------------------------------------------------------------

$projectDir = Resolve-ProjectDir -CwdFromPayload $null
$agentName = ''
$modelName = ''
$toolName = ''

$raw = ''

try {
    $raw = [Console]::In.ReadToEnd()
    $payload = $raw | ConvertFrom-Json

    $toolName = [string]$payload.tool_name
    $projectDir = Resolve-ProjectDir -CwdFromPayload ([string]$payload.cwd)

    if ($toolName -like ($script:CodexToolPrefix + '*')) {
        $role = ''
        if ($null -ne $payload.tool_input -and $null -ne $payload.tool_input.role) { $role = [string]$payload.tool_input.role }
        Approve-Call -ProjectDir $projectDir -Tool $toolName -Agent "codex:$role" -Model 'codex' -Reason 'codex call audited, not gated by this hook'
    }

    if ($script:WriteTools -contains $toolName) {
        # Гейт запису. Діючу роль беремо з agent_type: за документацією hooks
        # спрацьовують і всередині субагента, і payload несе agent_id/agent_type
        # — тобто ТОГО, ХТО ДІЄ. tool_input.subagent_type тут не підходить: він
        # описує, кого спавнять, і для Write/Edit його взагалі немає.
        $isWriteTool = $true
        $agentName = ''
        if ($null -ne $payload.agent_type) { $agentName = [string]$payload.agent_type }

        $writeTarget = ''
        if ($null -ne $payload.tool_input) {
            if ($null -ne $payload.tool_input.file_path) { $writeTarget = [string]$payload.tool_input.file_path }
            elseif ($null -ne $payload.tool_input.notebook_path) { $writeTarget = [string]$payload.tool_input.notebook_path }
        }
        $payloadCwd = [string]$payload.cwd
    }
    elseif ($script:DelegationTools -notcontains $toolName) {
        Approve-Call -ProjectDir $projectDir -Tool $toolName -Agent 'n/a' -Model 'n/a' -Reason 'tool not subject to routing policy'
    }
    else {
        $agentName = [string]$payload.tool_input.subagent_type
        if ($null -ne $payload.tool_input.model) { $modelName = [string]$payload.tool_input.model }
        $prompt = ''
        if ($null -ne $payload.tool_input.prompt) { $prompt = [string]$payload.tool_input.prompt }
    }
}
catch {
    # Збій розбору stdin — та сама логіка, що й для пошкодженої матриці:
    # закрито для гейт-критичних ролей, відкрито для решти.
    #
    # Роль при цьому ще не визначена, тому її доводиться відновити з сирого
    # тексту: інакше обіцяне fail-closed не настало б ніколи (порожнє
    # $agentName не входить до жодного списку, і хук пропускав би будь-який
    # зіпсований payload, навіть той, що називає reviewer).
    $reason = 'HOOK-ERROR: stdin parse failed: ' + $_.Exception.Message
    $recovered = ''

    # Сире тіло спершу розескейпуємо: ім'я роли в JSON може бути записане як
    # "reviewer", і порівняння з літеральним 'reviewer' його не впізнало б —
    # тобто гейт-критичний виклик пройшов би саме через escape-послідовність.
    $rawDecoded = ConvertFrom-JsonEscapedText -Value $raw

    # Беремо ВСІ згадки subagent_type, а не першу: розескейпування стирає межі
    # JSON-рядків, тому приклад усередині prompt ("subagent_type":"worker")
    # може стояти перед справжнім оголошенням роли й перекрити його. Якщо
    # будь-яка зі згадок — гейт-критична роль, трактуємо виклик як
    # гейт-критичний. Це свідомо консервативно: шлях узагалі досягається лише
    # тоді, коли payload уже зіпсований, і помилкове блокування тут дешевше за
    # пропущений підмінений гейт.
    $recoverMatches = @([regex]::Matches($rawDecoded, '"subagent_type"\s*:\s*"(?<agent>[^"]+)"'))
    foreach ($candidate in $recoverMatches) {
        $value = $candidate.Groups['agent'].Value
        if ($script:FailClosedRoles -contains $value) { $recovered = $value; break }
        if ([string]::IsNullOrEmpty($recovered)) { $recovered = $value }
    }

    if ($script:FailClosedRoles -notcontains $recovered) {
        # Імені роли в розпізнаваній формі немає (або воно не гейт-критичне):
        # якщо гейт-критична роль узагалі згадана в payload — сирому чи
        # розескейпованому — трактуємо виклик як гейт-критичний.
        foreach ($critical in $script:FailClosedRoles) {
            $pattern = '"' + [regex]::Escape($critical) + '"'
            if ($rawDecoded -match $pattern -or $raw -match $pattern) { $recovered = $critical; break }
        }
    }

    if ($script:FailClosedRoles -contains $recovered) {
        Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $recovered -Model $modelName `
            -Reason ($reason + ' — gate-critical role recovered from raw payload, blocked (fail-closed)')
    }
    Write-RoutingLog -ProjectDir $projectDir -Decision 'ALLOW' -Tool $toolName -Agent $recovered -Model $modelName `
        -Reason ($reason + ' — no gate-critical role identified, allowed (fail-open)')
    exit 0
}

# --- матриця -------------------------------------------------------------

$matrix = $null
$matrixError = ''
try {
    $matrixPath = Join-Path $projectDir '.claude\ai-routing.json'
    if (-not (Test-Path -LiteralPath $matrixPath -PathType Leaf)) {
        throw "routing matrix not found: $matrixPath"
    }
    $matrix = Get-Content -LiteralPath $matrixPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$matrix.schemaVersion -cne '1') { throw 'unsupported routing matrix schemaVersion' }
    if ($null -eq $matrix.roles -or @($matrix.roles.PSObject.Properties).Count -eq 0) { throw 'routing matrix defines no roles' }
}
catch {
    $matrix = $null
    $matrixError = $_.Exception.Message
}

if ($null -eq $matrix) {
    $reason = "HOOK-ERROR: $matrixError"
    if ($script:FailClosedRoles -contains $agentName) {
        Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName -Reason ($reason + ' — gate-critical role blocked (fail-closed)')
    }
    Write-RoutingLog -ProjectDir $projectDir -Decision 'ALLOW' -Tool $toolName -Agent $agentName -Model $modelName -Reason ($reason + ' — non-gate role allowed (fail-open)')
    exit 0
}

# --- гейт запису ---------------------------------------------------------
#
# Межа запису перевіряється на фактичному записі, а не лише за текстом SCOPE у
# брифі делегування: SCOPE — це декларація оркестратора, а запис — дія агента, і
# раніше другий шлях не контролювався взагалі.
if ($isWriteTool) {
    # Головна сесія: agent_type у payload відсутній. Гейтити її означало б
    # блокувати власну роботу власника процесу — система обмежує делегованих
    # виконавців, а не власника (ai-routing.json, enforcement.writeGate).
    if ([string]::IsNullOrWhiteSpace($agentName)) {
        Approve-Call -ProjectDir $projectDir -Tool $toolName -Agent 'main-session' -Model 'n/a' `
            -Reason 'no agent_type in payload: main session is not write-gated'
    }

    $writeRole = $matrix.roles.$agentName
    if ($null -eq $writeRole) {
        Approve-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model 'n/a' `
            -Reason 'agent is not managed by the routing matrix'
    }

    # Read-only роль не має права на жоден запис, незалежно від цілі — і ця
    # перевірка мусить стояти ПЕРЕД обробкою нерозпізнаної цілі. Інакше виклик
    # із полем шляху, якого хук не знає, проходив би саме тому, що хук не зміг
    # прочитати ціль.
    if ($writeRole.write -ne $true) {
        Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model 'n/a' `
            -Reason ("role '$agentName' is read-only by .claude/ai-routing.json and may not write (target: '$writeTarget')")
    }

    $resolved = Resolve-WriteTargetPath -Path $writeTarget -Cwd $payloadCwd -ProjectDir $projectDir

    # 'unverifiable' — fail-closed для КОЖНОЇ керованої матрицею роли, не лише
    # для ролі з allowlist. Форми drive-relative / корінь-диска / UNC можуть бути
    # аліасом файлу з deny-списку ('//localhost/E$/<корінь>/BRAVO_AGENT_POLICY.md'),
    # а жоден легітимний бриф таких форм не потребує. Пропускати їх означало б
    # лишити обхід deny-списку рівно там, де його найлегше застосувати.
    if ($resolved.Status -ceq 'unverifiable') {
        Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model 'n/a' `
            -Reason ("write target '$writeTarget' cannot be resolved to a path under the project root (drive-relative, drive-root or UNC form); blocked (fail-closed)")
    }

    if ($resolved.Status -cne 'inside') {
        # Ціль поза коренем проєкту.
        #
        # Для ролі з allowlist це fail-closed: межа описана через те, що
        # ДОЗВОЛЕНО, і позарепозиторна ціль у неї не входить. Для ролі лише з
        # deny-списком (worker/tester) межа все одно не в хуку, а в SCOPE
        # задачі, і deny-список перелічує саме файли ЦЬОГО репозиторію — тому
        # виклик пропускається з гучним записом у журнал.
        if ($null -ne $writeRole.writeAllow) {
            Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model 'n/a' `
                -Reason ("write target '$writeTarget' is outside the project root; role '$agentName' has a write allowlist, so it is blocked (fail-closed)")
        }
        Write-RoutingLog -ProjectDir $projectDir -Decision 'ALLOW' -Tool $toolName -Agent $agentName -Model 'n/a' `
            -Reason ('HOOK-ERROR: write target ''' + $writeTarget + ''' is outside the project root; deny-list-only role allowed (fail-open)')
        exit 0
    }

    $relativeTarget = $resolved.Relative

    if (Test-PatternMatch -Value $relativeTarget -Patterns $writeRole.writeDeny) {
        Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model 'n/a' `
            -Reason ("'$relativeTarget' is outside the write boundary of role '$agentName' (denied)")
    }

    if ($null -ne $writeRole.writeAllow -and -not (Test-PatternMatch -Value $relativeTarget -Patterns $writeRole.writeAllow)) {
        Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model 'n/a' `
            -Reason ("'$relativeTarget' is not inside the write allowlist of role '$agentName'")
    }

    Approve-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model 'n/a' `
        -Reason ("write target '$relativeTarget' is inside the write boundary of role '$agentName'")
}

$role = $matrix.roles.$agentName
if ($null -eq $role) {
    Approve-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName -Reason 'agent is not managed by the routing matrix'
}

# 1) Модель мусить відповідати матриці.
if (-not [string]::IsNullOrWhiteSpace($modelName)) {
    $expectedModel = [string]$role.model
    if ($modelName -cne $expectedModel) {
        Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName `
            -Reason ("role '$agentName' is pinned to model '$expectedModel' by .claude/ai-routing.json")
    }
}

# 2) Claude-агент не може бути брифований як формальний Codex-гейт.
$codexSourceMatch = [regex]::Match($prompt, '(?im)^\s*review_source\s*:\s*(?<source>codex-[a-z]+)')
if ($codexSourceMatch.Success) {
    Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName `
        -Reason ("brief declares review_source '" + $codexSourceMatch.Groups['source'].Value + "' — only Codex closes that gate (BRAVO_AGENT_POLICY.md 8.1/8.2)")
}

# 3) Режим claude-qa-fallback вимагає однієї з трьох дозволених причин.
#
# Тригер — саме ОГОЛОШЕННЯ режиму окремим ключем (REVIEW_MODE / review_source /
# mode), а не будь-яка згадка рядка 'claude-qa-fallback' у брифі. Інакше
# блокувались би легітимні виклики: бриф worker-а «реалізуй обробку
# claude-qa-fallback» або бриф reviewer-а «перевір формулювання про
# claude-qa-fallback у політиці» — жоден із них не є виконанням ролі fallback.
$fallbackDeclared = [regex]::IsMatch($prompt, '(?im)^\s*(REVIEW_MODE|review_source|mode)\s*:\s*claude-qa-fallback\s*$')
if ($fallbackDeclared) {
    $allowedReasons = @($matrix.fallback.allowedReasons)

    # Причина читається ДО кінця рядка і валідується повністю. Часткове
    # зіставлення ('quota' у 'quota/timeout') пропускало б явно заборонену
    # причину, прикриту дозволеним префіксом.
    $reasonMatch = [regex]::Match($prompt, '(?im)^\s*fallback_reason\s*:\s*(?<reason>.+?)\s*$')

    if (-not $reasonMatch.Success) {
        Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName `
            -Reason 'claude-qa-fallback brief declares no fallback_reason'
    }

    $declared = $reasonMatch.Groups['reason'].Value.Trim()
    if ($allowedReasons -notcontains $declared) {
        Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName `
            -Reason ("fallback_reason '$declared' is not allowed — only " + ($allowedReasons -join ', ') + "; anything else is a defect to diagnose, not a fallback trigger")
    }
}

# 4) Межі запису агента documentation.
if ($null -ne $role.writeDeny -or $null -ne $role.writeAllow) {
    foreach ($token in (Get-ScopeToken -Prompt $prompt)) {
        if (Test-PatternMatch -Value $token -Patterns $role.writeDeny) {
            Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName `
                -Reason ("SCOPE '$token' is outside the write boundary of role '$agentName' (denied)")
        }
        if ($null -ne $role.writeAllow -and -not (Test-PatternMatch -Value $token -Patterns $role.writeAllow)) {
            Deny-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName `
                -Reason ("SCOPE '$token' is not inside the write allowlist of role '$agentName'")
        }
    }
}

Approve-Call -ProjectDir $projectDir -Tool $toolName -Agent $agentName -Model $modelName -Reason 'routing policy satisfied'
