# Домен-фрагмент self-test: Operations (BRAVO.Operations — агент
# fleet-моніторингу BSYSTEM Operations). Dot-sourced з кореневого
# BRAVO_SELF_TEST.ps1 -- НЕ запускається напряму. Успадковує з викликача:
# $root, Test-BRAVOCondition, $script:failures.
#
# Покриття: E9 (fail-closed на пошкоджений server-id state-файл), E10
# (URL-нормалізація база+шлях, з/без кінцевого слеша), durable outbox
# (persist -> "перезапуск" (свіжий import модуля) -> drain), ідемпотентний
# retry (той самий eventId переживає повторну спробу), backoff-таймінг
# (експоненційний, обмежений стелею), E11 (401 -> локальний ключ
# видаляється, подія НЕ йде в нескінченний outbox-retry), dead-letter для
# справжньої 4xx-помилки валідації (400).
#
# A1-A7 (Wave 2 протокол enrollment, замінив старий server-rotated-claim
# протокол): агент сам генерує claim (X-Enrollment-Claim на POST і GET),
# 202-відповідь POST — лише {status} без claimToken, 409 claim_mismatch
# (термінально, окремо від already_finalized), 503 enrollment_not_configured
# (не помилка, та сама постава що pending), A7 lost-response recovery
# (повторний POST з тим самим serverId+claim+metadata — без спецобробки).
#
# HTTP-транспорт мокається підміною ГЛОБАЛЬНОЇ функції Invoke-WebRequest
# (BRAVO.Operations викликає її неявно, не якісним іменем модуля — той
# самий принцип, що New-BRAVOSelfTestRuntimeModule використовує для
# Get-Service/Start-Service в інших фрагментах: функція в поточній сесії
# має пріоритет над cmdlet-ом з тим самим іменем). Приватні
# module-internal функції (Get-BRAVOOperationsStateDirectory) мокаються
# через виконання scriptblock-у ВСЕРЕДИНІ самого модуля (& $module {...}),
# бо виклики між функціями одного psm1 резолвляться в межах module
# session state, а не глобальної сесії.

    if (Enter-BRAVOSelfTestSection -Name 'Operations/UrlNormalizationTrailingSlashInvariant') { try {
    Import-Module -Name (Join-Path $root "modules\BRAVO.Logging\BRAVO.Logging.psd1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $root "modules\BRAVO.Credentials\BRAVO.Credentials.psd1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $root "modules\BRAVO.Operations\BRAVO.Operations.psd1") -Force -ErrorAction Stop

    $opsSelfTestModule = Get-Module -Name 'BRAVO.Operations'

    # Ізоляція від реального ProgramData\BRAVO\State: та сама техніка, що
    # BRAVO_SELFTEST_ROOT/BRAVO_SELFTEST_VERSION_STATE_PATH у корені
    # BRAVO_SELF_TEST.ps1 (env var override, перевірений
    # Get-BRAVOOperationsStateDirectory першою чергою) — без цього кожен
    # прогін цього фрагмента або читав би, або (гірше) мутував би
    # справжній production server-id/outbox поточного хоста.
    function Set-BRAVOOpsSelfTestStateDirectory {
        param([Parameter(Mandatory = $true)][string]$Directory)
        if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
            New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        }
        [Environment]::SetEnvironmentVariable('BRAVO_OPERATIONS_TEST_STATE_DIR', $Directory)
    }

    # ---------------------------------------------------------------
    # Fake Credential Manager store (in-memory hashtable, keyed by Target)
    # + fake HTTP transport (FIFO queue of canned responses/errors, + call
    # log for idempotency/argument assertions).
    #
    # ВАЖЛИВО: ці shadow-функції МУСЯТЬ матеріалізуватись у СПРАВЖНІЙ
    # $global: Function:-drive, не лише в лексичному scope цього
    # dot-sourced фрагмента. BRAVO.Operations.psm1 викликає
    # Invoke-WebRequest/Get-BRAVOCredentialSecret/Set-BRAVOCredential/
    # Remove-BRAVOCredential НЕКВАЛІФІКОВАНО (без імені модуля) -- як
    # окремий script-модуль, його command resolution для команд, яких
    # немає в НЬОГО самого, іде одразу в GLOBAL scope рантайму, а НЕ в
    # scope скрипта-викликача (BRAVO_SELF_TEST.ps1 виконується як
    # ЗОВНІШНІЙ .ps1-файл, тому його власний top-level -- це scope,
    # ДОЧІРНІЙ до глобального, а не сам глобальний). Просте
    # `function X {}` тут пішло б у той дочірній scope і лишилось би
    # НЕВИДИМИМ для BRAVO.Operations -- саме тому весь цей self-test
    # framework вже має New-BRAVOSelfTestRuntimeModule для Get-Service/
    # Start-Service/etc: `New-Module -ScriptBlock {...}` (без
    # -AsCustomObject)ematerializes кожну визначену функцію
    # безпосередньо в $global: Function:-drive, незалежно від глибини
    # лексичного scope виклику -- той самий принцип застосовано тут
    # напряму (без AST-екстракції New-BRAVOSelfTestRuntimeModule, вона
    # там для ВИБІРКОВОГО імпорту з великого SourceText; тут увесь текст
    # призначений для мокання, тож простіше визначити напряму).
    $global:BRAVOOpsSelfTestCredentialStore = @{}
    $global:BRAVOOpsSelfTestHttpQueue = New-Object System.Collections.Generic.Queue[object]
    $global:BRAVOOpsSelfTestHttpCalls = New-Object System.Collections.Generic.List[object]

    [void](New-Module -ScriptBlock {
        function Get-BRAVOCredentialSecret {
            param([string]$Target)
            if ($global:BRAVOOpsSelfTestCredentialStore.ContainsKey($Target)) {
                return $global:BRAVOOpsSelfTestCredentialStore[$Target]
            }
            return $null
        }
        function Set-BRAVOCredential {
            param([string]$Target, [string]$UserName = "", [Security.SecureString]$Secret)
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
            try {
                $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            } finally {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
            $global:BRAVOOpsSelfTestCredentialStore[$Target] = $plain
        }
        function Remove-BRAVOCredential {
            param([string]$Target)
            if ($global:BRAVOOpsSelfTestCredentialStore.ContainsKey($Target)) {
                $global:BRAVOOpsSelfTestCredentialStore.Remove($Target)
                return $true
            }
            return $false
        }

        function New-BRAVOOpsSelfTestFakeHttpError {
            param([int]$StatusCode, [string]$Body = '{}')
            $stream = New-Object IO.MemoryStream(, [Text.Encoding]::UTF8.GetBytes($Body))
            $fakeResponse = [pscustomobject]@{ StatusCode = $StatusCode }
            $fakeResponse | Add-Member -MemberType ScriptMethod -Name GetResponseStream -Value { return $stream }.GetNewClosure()
            $ex = New-Object Exception("simulated http $StatusCode")
            $ex | Add-Member -MemberType NoteProperty -Name Response -Value $fakeResponse -Force
            return $ex
        }

        function Invoke-WebRequest {
            param(
                [string]$Uri, [string]$Method, [hashtable]$Headers, $Body,
                [int]$TimeoutSec, [switch]$UseBasicParsing, [string]$ErrorAction, [string]$ContentType
            )
            $bodyText = $null
            if ($null -ne $Body) {
                try { $bodyText = [Text.Encoding]::UTF8.GetString($Body) } catch { $bodyText = [string]$Body }
            }
            [void]$global:BRAVOOpsSelfTestHttpCalls.Add([pscustomobject]@{ Uri = $Uri; Method = $Method; Headers = $Headers; BodyText = $bodyText })

            if ($global:BRAVOOpsSelfTestHttpQueue.Count -eq 0) {
                throw "Operations self-test: жодної замокованої HTTP-відповіді в черзі для $Method $Uri"
            }
            $next = $global:BRAVOOpsSelfTestHttpQueue.Dequeue()
            if ($next.Type -eq 'Success') {
                return [pscustomobject]@{ Content = $next.Content }
            }
            if ($next.Type -eq 'HttpError') {
                throw (New-BRAVOOpsSelfTestFakeHttpError -StatusCode $next.StatusCode -Body $next.Body)
            }
            # NetworkError: звичайний виняток БЕЗ .Response -- Get-BRAVOOperationsHttpStatusCode
            # має повернути $null (транзиєнтний/мережевий збій), не HTTP-статус.
            throw (New-Object Exception('simulated network failure'))
        }
    })

    function Enqueue-BRAVOOpsSelfTestHttpSuccess {
        param([hashtable]$ContentObject = @{})
        $global:BRAVOOpsSelfTestHttpQueue.Enqueue([pscustomobject]@{ Type = 'Success'; Content = ($ContentObject | ConvertTo-Json -Depth 6 -Compress) })
    }
    function Enqueue-BRAVOOpsSelfTestHttpError {
        param([int]$StatusCode, [hashtable]$BodyObject = @{})
        $global:BRAVOOpsSelfTestHttpQueue.Enqueue([pscustomobject]@{ Type = 'HttpError'; StatusCode = $StatusCode; Body = ($BodyObject | ConvertTo-Json -Depth 6 -Compress) })
    }
    function Enqueue-BRAVOOpsSelfTestHttpNetworkError {
        $global:BRAVOOpsSelfTestHttpQueue.Enqueue([pscustomobject]@{ Type = 'NetworkError' })
    }

    $opsSelfTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("bravo_ops_selftest_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $opsSelfTestRoot -Force | Out-Null

    # ApiBaseUrl НАВМИСНО без '/api' -- документована конвенція
    # (BRAVO.local.config.example) з коментарем E10 нижче: модуль сам
    # додає повний '/api/v1/...' у кожному виклику Invoke-BRAVOOperationsApiRequest
    # (-Path '/api/v1/enroll' тощо), тож ApiBaseUrl з зайвим '/api' дає
    # подвоєний .../api/api/v1/... -- саме цю помилку в документованому
    # прикладі знайдено й виправлено при написанні цього тесту (було
    # 'https://ops.example.invalid/api', давало непомічений
    # double-/api в усіх функціональних тестах нижче, бо фейковий
    # Invoke-WebRequest мок не перевіряв $Uri, лише повертав чергу
    # відповідей незалежно від нього).
    $opsSettings = @{ Enabled = $true; ApiBaseUrl = 'https://ops.example.invalid'; ProductType = 'LIMS'; RequestTimeoutSeconds = 5 }
    $opsCredentialTargets = @{ OperationsBootstrapSecret = 'OpsSelfTestBootstrap'; OperationsApiKey = 'OpsSelfTestApiKey' }

    # =====================================================================
    # E10: URL normalization.
    #
    # Дві незалежні перевірки:
    #  (a) idempotency: база з/без кінцевого слеша дає ІДЕНТИЧНИЙ результат
    #      (на відміну від старого [Uri]::new-резолвінгу, де кінцевий слеш
    #      ламав шлях подвоєнням сегмента бази).
    #  (b) КОРЕКТНІСТЬ за документованою конвенцією (BRAVO.local.config.example):
    #      ApiBaseUrl БЕЗ '/api' (модуль сам додає повний '/api/v1/...' у
    #      кожному виклику -Path) -> результат МАЄ БУТИ без дубльованого
    #      /api. Це не гіпотетичний edge case: до цього фіксу задокументо-
    #      ваний приклад ('.../operations.bsystem.example/api', з '/api')
    #      у поєднанні з модульним -Path '/api/v1/...' давав РІВНО цю
    #      подвоєну помилку для БУДЬ-ЯКОГО оператора, що просто скопіював
    #      приклад з коментаря — знайдено при рев'ю цієї self-test-сюїти
    #      (перша версія тесту помилково стверджувала подвоєний /api/api/
    #      як "коректний", перевіряючи лише idempotency, не правильність).
    # =====================================================================
    $joinUrlFn = & $opsSelfTestModule { ${function:Join-BRAVOOperationsApiUrl} }

    $withoutTrailingSlash = & $joinUrlFn -BaseUrl 'https://host:8443/api' -Path 'api/v1/enroll'
    $withTrailingSlash = & $joinUrlFn -BaseUrl 'https://host:8443/api/' -Path 'api/v1/enroll'
    Test-BRAVOCondition -Condition ($withoutTrailingSlash -eq $withTrailingSlash) `
        -Name 'Operations/UrlNormalizationTrailingSlashInvariant' `
        -Failure "ApiBaseUrl з і без кінцевого слеша має давати ІДЕНТИЧНИЙ URL; without='$withoutTrailingSlash' with='$withTrailingSlash'"

    $documentedConventionUrl = & $joinUrlFn -BaseUrl 'https://operations.bsystem.example' -Path '/api/v1/enroll'
    Test-BRAVOCondition -Condition ($documentedConventionUrl -eq 'https://operations.bsystem.example/api/v1/enroll') `
        -Name 'Operations/UrlNormalizationMatchesDocumentedConventionNoDuplicateApi' `
        -Failure "ApiBaseUrl БЕЗ '/api' (документована конвенція) + -Path '/api/v1/enroll' (реальний виклик модуля) має дати 'https://operations.bsystem.example/api/v1/enroll' БЕЗ дублювання; отримано '$documentedConventionUrl'"

    # =====================================================================
    # E9: пошкоджений server-id state-файл -> fail-closed (ERROR-лог, $null),
    # БЕЗ мовчазної генерації нового GUID поверх можливо вже approved id.
    # =====================================================================
    $e9Dir = Join-Path $opsSelfTestRoot 'E9_Corrupt'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $e9Dir
    $corruptStatePath = Join-Path $e9Dir 'BRAVO_OPERATIONS_SERVER_ID.json'
    [IO.File]::WriteAllText($corruptStatePath, '{ not valid json !!!', (New-Object Text.UTF8Encoding($false)))
    $e9Result = Get-BRAVOOperationsServerId
    Test-BRAVOCondition -Condition ($null -eq $e9Result) `
        -Name 'Operations/CorruptServerIdStateFailsClosedReturnsNull' `
        -Failure "пошкоджений server-id state-файл має повертати `$null (fail-closed), отримано: $e9Result"

    $e9AfterContent = [IO.File]::ReadAllText($corruptStatePath, [Text.UTF8Encoding]::new($false))
    Test-BRAVOCondition -Condition ($e9AfterContent -eq '{ not valid json !!!') `
        -Name 'Operations/CorruptServerIdStateNotSilentlyReplaced' `
        -Failure 'пошкоджений файл НЕ повинен бути мовчки перезаписаний новим GUID -- вміст має лишитись незмінним для ручного розбору'

    # Контрольна умова: СПРАВЖНЯ відсутність файлу (перший запуск) і далі
    # генерує новий GUID -- regression-guard, що фікс E9 не зламав звичайний
    # перший-запуск шлях.
    $e9FreshDir = Join-Path $opsSelfTestRoot 'E9_Fresh'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $e9FreshDir
    $e9FreshResult = Get-BRAVOOperationsServerId
    $e9FreshGuidParsed = [guid]::Empty
    Test-BRAVOCondition -Condition ([guid]::TryParse($e9FreshResult, [ref]$e9FreshGuidParsed)) `
        -Name 'Operations/MissingServerIdStateStillGeneratesNewGuid' `
        -Failure "справжня відсутність файлу (перший запуск) має і далі генерувати валідний GUID; отримано '$e9FreshResult'"

    # =====================================================================
    # OUTBOX: durable persistence переживає "перезапуск" (свіжий import
    # модуля симулює новий процес/сесію) + drain успішно доставляє.
    # =====================================================================
    $outboxDir = Join-Path $opsSelfTestRoot 'Outbox_Persist'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $outboxDir
    $global:BRAVOOpsSelfTestCredentialStore = @{ 'OpsSelfTestApiKey' = 'fixed-test-api-key' }

    # Перша "подія" не доставляється негайно (мережевий збій) -> має
    # опинитись в durable outbox на диску.
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    Enqueue-BRAVOOpsSelfTestHttpNetworkError
    Send-BRAVOOperationsEvent -OperationsReportingSettings $opsSettings -CredentialTargets $opsCredentialTargets `
        -InstitutionCode 'INST1' -Category 'backup' -Severity 'SUCCESS' -Message 'outbox persistence test event'

    $outboxItemsOnDisk = @(Get-ChildItem -LiteralPath (Join-Path $outboxDir 'Outbox') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition ($outboxItemsOnDisk.Count -eq 1) `
        -Name 'Operations/FailedSendIsPersistedToOutboxOnDisk' `
        -Failure "невдала негайна відправка має створити рівно 1 файл в Outbox\; знайдено $($outboxItemsOnDisk.Count)"

    $persistedEventId = $null
    if ($outboxItemsOnDisk.Count -eq 1) {
        $persistedRaw = ([IO.File]::ReadAllText($outboxItemsOnDisk[0].FullName, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
        $persistedEventId = [string]$persistedRaw.EventId
        Test-BRAVOCondition -Condition (
            -not [string]::IsNullOrWhiteSpace($persistedEventId) -and
            $persistedRaw.SchemaVersion -eq 1 -and
            -not [string]::IsNullOrWhiteSpace([string]$persistedRaw.OccurredAtUtc) -and
            $persistedRaw.RequestBody.eventId -eq $persistedEventId
        ) -Name 'Operations/OutboxItemCarriesEnvelopeFields' `
          -Failure "outbox item має нести eventId/occurredAt/schemaVersion=1, узгоджені з RequestBody.eventId; отримано $($persistedRaw | ConvertTo-Json -Compress -Depth 5)"
    }

    # "Перезапуск процесу": Remove-Module + Import-Module наново -- жодних
    # in-memory структур не лишається, лише файл на диску.
    Remove-Module -Name 'BRAVO.Operations' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.Operations\BRAVO.Operations.psd1") -Force -ErrorAction Stop
    $opsSelfTestModule = Get-Module -Name 'BRAVO.Operations'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $outboxDir

    $outboxItemsAfterRestart = @(Get-ChildItem -LiteralPath (Join-Path $outboxDir 'Outbox') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition ($outboxItemsAfterRestart.Count -eq 1) `
        -Name 'Operations/OutboxSurvivesModuleReimportRestart' `
        -Failure "outbox-файл на диску має пережити перезапуск (Remove-Module/Import-Module); знайдено $($outboxItemsAfterRestart.Count)"

    # Backoff (30s на першій спробі) навмисно НЕ дозволив би дренаж
    # відбутись негайно в реальному часі -- перемотуємо NextRetryAtUtc
    # item-у в минуле, щоб перевірити саму логіку дренажу/ідемпотентності
    # без залежності від годинника self-test.
    foreach ($outboxFile in $outboxItemsAfterRestart) {
        $rewound = ([IO.File]::ReadAllText($outboxFile.FullName, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
        $rewound.NextRetryAtUtc = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
        [IO.File]::WriteAllText($outboxFile.FullName, ($rewound | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    }

    # Drain: наступний heartbeat (з успішним enroll no-op, бо ключ уже є)
    # спершу дренує outbox (успішний POST), ПОТІМ відправляє власний
    # heartbeat -- дві успішні HTTP-відповіді в черзі.
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'accepted' }   # drain of the queued event
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'accepted' }   # the heartbeat itself
    Send-BRAVOOperationsHeartbeat -OperationsReportingSettings $opsSettings -CredentialTargets $opsCredentialTargets `
        -InstitutionCode 'INST1' -BravoVersion '9.9.9-selftest'

    $outboxItemsAfterDrain = @(Get-ChildItem -LiteralPath (Join-Path $outboxDir 'Outbox') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition ($outboxItemsAfterDrain.Count -eq 0) `
        -Name 'Operations/DrainRemovesSucceededOutboxItem' `
        -Failure "успішний drain має видалити item з Outbox\; лишилось $($outboxItemsAfterDrain.Count)"

    $drainedCallBodies = @($global:BRAVOOpsSelfTestHttpCalls | Where-Object { $_.Uri -like '*events*' })
    Test-BRAVOCondition -Condition (
        $drainedCallBodies.Count -ge 1 -and
        $drainedCallBodies[0].BodyText -match [regex]::Escape($persistedEventId)
    ) -Name 'Operations/DrainRetriesSameEventIdAsOriginalAttempt' `
      -Failure "drain повторної спроби має нести ТОЙ САМИЙ eventId, що й початкова невдала спроба ($persistedEventId) -- ідемпотентність на API стороні спирається саме на це"

    # =====================================================================
    # BACKOFF: чисто-функціональна перевірка меж (30s старт, подвоєння,
    # стеля 1800s) -- без HTTP, щоб не залежати від таймінгу реального
    # годинника в self-test.
    # =====================================================================
    $backoffFn = & $opsSelfTestModule { ${function:Get-BRAVOOperationsOutboxBackoffSeconds} }
    $backoff1 = & $backoffFn -AttemptCount 1
    $backoff2 = & $backoffFn -AttemptCount 2
    $backoff3 = & $backoffFn -AttemptCount 3
    $backoffHuge = & $backoffFn -AttemptCount 999
    Test-BRAVOCondition -Condition (
        $backoff1 -eq 30 -and $backoff2 -eq 60 -and $backoff3 -eq 120 -and $backoffHuge -eq 1800
    ) -Name 'Operations/OutboxBackoffExponentialWithCeiling' `
      -Failure "backoff має бути 30/60/120s на спробах 1/2/3 і не перевищувати стелю 1800s на дуже великих attempt count; отримано $backoff1/$backoff2/$backoff3/$backoffHuge"

    # =====================================================================
    # E11: 401 на надсиланні -> локальний API-ключ видаляється, а сама
    # подія ЗБЕРІГАЄТЬСЯ в durable outbox.
    #
    # Контракт свідомо змінений (review thread 5, PR #225): раніше тут
    # перевірялось ПРОТИЛЕЖНЕ — що 401 НЕ ставить подію в outbox, бо "цей
    # самий ключ ніколи не стане валідним і retry був би вічним". Той
    # аргумент хибний: outbox item НЕ зберігає ключ, дренаж підставляє
    # той, що валідний на момент дренажу. Тож стара очікуваність означала
    # гарантовану втрату саме тієї події (результату backup/health/
    # maintenance), яка й виявила інвалідизацію ключа. Вічного retry немає
    # й тепер: 401 у дренажі зупиняє дренаж, а outbox обмежений
    # (MaxOutboxItems -> витіснення найстарших у dead-letter).
    # =====================================================================
    $e11Dir = Join-Path $opsSelfTestRoot 'E11_Revoked'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $e11Dir
    $global:BRAVOOpsSelfTestCredentialStore = @{ 'OpsSelfTestApiKey' = 'now-revoked-api-key' }
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    Enqueue-BRAVOOpsSelfTestHttpError -StatusCode 401 -BodyObject @{ error = 'unauthorized' }
    Send-BRAVOOperationsEvent -OperationsReportingSettings $opsSettings -CredentialTargets $opsCredentialTargets `
        -InstitutionCode 'INST1' -Category 'health' -Severity 'CRITICAL' -Message 'e11 test event'

    Test-BRAVOCondition -Condition (-not $global:BRAVOOpsSelfTestCredentialStore.ContainsKey('OpsSelfTestApiKey')) `
        -Name 'Operations/HttpUnauthorizedClearsStoredApiKey' `
        -Failure '401 на event-надсиланні має призвести до видалення локального збереженого API-ключа (E11)'

    $e11OutboxItems = @(Get-ChildItem -LiteralPath (Join-Path $e11Dir 'Outbox') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition ($e11OutboxItems.Count -eq 1) `
        -Name 'Operations/HttpUnauthorizedEnqueuesEventForLaterKey' `
        -Failure "401 має ЗБЕРЕГТИ подію в durable outbox (ключ у item не зберігається — дренаж підставить валідний після наступного enrollment); знайдено $($e11OutboxItems.Count) файлів замість 1"

    # Той самий item мусить лишитись негайно дренажним (AttemptCount=0 —
    # це не невдала спроба доставки, а відкладення через невалідний
    # ключ), інакше подія чекала б штучні 30с і її пропустив би ручний
    # BRAVO_OPERATIONS_HEARTBEAT.ps1 одразу після reissue ключа.
    $e11Item = $null
    if ($e11OutboxItems.Count -eq 1) {
        $e11Item = ([IO.File]::ReadAllText($e11OutboxItems[0].FullName, (New-Object Text.UTF8Encoding($false))) | ConvertFrom-Json)
    }
    $e11DueNow = $false
    if ($null -ne $e11Item) {
        $e11NextRetry = [datetime]::Parse([string]$e11Item.NextRetryAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        $e11DueNow = ([int]$e11Item.AttemptCount -eq 0) -and ($e11NextRetry -le (Get-Date).ToUniversalTime().AddSeconds(1))
    }
    Test-BRAVOCondition -Condition $e11DueNow `
        -Name 'Operations/AttemptZeroOutboxItemIsImmediatelyDue' `
        -Failure 'Item, поставлений в outbox з AttemptCount=0 (401 або pending enrollment), мусить бути негайно дренажним: AttemptCount=0 і NextRetryAtUtc <= now, БЕЗ штучного стартового backoff 30с'

    # =====================================================================
    # DEAD-LETTER: справжня 4xx-помилка валідації (400) НЕ повинна вічно
    # ретраятись -- переноситься в DeadLetter\, не в звичайний Outbox\.
    # =====================================================================
    $deadLetterDir = Join-Path $opsSelfTestRoot 'DeadLetter'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $deadLetterDir
    $global:BRAVOOpsSelfTestCredentialStore = @{ 'OpsSelfTestApiKey' = 'valid-api-key' }
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    Enqueue-BRAVOOpsSelfTestHttpError -StatusCode 400 -BodyObject @{ error = 'invalid_request' }
    Send-BRAVOOperationsEvent -OperationsReportingSettings $opsSettings -CredentialTargets $opsCredentialTargets `
        -InstitutionCode 'INST1' -Category 'maintenance' -Severity 'ERROR' -Message 'dead letter test event'

    $normalOutboxAfter400 = @(Get-ChildItem -LiteralPath (Join-Path $deadLetterDir 'Outbox') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $deadLetterAfter400 = @(Get-ChildItem -LiteralPath (Join-Path $deadLetterDir 'Outbox\DeadLetter') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition ($normalOutboxAfter400.Count -eq 0 -and $deadLetterAfter400.Count -eq 1) `
        -Name 'Operations/PermanentValidationErrorGoesToDeadLetterNotRetryOutbox' `
        -Failure "HTTP 400 (справжня помилка валідації) має піти в DeadLetter\ (знайдено $($deadLetterAfter400.Count)), НЕ в звичайний retry-Outbox\ (знайдено $($normalOutboxAfter400.Count))"

    # =====================================================================
    # HTTP 408: Request Timeout — НЕ постійна помилка валідації.
    #
    # Review finding (thread 8, PR #225): попередній предикат dead-letter
    # покривав увесь діапазон 4xx крім 429, тож 408 від API чи проміжного
    # gateway трактувався як "payload відхилено" й подія переносилась у
    # DeadLetter\ назавжди — хоча 408 означає лише "я не дочекався твого
    # запиту" і не встановлює ні прийняття, ні відхилення. Ретрай із ТИМ
    # САМИМ eventId ідемпотентний на стороні API (UNIQUE(server_id,
    # event_id)), тому 408 має йти в звичайний retry-Outbox\, як 429.
    # =====================================================================
    $timeout408Dir = Join-Path $opsSelfTestRoot 'Timeout408'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $timeout408Dir
    $global:BRAVOOpsSelfTestCredentialStore = @{ 'OpsSelfTestApiKey' = 'valid-api-key' }
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    Enqueue-BRAVOOpsSelfTestHttpError -StatusCode 408 -BodyObject @{ error = 'request_timeout' }
    Send-BRAVOOperationsEvent -OperationsReportingSettings $opsSettings -CredentialTargets $opsCredentialTargets `
        -InstitutionCode 'INST1' -Category 'backup' -Severity 'SUCCESS' -Message '408 retry test event'

    $outboxAfter408 = @(Get-ChildItem -LiteralPath (Join-Path $timeout408Dir 'Outbox') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $deadLetterAfter408 = @(Get-ChildItem -LiteralPath (Join-Path $timeout408Dir 'Outbox\DeadLetter') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition ($outboxAfter408.Count -eq 1 -and $deadLetterAfter408.Count -eq 0) `
        -Name 'Operations/RequestTimeout408RetriesInsteadOfDeadLetter' `
        -Failure "HTTP 408 має піти в звичайний retry-Outbox\ (знайдено $($outboxAfter408.Count), очікувалось 1), а НЕ в DeadLetter\ (знайдено $($deadLetterAfter408.Count), очікувалось 0)"

    # =====================================================================
    # ДРЕНАЖ: зупинка після ПЕРШОГО transient збою.
    #
    # Review finding (thread 3, PR #225): коли API недоступний, кожен
    # due-item у пачці падав по повному RequestTimeoutSeconds, а дренаж
    # ішов далі — Archive/Health/Maintenance платили за це затримкою в
    # кожному прогоні, хоча жодна доставка вже не могла вдатись. Тепер
    # дренаж зупиняється після першого transient збою (як і для 401):
    # рівно ОДНА HTTP-спроба, і ЖОДЕН item не втрачено.
    # =====================================================================
    $drainStopDir = Join-Path $opsSelfTestRoot 'DrainStop'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $drainStopDir
    $global:BRAVOOpsSelfTestCredentialStore = @{ 'OpsSelfTestApiKey' = 'valid-api-key' }
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    foreach ($seedIndex in 1..3) {
        & $opsSelfTestModule {
            param($n)
            Add-BRAVOOperationsOutboxItem -Kind 'event' -EventId "drainstop-$n" `
                -OccurredAtUtc ((Get-Date).ToUniversalTime().ToString('o')) -SchemaVersion 1 `
                -ApiPath '/api/v1/events' `
                -RequestBody @{ category = 'backup'; severity = 'SUCCESS'; payload = @{ message = "seed$n" } } `
                -AttemptCount 0
        } $seedIndex
    }
    $seededDrainItems = @(Get-ChildItem -LiteralPath (Join-Path $drainStopDir 'Outbox') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    1..3 | ForEach-Object { Enqueue-BRAVOOpsSelfTestHttpNetworkError }
    Invoke-BRAVOOperationsOutboxDrain -ApiBaseUrl ([string]$opsSettings.ApiBaseUrl) -ApiKey 'valid-api-key' `
        -CredentialTargets $opsCredentialTargets -TimeoutSeconds ([int]$opsSettings.RequestTimeoutSeconds)
    $drainItemsAfter = @(Get-ChildItem -LiteralPath (Join-Path $drainStopDir 'Outbox') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition (
        $seededDrainItems.Count -eq 3 -and $global:BRAVOOpsSelfTestHttpCalls.Count -eq 1 -and $drainItemsAfter.Count -eq 3
    ) -Name 'Operations/OutboxDrainStopsAfterFirstTransientFailure' `
      -Failure "Дренаж при недоступному API має зробити РІВНО одну HTTP-спробу й не втратити жодного item; засіяно $($seededDrainItems.Count) (очікувалось 3), HTTP-спроб $($global:BRAVOOpsSelfTestHttpCalls.Count) (очікувалось 1), лишилось у черзі $($drainItemsAfter.Count) (очікувалось 3)"

    # =====================================================================
    # Після transient-збою дренажу негайна відправка ПРОПУСКАЄТЬСЯ.
    #
    # Review finding (thread 19, PR #225): дренаж зупиняється на першому
    # transient збої, але викликач цього не бачив і одразу робив ЩЕ ОДИН
    # синхронний запит до того самого щойно недоступного API — подвійний
    # RequestTimeoutSeconds у кожному прогоні. Тепер
    # Invoke-BRAVOOperationsOutboxDrain повертає результат, і на
    # 'transient'/'unauthorized' поточний envelope одразу ставиться в
    # outbox. Разом із цим перевіряємо, що захоплений результат НЕ
    # потрапляє у вихідний потік Send-BRAVOOperationsEvent.
    # =====================================================================
    $drainSkipDir = Join-Path $opsSelfTestRoot 'DrainSkip'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $drainSkipDir
    $global:BRAVOOpsSelfTestCredentialStore = @{ 'OpsSelfTestApiKey' = 'valid-api-key' }
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    & $opsSelfTestModule {
        Add-BRAVOOperationsOutboxItem -Kind 'event' -EventId 'drainskip-backlog' `
            -OccurredAtUtc ((Get-Date).ToUniversalTime().ToString('o')) -SchemaVersion 1 `
            -ApiPath '/api/v1/events' `
            -RequestBody @{ category = 'backup'; severity = 'SUCCESS'; payload = @{ message = 'backlog' } } `
            -AttemptCount 0
    }
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    Enqueue-BRAVOOpsSelfTestHttpNetworkError
    $drainSkipEmitted = @(Send-BRAVOOperationsEvent -OperationsReportingSettings $opsSettings `
        -CredentialTargets $opsCredentialTargets -InstitutionCode 'INST1' `
        -Category 'health' -Severity 'WARNING' -Message 'drain skip test event')
    $drainSkipOutbox = @(Get-ChildItem -LiteralPath (Join-Path $drainSkipDir 'Outbox') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition (
        $global:BRAVOOpsSelfTestHttpCalls.Count -eq 1 -and $drainSkipOutbox.Count -eq 2 -and $drainSkipEmitted.Count -eq 0
    ) -Name 'Operations/TransientDrainFailureSkipsImmediateSend' `
      -Failure "Після transient-збою дренажу має бути РІВНО одна HTTP-спроба (отримано $($global:BRAVOOpsSelfTestHttpCalls.Count)), у черзі 2 items — backlog і поточна подія (отримано $($drainSkipOutbox.Count)), і ЖОДНОГО об'єкта у вихідному потоці Send-BRAVOOperationsEvent (отримано $($drainSkipEmitted.Count))"

    # =====================================================================
    # Item чужої серверної ідентичності карантиниться, а не надсилається.
    #
    # Review finding (thread 16, PR #225): після задокументованого
    # відновлення від claim_mismatch оператор замінює server-id/enrollment
    # state, але наявні файли в outbox лишались непривʼязаними — дренаж
    # надсилав їх ключем НОВОЇ ідентичності, і бекенд приписував події
    # старого сервера новому. Тепер item несе ідентичність, яка його
    # породила, і розбіжність веде в dead-letter БЕЗ мережевої спроби.
    # =====================================================================
    $identityDir = Join-Path $opsSelfTestRoot 'IdentityReset'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $identityDir
    $global:BRAVOOpsSelfTestCredentialStore = @{ 'OpsSelfTestApiKey' = 'valid-api-key' }
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    & $opsSelfTestModule {
        Add-BRAVOOperationsOutboxItem -Kind 'event' -EventId 'identity-orphan' `
            -OccurredAtUtc ((Get-Date).ToUniversalTime().ToString('o')) -SchemaVersion 1 `
            -ApiPath '/api/v1/events' `
            -RequestBody @{ category = 'backup'; severity = 'SUCCESS'; payload = @{ message = 'orphan' } } `
            -AttemptCount 0
    }
    $orphanFiles = @(Get-ChildItem -LiteralPath (Join-Path $identityDir 'Outbox') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($orphanFiles.Count -eq 1) {
        $orphanObject = ([IO.File]::ReadAllText($orphanFiles[0].FullName, (New-Object Text.UTF8Encoding($false))) | ConvertFrom-Json)
        $orphanObject.ServerId = [guid]::NewGuid().ToString()
        [IO.File]::WriteAllText($orphanFiles[0].FullName, ($orphanObject | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    }
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    [void](Invoke-BRAVOOperationsOutboxDrain -ApiBaseUrl ([string]$opsSettings.ApiBaseUrl) -ApiKey 'valid-api-key' `
        -CredentialTargets $opsCredentialTargets -TimeoutSeconds ([int]$opsSettings.RequestTimeoutSeconds))
    $orphanOutboxAfter = @(Get-ChildItem -LiteralPath (Join-Path $identityDir 'Outbox') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $orphanDeadAfter = @(Get-ChildItem -LiteralPath (Join-Path $identityDir 'Outbox\DeadLetter') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition (
        $global:BRAVOOpsSelfTestHttpCalls.Count -eq 0 -and $orphanOutboxAfter.Count -eq 0 -and $orphanDeadAfter.Count -eq 1
    ) -Name 'Operations/ForeignServerIdentityItemIsQuarantinedNotSent' `
      -Failure "Item чужої ідентичності НЕ має надсилатись (HTTP-спроб $($global:BRAVOOpsSelfTestHttpCalls.Count), очікувалось 0) і має піти в dead-letter (outbox $($orphanOutboxAfter.Count) очікувалось 0, dead-letter $($orphanDeadAfter.Count) очікувалось 1)"

    # =====================================================================
    # State-файл БЕЗ новішого optional-поля зберігає свій claim.
    #
    # Review finding (thread 17, PR #225): під активним у модулі
    # Set-StrictMode -Version 2.0 прямий доступ до відсутньої властивості
    # КИДАЄ, а не дає $null. Файл, записаний до появи в контракті чергової
    # throttle-мітки, містить валідний Claim — але виняток відправляв увесь
    # об'єкт у catch, який повертав Claim = $null, і наступний прогін
    # генерував ІНШИЙ claim -> постійний 409 claim_mismatch для вже-pending
    # серверId. Тест імітує саме такий pre-upgrade файл.
    # =====================================================================
    $legacyStateDir = Join-Path $opsSelfTestRoot 'LegacyState'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $legacyStateDir
    $legacyStatePath = & $opsSelfTestModule { Get-BRAVOOperationsEnrollmentStatePath }
    $legacyStateClaim = [guid]::NewGuid().ToString()
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $legacyStatePath) -PathType Container)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $legacyStatePath) -Force | Out-Null
    }
    # LastApiBaseUrlMissingLoggedAtUtc НАВМИСНО відсутнє — саме це поле
    # додали в контракт останнім.
    [IO.File]::WriteAllText($legacyStatePath, (@{ Claim = $legacyStateClaim; LastNotReadyLoggedAtUtc = $null } | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    $legacyStateReadClaim = & $opsSelfTestModule { (Get-BRAVOOperationsEnrollmentState).Claim }
    $legacyStateMintedClaim = & $opsSelfTestModule { Get-BRAVOOperationsEnrollmentClaim }
    Test-BRAVOCondition -Condition (
        $legacyStateReadClaim -eq $legacyStateClaim -and $legacyStateMintedClaim -eq $legacyStateClaim
    ) -Name 'Operations/StateFileMissingNewerOptionalFieldKeepsClaim' `
      -Failure "State-файл без новішого optional-поля мусить зберегти персистований claim ($legacyStateClaim); прочитано [$legacyStateReadClaim], Get-BRAVOOperationsEnrollmentClaim повернув [$legacyStateMintedClaim] (якщо він інший — наступний POST /enroll дав би постійний 409 claim_mismatch)"
    } catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'Operations/UrlNormalizationTrailingSlashInvariant' } }
    if (Enter-BRAVOSelfTestSection -Name 'Operations/ApprovedWithoutApiKeyMeansTtlExpiredReturnsNullNoThrow' -DependsOn 'Operations/UrlNormalizationTrailingSlashInvariant') { try {

    # =====================================================================
    # ENROLLMENT (A1-A7 протокол — агент сам генерує claim, сервер його
    # НІКОЛИ не видає/не ротує): header-only bootstrap secret (POST-тіло
    # БЕЗ bootstrapSecret/claim), X-Enrollment-Claim агент-згенерований і
    # ІДЕНТИЧНИЙ на POST і GET, 202-відповідь POST БЕЗ claimToken-поля,
    # TTL-expired (approved БЕЗ apiKey) не падає в нескінченний тісний
    # цикл (повертає $null, не кидає).
    # =====================================================================
    $enrollDir = Join-Path $opsSelfTestRoot 'Enroll'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $enrollDir
    $global:BRAVOOpsSelfTestCredentialStore = @{ 'OpsSelfTestBootstrap' = 'fleet-bootstrap-secret' }
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'pending' }   # A1/A2: 202 body no longer carries claimToken
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'approved' }   # apiKey deliberately absent -> TTL expired

    $enrollApiKeyResult = Invoke-BRAVOOperationsEnrollment -OperationsReportingSettings $opsSettings `
        -CredentialTargets $opsCredentialTargets -InstitutionCode 'INST1'

    Test-BRAVOCondition -Condition ($null -eq $enrollApiKeyResult) `
        -Name 'Operations/ApprovedWithoutApiKeyMeansTtlExpiredReturnsNullNoThrow' `
        -Failure 'approved без apiKey (TTL вичерпано) має повернути $null без винятку, не намагаючись самовиправитись'

    $postEnrollCall = @($global:BRAVOOpsSelfTestHttpCalls | Where-Object { $_.Uri -like '*api/v1/enroll' -and $_.Method -eq 'POST' }) | Select-Object -First 1
    Test-BRAVOCondition -Condition (
        $null -ne $postEnrollCall -and
        $postEnrollCall.Headers['X-Bootstrap-Secret'] -eq 'fleet-bootstrap-secret' -and
        $postEnrollCall.BodyText -notmatch 'bootstrapSecret'
    ) -Name 'Operations/PostEnrollSendsBootstrapSecretOnlyViaHeaderNotBody' `
      -Failure "POST /enroll має нести bootstrap-секрет ЛИШЕ в заголовку X-Bootstrap-Secret, БЕЗ дублювання bootstrapSecret у JSON-тілі; body=$($postEnrollCall.BodyText)"

    # A1/A2: агент сам генерує claim (не з тіла запиту -- лише заголовок),
    # і воно валідний непорожній рядок (GUID), надіслане в заголовку, а не
    # в JSON-тілі.
    $generatedClaim = $null
    if ($null -ne $postEnrollCall) { $generatedClaim = [string]$postEnrollCall.Headers['X-Enrollment-Claim'] }
    $generatedClaimParsed = [guid]::Empty
    Test-BRAVOCondition -Condition (
        -not [string]::IsNullOrWhiteSpace($generatedClaim) -and
        [guid]::TryParse($generatedClaim, [ref]$generatedClaimParsed) -and
        $postEnrollCall.BodyText -notmatch 'claim'
    ) -Name 'Operations/PostEnrollSendsAgentGeneratedClaimHeaderNotInBody' `
      -Failure "POST /enroll має нести АГЕНТ-ЗГЕНЕРОВАНИЙ X-Enrollment-Claim (валідний GUID) у заголовку, НЕ в JSON-тілі; заголовок='$generatedClaim' body=$($postEnrollCall.BodyText)"

    # E10 regression guard на РЕАЛЬНОМУ функціональному шляху (не лише
    # ізольований виклик Join-BRAVOOperationsApiUrl вище): $opsSettings.ApiBaseUrl
    # тут навмисно БЕЗ '/api' (документована конвенція) — якщо колись хтось
    # поверне зайвий '/api' у -Path чи в конкатенацію, ця точна перевірка
    # URI впіймає подвоєння там, де воно реально впливає на трафік агента.
    Test-BRAVOCondition -Condition (
        $null -ne $postEnrollCall -and $postEnrollCall.Uri -eq 'https://ops.example.invalid/api/v1/enroll'
    ) -Name 'Operations/PostEnrollUriHasNoDuplicatedApiSegment' `
      -Failure "POST /enroll URI має бути рівно 'https://ops.example.invalid/api/v1/enroll' без дублювання /api; отримано '$($postEnrollCall.Uri)'"

    $getEnrollCall = @($global:BRAVOOpsSelfTestHttpCalls | Where-Object { $_.Method -eq 'GET' }) | Select-Object -First 1
    Test-BRAVOCondition -Condition (
        $null -ne $getEnrollCall -and
        -not [string]::IsNullOrWhiteSpace($generatedClaim) -and
        $getEnrollCall.Headers['X-Enrollment-Claim'] -eq $generatedClaim -and
        $getEnrollCall.Headers['X-Bootstrap-Secret'] -eq 'fleet-bootstrap-secret'
    ) -Name 'Operations/GetEnrollPollSendsSameAgentGeneratedClaimAsPost' `
      -Failure 'GET /enroll/:id має нести ТОЙ САМИЙ агент-згенерований X-Enrollment-Claim, що й POST /enroll (не сервер-виданий), плюс X-Bootstrap-Secret'

    # Claim персистований локально (той самий atomic-write патерн, що
    # server-id) -- незалежна перевірка вмісту файлу стану, а не лише
    # заголовків HTTP-викликів вище.
    $persistedEnrollmentStatePath = Join-Path $enrollDir 'BRAVO_OPERATIONS_ENROLLMENT.json'
    $persistedClaimOnDisk = $null
    if ([IO.File]::Exists($persistedEnrollmentStatePath)) {
        $persistedClaimOnDisk = [string]([IO.File]::ReadAllText($persistedEnrollmentStatePath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json).Claim
    }
    Test-BRAVOCondition -Condition ($persistedClaimOnDisk -eq $generatedClaim) `
        -Name 'Operations/EnrollmentClaimPersistedToDiskMatchesSentClaim' `
        -Failure "claim, надісланий у HTTP-заголовках, має бути персистований на диску ($persistedEnrollmentStatePath) для повторного використання; на диску='$persistedClaimOnDisk' надіслано='$generatedClaim'"

    # =====================================================================
    # A7: lost-response recovery -- повторний Invoke (симулює повторну
    # спробу після втраченої HTTP-відповіді на попередній цикл) несе РІВНО
    # ТОЙ САМИЙ serverId (незмінний, стан на диску) + ТОЙ САМИЙ claim
    # (персистований, НЕ перегенерований) -- жодної спеціальної обробки в
    # коді, просто природний ідемпотентний повтор.
    # =====================================================================
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'pending' }
    Enqueue-BRAVOOpsSelfTestHttpError -StatusCode 404 -BodyObject @{ error = 'not_found' }
    $enrollRetryResult = $null
    $enrollRetryThrew = $false
    try {
        $enrollRetryResult = Invoke-BRAVOOperationsEnrollment -OperationsReportingSettings $opsSettings `
            -CredentialTargets $opsCredentialTargets -InstitutionCode 'INST1'
    } catch {
        $enrollRetryThrew = $true
    }
    $retryPostCall = @($global:BRAVOOpsSelfTestHttpCalls | Where-Object { $_.Uri -like '*api/v1/enroll' -and $_.Method -eq 'POST' }) | Select-Object -First 1
    Test-BRAVOCondition -Condition (
        -not $enrollRetryThrew -and $null -eq $enrollRetryResult -and
        $null -ne $retryPostCall -and
        [string]$retryPostCall.Headers['X-Enrollment-Claim'] -eq $generatedClaim
    ) -Name 'Operations/LostResponseRetryReusesSameClaimNoSpecialHandling' `
      -Failure "повторний POST /enroll (симуляція втраченої відповіді попереднього циклу) має нести ТОЙ САМИЙ claim без жодної спецобробки; очікувано='$generatedClaim' надіслано='$($retryPostCall.Headers['X-Enrollment-Claim'])'"

    # 404 на poll (D7: невідрізнюваний "не готово"/revoked/wrong-claim) не
    # кидає і не губить локальний pending-стан (claim лишається на диску) --
    # уже покрито вище (retryPostCall/404), тут -- окрема регресія на
    # never-throw контракт.
    Test-BRAVOCondition -Condition (-not $enrollRetryThrew -and $null -eq $enrollRetryResult) `
        -Name 'Operations/PollNotFound404NeverThrowsReturnsNull' `
        -Failure '404 на GET /enroll/:id (D7 not_found) має повернути $null без винятку (never-throw invariant)'

    # =====================================================================
    # 409 already_finalized: термінально для цієї спроби, ніколи не кидає.
    # =====================================================================
    $enroll409Dir = Join-Path $opsSelfTestRoot 'Enroll409'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $enroll409Dir
    $global:BRAVOOpsSelfTestCredentialStore = @{ 'OpsSelfTestBootstrap' = 'fleet-bootstrap-secret' }
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    Enqueue-BRAVOOpsSelfTestHttpError -StatusCode 409 -BodyObject @{ error = 'already_finalized'; status = 'approved' }
    $enroll409Threw = $false
    $enroll409Result = $null
    try {
        $enroll409Result = Invoke-BRAVOOperationsEnrollment -OperationsReportingSettings $opsSettings `
            -CredentialTargets $opsCredentialTargets -InstitutionCode 'INST1'
    } catch {
        $enroll409Threw = $true
    }
    Test-BRAVOCondition -Condition (-not $enroll409Threw -and $null -eq $enroll409Result) `
        -Name 'Operations/PostEnrollAlreadyFinalized409NeverThrowsReturnsNull' `
        -Failure '409 already_finalized на POST /enroll має повернути $null без винятку -- термінально для цієї спроби, не loop'

    # =====================================================================
    # PR #225 thread @ line 870 (reveal window vs poll cadence): TTL-
    # expired (approved БЕЗ apiKey) WARNING має нести КОНКРЕТНУ, дієву
    # діагностику -- причину (5-хвилинне вікно видачі вичерпано), потрібну
    # дію (ручне admin reissue в Operations UI) і негайний наступний крок
    # (вручну запустити BRAVO_OPERATIONS_HEARTBEAT.ps1) -- НЕ generic
    # помилку і НЕ мовчазне залишення pending-стану назавжди. Return-
    # контракт ($null, never-throw) уже покритий
    # Operations/ApprovedWithoutApiKeyMeansTtlExpiredReturnsNullNoThrow
    # вище -- цей тест закриває окремий ґап: досі ніщо не перевіряло ТЕКСТ
    # повідомлення, лише факт повернення $null.
    # =====================================================================
    $ttlWarnDir = Join-Path $opsSelfTestRoot 'TtlExpiredWarningText'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $ttlWarnDir
    $global:BRAVOOpsSelfTestCredentialStore = @{ 'OpsSelfTestBootstrap' = 'fleet-bootstrap-secret' }
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'pending' }
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'approved' }   # apiKey deliberately absent -> TTL expired

    $global:BRAVOOpsSelfTestTtlExpiredWarnings = New-Object System.Collections.Generic.List[object]
    $originalWriteBravoLogForTtlTest = Get-Command -Name Write-BRAVOLog -CommandType Function -ErrorAction SilentlyContinue
    [void](New-Module -ScriptBlock {
        function Write-BRAVOLog {
            param([string]$Component, [string]$Level, [string]$Message, [switch]$Secondary)
            if ($Component -eq 'Operations' -and $Level -eq 'WARNING' -and $Message -like '*API-ключ*') {
                [void]$global:BRAVOOpsSelfTestTtlExpiredWarnings.Add($Message)
            }
        }
    })

    $ttlWarnResult = $null
    $ttlWarnThrew = $false
    try {
        $ttlWarnResult = Invoke-BRAVOOperationsEnrollment -OperationsReportingSettings $opsSettings `
            -CredentialTargets $opsCredentialTargets -InstitutionCode 'INST1'
    } catch {
        $ttlWarnThrew = $true
    }

    if ($null -ne $originalWriteBravoLogForTtlTest) {
        Set-Item -Path function:Write-BRAVOLog -Value $originalWriteBravoLogForTtlTest.ScriptBlock -Force
    } else {
        Remove-Item -Path function:Write-BRAVOLog -Force -ErrorAction SilentlyContinue
    }

    $ttlWarningText = if ($global:BRAVOOpsSelfTestTtlExpiredWarnings.Count -gt 0) { [string]$global:BRAVOOpsSelfTestTtlExpiredWarnings[0] } else { '' }
    Test-BRAVOCondition -Condition (-not $ttlWarnThrew -and $null -eq $ttlWarnResult) `
        -Name 'Operations/TtlExpiredWarningPathNeverThrowsReturnsNull' `
        -Failure 'TTL-expired (approved без apiKey) шлях, що продукує діагностичний WARNING, все ще має повернути $null без винятку'
    Test-BRAVOCondition -Condition (
        $global:BRAVOOpsSelfTestTtlExpiredWarnings.Count -ge 1 -and
        $ttlWarningText -match '(?i)approved' -and
        $ttlWarningText -match '5-хвилинне вікно' -and
        $ttlWarningText -match '(?i)admin reissue' -and
        $ttlWarningText -match 'BRAVO_OPERATIONS_HEARTBEAT\.ps1'
    ) -Name 'Operations/TtlExpiredWarningIsActionableNotGeneric' `
      -Failure "TTL-expired WARNING (approved без apiKey) має явно називати причину (5-хвилинне вікно), потрібну дію (admin reissue в Operations UI) і негайний наступний крок (запустити BRAVO_OPERATIONS_HEARTBEAT.ps1) -- не generic помилку; отримано ($($global:BRAVOOpsSelfTestTtlExpiredWarnings.Count) WARNING(-и)): '$ttlWarningText'"

    Remove-Variable -Name BRAVOOpsSelfTestTtlExpiredWarnings -Scope Global -Force -ErrorAction SilentlyContinue

    # =====================================================================
    # NEW (A3): 409 claim_mismatch -- відмінне від already_finalized,
    # термінально для цієї спроби, ніколи не кидає, НЕ ретраїться тісно.
    # =====================================================================
    $enrollClaimMismatchDir = Join-Path $opsSelfTestRoot 'EnrollClaimMismatch'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $enrollClaimMismatchDir
    $global:BRAVOOpsSelfTestCredentialStore = @{ 'OpsSelfTestBootstrap' = 'fleet-bootstrap-secret' }
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    Enqueue-BRAVOOpsSelfTestHttpError -StatusCode 409 -BodyObject @{ error = 'claim_mismatch' }
    $enrollClaimMismatchThrew = $false
    $enrollClaimMismatchResult = $null
    try {
        $enrollClaimMismatchResult = Invoke-BRAVOOperationsEnrollment -OperationsReportingSettings $opsSettings `
            -CredentialTargets $opsCredentialTargets -InstitutionCode 'INST1'
    } catch {
        $enrollClaimMismatchThrew = $true
    }
    Test-BRAVOCondition -Condition (-not $enrollClaimMismatchThrew -and $null -eq $enrollClaimMismatchResult) `
        -Name 'Operations/PostEnrollClaimMismatch409NeverThrowsReturnsNullTerminal' `
        -Failure '409 claim_mismatch на POST /enroll має повернути $null без винятку -- термінально для цієї спроби (можливе пошкодження локального claim-стану), не loop/retry'

    # =====================================================================
    # NEW (A5): 503 enrollment_not_configured -- відмінне від pending чи
    # від 401 (невірний секрет): функція взагалі не ввімкнена на бекенді.
    # Та сама постава, що pending -- $null, ніколи не кидає.
    # =====================================================================
    $enrollNotConfiguredDir = Join-Path $opsSelfTestRoot 'EnrollNotConfigured'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $enrollNotConfiguredDir
    $global:BRAVOOpsSelfTestCredentialStore = @{ 'OpsSelfTestBootstrap' = 'fleet-bootstrap-secret' }
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    Enqueue-BRAVOOpsSelfTestHttpError -StatusCode 503 -BodyObject @{ error = 'enrollment_not_configured' }
    $enrollNotConfiguredThrew = $false
    $enrollNotConfiguredResult = $null
    try {
        $enrollNotConfiguredResult = Invoke-BRAVOOperationsEnrollment -OperationsReportingSettings $opsSettings `
            -CredentialTargets $opsCredentialTargets -InstitutionCode 'INST1'
    } catch {
        $enrollNotConfiguredThrew = $true
    }
    Test-BRAVOCondition -Condition (-not $enrollNotConfiguredThrew -and $null -eq $enrollNotConfiguredResult) `
        -Name 'Operations/PostEnroll503NotConfiguredNeverThrowsReturnsNullSamePostureAsPending' `
        -Failure '503 enrollment_not_configured на POST /enroll має повернути $null без винятку -- "ще не доступно" (та сама постава, що pending), не hard error'

    # =====================================================================
    # PR #225 review-фікси (раунд 2, thread 7/9/6): regression-тести для
    # трьох виправлень, які раніше мали лише ad-hoc ручну перевірку під час
    # розробки (d2d1136), без committed regression-покриття.
    # =====================================================================

    # ---------------------------------------------------------------------
    # Thread 7 (review): serialize first-time enrollment claim creation.
    #
    # Get-BRAVOOperationsEnrollmentClaim (module-internal) серіалізує
    # генерацію+запис ПЕРШОГО claim через cross-process named mutex
    # (Enter-/Exit-BRAVOOperationsEnrollmentClaimLock) + double-checked
    # locking (перечитує стан ПІСЛЯ отримання локу). Без цього дві
    # одночасні "перші" спроби (напр. Health+Maintenance стартують за
    # розкладом одночасно) могли б прочитати ВІДСУТНІЙ claim, згенерувати
    # РІЗНІ GUID і атомарно перезаписати той самий файл -- переможець
    # запису лишає claim, якого "програвець" ніколи не побачив і надішле
    # СВІЙ (застарілий) GUID серверу, що дає постійний 409 claim_mismatch.
    #
    # Тест відтворює це напряму на рівні локу (не через окремі процеси):
    # 1) наш процес тримає named mutex ("виграв" перегонку першим);
    # 2) паралельний PowerShell-job (окремий процес, той самий
    #    Global\-простір імен мьютекса) намагається згенерувати claim
    #    того самого serverId одночасно -- має ЗАБЛОКУВАТИСЯ на mutex;
    # 3) наш процес персистує claim і звільняє лок;
    # 4) job має прокинутись, ПЕРЕЧИТАТИ вже записаний claim (double-check)
    #    і повернути РІВНО той самий claim, а НЕ згенерувати власний.
    # ---------------------------------------------------------------------
    $raceDir = Join-Path $opsSelfTestRoot 'EnrollmentClaimRace'
    New-Item -ItemType Directory -Path $raceDir -Force | Out-Null
    Set-BRAVOOpsSelfTestStateDirectory -Directory $raceDir
    $opsModulePsd1Path = Join-Path $root "modules\BRAVO.Operations\BRAVO.Operations.psd1"

    $enterLockFn = & $opsSelfTestModule { ${function:Enter-BRAVOOperationsEnrollmentClaimLock} }
    $exitLockFn = & $opsSelfTestModule { ${function:Exit-BRAVOOperationsEnrollmentClaimLock} }
    $stateGetFn = & $opsSelfTestModule { ${function:Get-BRAVOOperationsEnrollmentState} }
    $statePathFn = & $opsSelfTestModule { ${function:Get-BRAVOOperationsEnrollmentStatePath} }
    $writeAtomicFn = & $opsSelfTestModule { ${function:Write-BRAVOOperationsAtomicJsonFile} }

    $raceStatePath = & $statePathFn
    $ourMutex = & $enterLockFn -Path $raceStatePath -TimeoutSeconds 10
    $raceJob = $null
    $raceClaimFromJob = $null
    $raceJobThrew = $false
    $winnerClaim = $null
    try {
        Test-BRAVOCondition -Condition ($null -ne $ourMutex) `
            -Name 'Operations/EnrollmentClaimRacePrecondition_LockAcquired' `
            -Failure 'не вдалося отримати cross-process claim-lock у власному процесі -- передумова race-тесту не виконана'

        $raceJob = Start-Job -ScriptBlock {
            param($ModulePath, $StateDir)
            [Environment]::SetEnvironmentVariable('BRAVO_OPERATIONS_TEST_STATE_DIR', $StateDir)
            Import-Module -Name $ModulePath -Force -ErrorAction Stop
            $mod = Get-Module -Name 'BRAVO.Operations'
            # Приватна функція -- виконуємо всередині module session state
            # тим самим прийомом, що self-test суїта використовує для
            # $joinUrlFn вище.
            & $mod { Get-BRAVOOperationsEnrollmentClaim }
        } -ArgumentList $opsModulePsd1Path, $raceDir

        # Дати job-у реальний шанс дійти до Enter-Lock і заблокуватись на
        # нашому mutex (без цього тест міг би "випадково" пройти навіть
        # без коректної серіалізації, якщо job ще навіть не стартував).
        Start-Sleep -Milliseconds 800

        $winnerClaim = [guid]::NewGuid().ToString()
        $raceState = & $stateGetFn
        $raceState.Claim = $winnerClaim
        & $writeAtomicFn -Path $raceStatePath -Object $raceState
    } finally {
        if ($null -ne $ourMutex) { & $exitLockFn -Mutex $ourMutex }
    }

    if ($null -ne $raceJob) {
        try {
            $raceJobResult = $raceJob | Wait-Job -Timeout 20 | Receive-Job -ErrorAction Stop
            $raceClaimFromJob = [string]$raceJobResult
        } catch {
            $raceJobThrew = $true
        } finally {
            Remove-Job -Job $raceJob -Force -ErrorAction SilentlyContinue
        }
    }

    Test-BRAVOCondition -Condition (
        -not $raceJobThrew -and
        -not [string]::IsNullOrWhiteSpace($raceClaimFromJob) -and
        $raceClaimFromJob -eq $winnerClaim
    ) -Name 'Operations/EnrollmentClaimFirstCreationRaceSerializedNoOverwrite' `
      -Failure "конкурентна перша генерація claim має серіалізуватись через cross-process lock -- паралельний процес мав дочекатись і повернути ТОЙ САМИЙ claim, що записав переможець ('$winnerClaim'), а не власний GUID; отримано з job='$raceClaimFromJob' threw=$raceJobThrew"

    # ---------------------------------------------------------------------
    # Thread 9 (review): isolate malformed/poison outbox item during drain.
    #
    # Один item з відсутнім/невалідним RequestBody (пошкоджений на диску
    # вручну, схемна зміна, партиальний запис) НЕ повинен зупиняти дренаж
    # усієї черги -- раніше виняток при парсингу PSObject.Properties цього
    # ОДНОГО item летів у зовнішній try функції й переривав обробку ВСІХ
    # наступних items (FIFO-порядок), тож битий item "отруював" би чергу
    # на кожному наступному прогоні. Фікс: per-item isolation -> зіпсований
    # item іде в DeadLetter, решта (справний item) обробляється далі.
    # ---------------------------------------------------------------------
    $poisonDir = Join-Path $opsSelfTestRoot 'PoisonOutbox'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $poisonDir
    $outboxDirFn = & $opsSelfTestModule { ${function:Get-BRAVOOperationsOutboxDirectory} }
    $outboxDir = & $outboxDirFn
    New-Item -ItemType Directory -Path $outboxDir -Force | Out-Null

    # Обидва items записані НАПРЯМУ на диск (той самий формат, що Add-
    # BRAVOOperationsOutboxItem продукує) замість через Add-BRAVOOperationsOutboxItem
    # -- останній обчислює NextRetryAtUtc = зараз+30с (перший backoff-крок),
    # тобто щойно доданий item НЕ due для дренажу негайно; тест мусить
    # контролювати EnqueuedAtUtc (FIFO-порядок) і NextRetryAtUtc (due "в
    # минулому") явно, щоб обидва items реально дренувались у ЦЬОМУ виклику.

    # Item 1 (валідний) -- має бути доставлений успішно.
    $goodEventId = [guid]::NewGuid().ToString()
    $goodItemPath = Join-Path $outboxDir "$goodEventId.json"
    $goodPayload = [pscustomobject]@{
        Kind = 'event'; EventId = $goodEventId
        OccurredAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        SchemaVersion = 1; ApiPath = '/api/v1/events'
        RequestBody = @{ category = 'health'; severity = 'SUCCESS' }
        EnqueuedAtUtc = (Get-Date).ToUniversalTime().AddSeconds(-1).ToString('o')
        AttemptCount = 1
        NextRetryAtUtc = (Get-Date).ToUniversalTime().AddSeconds(-5).ToString('o')
        LastError = $null
    }
    [IO.File]::WriteAllText($goodItemPath, ($goodPayload | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

    # Item 2 (пошкоджений, EnqueuedAtUtc РАНІШЕ за item 1, щоб гарантовано
    # опинитись першим у FIFO-порядку дренажу, який Get-BRAVOOperationsOutboxItems
    # сортує саме за EnqueuedAtUtc) -- RequestBody замінено на рядок (не
    # об'єкт) прямим записом JSON на диск, імітуючи пошкодження/ручне
    # редагування/схемну неузгодженість.
    $poisonEventId = '0000-poison-' + [guid]::NewGuid().ToString()
    $poisonItemPath = Join-Path $outboxDir "$poisonEventId.json"
    $poisonPayload = [pscustomobject]@{
        Kind = 'event'; EventId = $poisonEventId
        OccurredAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        SchemaVersion = 1; ApiPath = '/api/v1/events'
        RequestBody = 'not-an-object-broken-payload'
        EnqueuedAtUtc = (Get-Date).ToUniversalTime().AddSeconds(-2).ToString('o')
        AttemptCount = 1
        NextRetryAtUtc = (Get-Date).ToUniversalTime().AddSeconds(-5).ToString('o')
        LastError = $null
    }
    [IO.File]::WriteAllText($poisonItemPath, ($poisonPayload | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'accepted' }
    $drainThrew = $false
    try {
        Invoke-BRAVOOperationsOutboxDrain -ApiBaseUrl $opsSettings.ApiBaseUrl -ApiKey 'test-api-key' `
            -CredentialTargets $opsCredentialTargets -TimeoutSeconds 5
    } catch {
        $drainThrew = $true
    }

    $deadLetterDirFn = & $opsSelfTestModule { ${function:Get-BRAVOOperationsOutboxDeadLetterDirectory} }
    $deadLetterDir = & $deadLetterDirFn
    $poisonMovedToDeadLetter = Test-Path -LiteralPath (Join-Path $deadLetterDir "$poisonEventId.json") -PathType Leaf
    $poisonRemainsInOutbox = Test-Path -LiteralPath $poisonItemPath -PathType Leaf
    $goodItemRemainsInOutbox = Test-Path -LiteralPath (Join-Path $outboxDir "$goodEventId.json") -PathType Leaf
    $goodItemWasSent = @($global:BRAVOOpsSelfTestHttpCalls | Where-Object { $_.Uri -like '*api/v1/events*' }).Count -ge 1

    Test-BRAVOCondition -Condition (-not $drainThrew) `
        -Name 'Operations/PoisonOutboxItemDoesNotAbortDrainForWholeQueue' `
        -Failure 'один пошкоджений outbox-item НЕ повинен кидати виняток, що зупиняє дренаж всієї черги (never-throw invariant дренажу)'
    Test-BRAVOCondition -Condition ($poisonMovedToDeadLetter -and -not $poisonRemainsInOutbox) `
        -Name 'Operations/PoisonOutboxItemIsolatedToDeadLetterNotLost' `
        -Failure "пошкоджений item (RequestBody не об'єкт) має бути переміщений у DeadLetter і видалений з активного outbox -- movedToDeadLetter=$poisonMovedToDeadLetter remainsInOutbox=$poisonRemainsInOutbox (item НЕ повинен просто губитись мовчки і НЕ повинен лишатись у активній черзі, блокуючи наступні прогони)"
    Test-BRAVOCondition -Condition (-not $goodItemRemainsInOutbox -and $goodItemWasSent) `
        -Name 'Operations/PoisonOutboxItemDoesNotBlockRemainingQueueDrain' `
        -Failure "справний item ($goodEventId) МАВ БУТИ успішно доставлений і видалений з outbox, попри поруч зіпсований item -- rest-of-queue має продовжити дренуватись; wasSent=$goodItemWasSent remainsInOutbox=$goodItemRemainsInOutbox"

    # ---------------------------------------------------------------------
    # Review PR #225: item з валідним RequestBody, але БЕЗ ApiPath. Перша
    # версія per-item ізоляції валідувала лише RequestBody, тому такий item
    # доходив до Invoke-BRAVOOperationsApiRequest із порожнім ОБОВ'ЯЗКОВИМ
    # -Path; PowerShell відхиляв це на binding-у (НЕ HTTP-збій, statusCode
    # $null), catch класифікував як transient і виходив із ЦІЛОГО дренажу.
    # Item лишався першим у FIFO і блокував усю чергу на кожному ретраї.
    # Той самий сценарій, що PoisonOutbox вище, лише інше поле конверта.
    # ---------------------------------------------------------------------
    $noPathDir = Join-Path $opsSelfTestRoot 'OutboxMissingApiPath'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $noPathDir
    $noPathOutboxDir = & $outboxDirFn
    New-Item -ItemType Directory -Path $noPathOutboxDir -Force | Out-Null

    # Справний item -- новіший за битий, тобто в FIFO-порядку ПІСЛЯ нього.
    $noPathGoodEventId = [guid]::NewGuid().ToString()
    $noPathGoodPayload = [pscustomobject]@{
        Kind = 'event'; EventId = $noPathGoodEventId
        OccurredAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        SchemaVersion = 1; ApiPath = '/api/v1/events'
        RequestBody = @{ category = 'health'; severity = 'SUCCESS' }
        EnqueuedAtUtc = (Get-Date).ToUniversalTime().AddSeconds(-1).ToString('o')
        AttemptCount = 1
        NextRetryAtUtc = (Get-Date).ToUniversalTime().AddSeconds(-5).ToString('o')
        LastError = $null
    }
    [IO.File]::WriteAllText((Join-Path $noPathOutboxDir "$noPathGoodEventId.json"), ($noPathGoodPayload | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

    $noPathEventId = '0000-nopath-' + [guid]::NewGuid().ToString()
    $noPathItemPath = Join-Path $noPathOutboxDir "$noPathEventId.json"
    $noPathPayload = [pscustomobject]@{
        Kind = 'event'; EventId = $noPathEventId
        OccurredAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        SchemaVersion = 1; ApiPath = ''
        RequestBody = @{ category = 'health'; severity = 'SUCCESS' }
        EnqueuedAtUtc = (Get-Date).ToUniversalTime().AddSeconds(-2).ToString('o')
        AttemptCount = 1
        NextRetryAtUtc = (Get-Date).ToUniversalTime().AddSeconds(-5).ToString('o')
        LastError = $null
    }
    [IO.File]::WriteAllText($noPathItemPath, ($noPathPayload | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'accepted' }
    $noPathDrainOutcome = $null
    $noPathDrainThrew = $false
    try {
        $noPathDrainOutcome = Invoke-BRAVOOperationsOutboxDrain -ApiBaseUrl $opsSettings.ApiBaseUrl -ApiKey 'test-api-key' `
            -CredentialTargets $opsCredentialTargets -TimeoutSeconds 5
    } catch {
        $noPathDrainThrew = $true
    }

    $noPathDeadLetterDir = & $deadLetterDirFn
    $noPathMovedToDeadLetter = Test-Path -LiteralPath (Join-Path $noPathDeadLetterDir "$noPathEventId.json") -PathType Leaf
    $noPathRemainsInOutbox = Test-Path -LiteralPath $noPathItemPath -PathType Leaf
    $noPathGoodRemainsInOutbox = Test-Path -LiteralPath (Join-Path $noPathOutboxDir "$noPathGoodEventId.json") -PathType Leaf

    Test-BRAVOCondition -Condition (-not $noPathDrainThrew -and $noPathMovedToDeadLetter -and -not $noPathRemainsInOutbox) `
        -Name 'Operations/OutboxItemWithoutApiPathIsDeadLetteredNotRetriedForever' `
        -Failure "item без ApiPath має бути карантинований у DeadLetter ще ДО транспорту (порожній -Path дав би parameter-binding збій, який класифікувався б як transient і повертався б на кожному ретраї); threw=$noPathDrainThrew movedToDeadLetter=$noPathMovedToDeadLetter remainsInOutbox=$noPathRemainsInOutbox"
    Test-BRAVOCondition -Condition (-not $noPathGoodRemainsInOutbox -and $noPathDrainOutcome -eq 'ok') `
        -Name 'Operations/OutboxItemWithoutApiPathDoesNotBlockRemainingQueueDrain' `
        -Failure "справний item після item-а без ApiPath МАВ БУТИ доставлений у тому самому дренажі, а результат дренажу -- 'ok', а не 'transient'; outcome=$noPathDrainOutcome goodRemainsInOutbox=$noPathGoodRemainsInOutbox"

    # ---------------------------------------------------------------------
    # #305: item без EventId (валідний JSON, ручна правка / часткове
    # відновлення). Під StrictMode 2.0 `$item.EventId` кидав виняток уже в
    # логуванні/dead-letter, виняток минав поелементну ізоляцію, і дренаж
    # зупинявся на цьому item на КОЖНОМУ прогоні. Тепер item карантиниться
    # в DeadLetter з окремою причиною ДО транспорту, решта черги йде далі.
    # ---------------------------------------------------------------------
    $noIdDir = Join-Path $opsSelfTestRoot 'OutboxMissingEventId'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $noIdDir
    $noIdOutboxDir = & $outboxDirFn
    New-Item -ItemType Directory -Path $noIdOutboxDir -Force | Out-Null

    $noIdGoodEventId = [guid]::NewGuid().ToString()
    $noIdGoodPayload = [pscustomobject]@{
        Kind = 'event'; EventId = $noIdGoodEventId
        OccurredAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        SchemaVersion = 1; ApiPath = '/api/v1/events'
        RequestBody = @{ category = 'health'; severity = 'SUCCESS' }
        EnqueuedAtUtc = (Get-Date).ToUniversalTime().AddSeconds(-1).ToString('o')
        AttemptCount = 1
        NextRetryAtUtc = (Get-Date).ToUniversalTime().AddSeconds(-5).ToString('o')
        LastError = $null
    }
    [IO.File]::WriteAllText((Join-Path $noIdOutboxDir "$noIdGoodEventId.json"), ($noIdGoodPayload | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

    # Без EventId і без EnqueuedAtUtc: сортується ПЕРШИМ, як в описі #305.
    # ApiPath/RequestBody валідні — без карантину подія пішла б у транспорт.
    $noIdFileBase = '0000-noeventid-' + [guid]::NewGuid().ToString('N')
    $noIdItemPath = Join-Path $noIdOutboxDir "$noIdFileBase.json"
    $noIdPayload = [pscustomobject]@{
        Kind = 'event'
        OccurredAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        SchemaVersion = 1; ApiPath = '/api/v1/events'
        RequestBody = @{ category = 'health'; severity = 'WARNING' }
        AttemptCount = 1
        NextRetryAtUtc = (Get-Date).ToUniversalTime().AddSeconds(-5).ToString('o')
        LastError = $null
    }
    [IO.File]::WriteAllText($noIdItemPath, ($noIdPayload | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'accepted' }
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'accepted' }
    $noIdDrainOutcome = $null
    $noIdDrainThrew = $null
    try {
        $noIdDrainOutcome = Invoke-BRAVOOperationsOutboxDrain -ApiBaseUrl $opsSettings.ApiBaseUrl -ApiKey 'test-api-key' `
            -CredentialTargets $opsCredentialTargets -TimeoutSeconds 5
    } catch {
        $noIdDrainThrew = $_.Exception.Message
    }

    $noIdDeadLetterDir = & $deadLetterDirFn
    $noIdDeadLetterReasons = New-Object 'System.Collections.Generic.List[string]'
    foreach ($deadLetterFile in @(Get-ChildItem -LiteralPath $noIdDeadLetterDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $deadLetterItem = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($deadLetterFile.FullName))
        if ($null -ne $deadLetterItem.PSObject.Properties['DeadLetterReason']) { $noIdDeadLetterReasons.Add([string]$deadLetterItem.DeadLetterReason) }
    }
    $noIdRemainsInOutbox = Test-Path -LiteralPath $noIdItemPath -PathType Leaf
    $noIdGoodRemainsInOutbox = Test-Path -LiteralPath (Join-Path $noIdOutboxDir "$noIdGoodEventId.json") -PathType Leaf
    # List[object]: лише .Count напряму; обгортка масивом кидає ArgumentException у PS 5.1.
    $noIdHttpCallCount = $global:BRAVOOpsSelfTestHttpCalls.Count

    Test-BRAVOCondition -Condition (
        $null -eq $noIdDrainThrew -and
        -not $noIdRemainsInOutbox -and
        $noIdDeadLetterReasons.Count -eq 1 -and
        $noIdDeadLetterReasons[0] -match 'EventId'
    ) `
        -Name 'Operations/OutboxItemWithoutEventIdIsDeadLetteredWithOwnReason' `
        -Failure "item без EventId має бути карантинований у DeadLetter з причиною про EventId, а не блокувати дренаж; threw='$noIdDrainThrew' remainsInOutbox=$noIdRemainsInOutbox deadLetterReasons='$($noIdDeadLetterReasons -join ' | ')'"
    Test-BRAVOCondition -Condition (
        -not $noIdGoodRemainsInOutbox -and
        $noIdDrainOutcome -eq 'ok' -and
        $noIdHttpCallCount -eq 1
    ) `
        -Name 'Operations/OutboxItemWithoutEventIdDoesNotBlockOrResendQueue' `
        -Failure "справний item після item-а без EventId МАВ БУТИ доставлений у тому самому дренажі (outcome 'ok'), а сам item без EventId не надсилається; outcome=$noIdDrainOutcome goodRemainsInOutbox=$noIdGoodRemainsInOutbox httpCalls=$noIdHttpCallCount"

    # ---------------------------------------------------------------------
    # #397: карантин зіпсованої події ніколи не знищує попередній
    # dead-letter-артефакт (доказ для ручного розбору). Ім'я dead-letter
    # для елемента без EventId раніше було детермінованим
    # (`missing-eventid-<санітизоване ім'я outbox-файлу>`), а запис ішов
    # через File.Replace — повернений вручну файл з тим самим ім'ям,
    # імена, що збігаються після санітизації (`a b` / `a_b`), і (на Windows)
    # імена, що відрізняються лише регістром, перезаписували попередній
    # артефакт. Нерядковий EventId (масив/об'єкт/число/bool) після
    # `[string]`-приведення вважався присутнім і подія йшла в транспорт.
    # ---------------------------------------------------------------------
    function New-BRAVOOpsSelfTestRawOutboxItem {
        param(
            [Parameter(Mandatory = $true)][string]$Directory,
            [Parameter(Mandatory = $true)][string]$FileBase,
            [Parameter(Mandatory = $true)][string]$Marker,
            [switch]$OmitEventId,
            [AllowNull()]$EventId = $null,
            [string]$ServerId = '',
            [object]$RequestBody = $null,
            [int]$EnqueuedOffsetSeconds = -10
        )
        $payload = [ordered]@{ Kind = 'event' }
        if (-not $OmitEventId) { $payload['EventId'] = $EventId }
        $payload['OccurredAtUtc'] = (Get-Date).ToUniversalTime().ToString('o')
        $payload['SchemaVersion'] = 1
        $payload['ApiPath'] = '/api/v1/events'
        $payload['RequestBody'] = if ($null -ne $RequestBody) { $RequestBody } else { @{ category = 'health'; severity = 'WARNING'; marker = $Marker } }
        $payload['EnqueuedAtUtc'] = (Get-Date).ToUniversalTime().AddSeconds($EnqueuedOffsetSeconds).ToString('o')
        $payload['AttemptCount'] = 1
        $payload['NextRetryAtUtc'] = (Get-Date).ToUniversalTime().AddSeconds(-5).ToString('o')
        $payload['LastError'] = $Marker
        if (-not [string]::IsNullOrWhiteSpace($ServerId)) { $payload['ServerId'] = $ServerId }
        $itemPath = Join-Path $Directory "$FileBase.json"
        [IO.File]::WriteAllText($itemPath, (([pscustomobject]$payload) | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
        return $itemPath
    }
    function Get-BRAVOOpsSelfTestDeadLetterSnapshot {
        param([Parameter(Mandatory = $true)][string]$Directory)
        $snapshot = New-Object System.Collections.Generic.List[object]
        foreach ($snapshotFile in @(Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $snapshotItem = $null
            try { $snapshotItem = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($snapshotFile.FullName)) } catch { $snapshotItem = $null }
            $snapshotMarker = ''
            $snapshotReason = ''
            if ($null -ne $snapshotItem -and $null -ne $snapshotItem.PSObject.Properties['LastError']) { $snapshotMarker = [string]$snapshotItem.LastError }
            if ($null -ne $snapshotItem -and $null -ne $snapshotItem.PSObject.Properties['DeadLetterReason']) { $snapshotReason = [string]$snapshotItem.DeadLetterReason }
            $snapshot.Add([pscustomobject]@{ Name = $snapshotFile.Name; Marker = $snapshotMarker; Reason = $snapshotReason })
        }
        return $snapshot.ToArray()
    }
    function Invoke-BRAVOOpsSelfTestDrainQuietly {
        try {
            [void](Invoke-BRAVOOperationsOutboxDrain -ApiBaseUrl $opsSettings.ApiBaseUrl -ApiKey 'test-api-key' `
                -CredentialTargets $opsCredentialTargets -TimeoutSeconds 5)
            return ''
        } catch {
            return [string]$_.Exception.Message
        }
    }

    # (a) Той самий outbox-файл без EventId двічі (ручне повернення).
    $dlRepeatDir = Join-Path $opsSelfTestRoot 'DeadLetterRepeatName'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $dlRepeatDir
    $dlRepeatOutboxDir = & $outboxDirFn
    New-Item -ItemType Directory -Path $dlRepeatOutboxDir -Force | Out-Null
    $dlRepeatBase = '0000-repeat-' + [guid]::NewGuid().ToString('N')
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlRepeatOutboxDir -FileBase $dlRepeatBase -Marker 'dl397-repeat-first' -OmitEventId)
    $dlRepeatThrew = Invoke-BRAVOOpsSelfTestDrainQuietly
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlRepeatOutboxDir -FileBase $dlRepeatBase -Marker 'dl397-repeat-second' -OmitEventId)
    $dlRepeatThrew += Invoke-BRAVOOpsSelfTestDrainQuietly
    $dlRepeatSnapshot = @(Get-BRAVOOpsSelfTestDeadLetterSnapshot -Directory (& $deadLetterDirFn))
    $dlRepeatMarkers = @($dlRepeatSnapshot | ForEach-Object { $_.Marker })
    $dlRepeatOutboxLeft = @(Get-ChildItem -LiteralPath $dlRepeatOutboxDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition (
        $dlRepeatThrew -eq '' -and
        $dlRepeatSnapshot.Count -eq 2 -and
        @($dlRepeatSnapshot | Where-Object { $_.Name -like 'missing-eventid-*' -and $_.Reason -match 'EventId відсутній' }).Count -eq 2 -and
        $dlRepeatMarkers -contains 'dl397-repeat-first' -and
        $dlRepeatMarkers -contains 'dl397-repeat-second' -and
        $dlRepeatOutboxLeft.Count -eq 0 -and
        $global:BRAVOOpsSelfTestHttpCalls.Count -eq 0
    ) -Name 'Operations/DeadLetterRepeatedMissingEventIdFileNameKeepsEarlierArtifact' `
      -Failure "#397: повторний карантин outbox-файлу з тим самим ім'ям без EventId не має перезаписувати попередній dead-letter; у DeadLetter: $(@($dlRepeatSnapshot | ForEach-Object { $_.Name + '=' + $_.Marker }) -join ', ') (очікувано 2 файли missing-eventid-* з обома маркерами), outbox=$($dlRepeatOutboxLeft.Count), HTTP=$($global:BRAVOOpsSelfTestHttpCalls.Count), виняток='$dlRepeatThrew'"

    # (b) Різні імена, що збігаються після санітизації (`a b` / `a_b`).
    $dlSanitizedDir = Join-Path $opsSelfTestRoot 'DeadLetterSanitizedCollision'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $dlSanitizedDir
    $dlSanitizedOutboxDir = & $outboxDirFn
    New-Item -ItemType Directory -Path $dlSanitizedOutboxDir -Force | Out-Null
    $dlSanitizedSuffix = [guid]::NewGuid().ToString('N')
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlSanitizedOutboxDir -FileBase ('0000-col ' + $dlSanitizedSuffix) -Marker 'dl397-sanitized-space' -OmitEventId -EnqueuedOffsetSeconds -20)
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlSanitizedOutboxDir -FileBase ('0000-col_' + $dlSanitizedSuffix) -Marker 'dl397-sanitized-underscore' -OmitEventId -EnqueuedOffsetSeconds -10)
    $dlSanitizedThrew = Invoke-BRAVOOpsSelfTestDrainQuietly
    $dlSanitizedSnapshot = @(Get-BRAVOOpsSelfTestDeadLetterSnapshot -Directory (& $deadLetterDirFn))
    $dlSanitizedMarkers = @($dlSanitizedSnapshot | ForEach-Object { $_.Marker })
    $dlSanitizedOutboxLeft = @(Get-ChildItem -LiteralPath $dlSanitizedOutboxDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition (
        $dlSanitizedThrew -eq '' -and
        $dlSanitizedSnapshot.Count -eq 2 -and
        @($dlSanitizedSnapshot | Where-Object { $_.Name -like 'missing-eventid-*' }).Count -eq 2 -and
        $dlSanitizedMarkers -contains 'dl397-sanitized-space' -and
        $dlSanitizedMarkers -contains 'dl397-sanitized-underscore' -and
        $dlSanitizedOutboxLeft.Count -eq 0 -and
        $global:BRAVOOpsSelfTestHttpCalls.Count -eq 0
    ) -Name 'Operations/DeadLetterSanitizedFileNameCollisionKeepsBothArtifacts' `
      -Failure "#397: два outbox-файли без EventId, імена яких збігаються після санітизації ('a b' / 'a_b'), мають дати два окремі dead-letter; у DeadLetter: $(@($dlSanitizedSnapshot | ForEach-Object { $_.Name + '=' + $_.Marker }) -join ', '), outbox=$($dlSanitizedOutboxLeft.Count), HTTP=$($global:BRAVOOpsSelfTestHttpCalls.Count), виняток='$dlSanitizedThrew'"

    # (c) Імена, що відрізняються лише регістром (NTFS їх не розрізняє).
    $dlCaseDir = Join-Path $opsSelfTestRoot 'DeadLetterCaseCollision'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $dlCaseDir
    $dlCaseOutboxDir = & $outboxDirFn
    New-Item -ItemType Directory -Path $dlCaseOutboxDir -Force | Out-Null
    $dlCaseBase = '0000-case-' + [guid]::NewGuid().ToString('N')
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlCaseOutboxDir -FileBase $dlCaseBase.ToUpperInvariant() -Marker 'dl397-case-upper' -OmitEventId)
    $dlCaseThrew = Invoke-BRAVOOpsSelfTestDrainQuietly
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlCaseOutboxDir -FileBase $dlCaseBase -Marker 'dl397-case-lower' -OmitEventId)
    $dlCaseThrew += Invoke-BRAVOOpsSelfTestDrainQuietly
    $dlCaseSnapshot = @(Get-BRAVOOpsSelfTestDeadLetterSnapshot -Directory (& $deadLetterDirFn))
    $dlCaseMarkers = @($dlCaseSnapshot | ForEach-Object { $_.Marker })
    $dlCaseOutboxLeft = @(Get-ChildItem -LiteralPath $dlCaseOutboxDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition (
        $dlCaseThrew -eq '' -and
        $dlCaseSnapshot.Count -eq 2 -and
        @($dlCaseSnapshot | Where-Object { $_.Name -like 'missing-eventid-*' }).Count -eq 2 -and
        $dlCaseMarkers -contains 'dl397-case-upper' -and
        $dlCaseMarkers -contains 'dl397-case-lower' -and
        $dlCaseOutboxLeft.Count -eq 0 -and
        $global:BRAVOOpsSelfTestHttpCalls.Count -eq 0
    ) -Name 'Operations/DeadLetterCaseInsensitiveFileNameCollisionKeepsBothArtifacts' `
      -Failure "#397: outbox-файли без EventId з іменами, що відрізняються лише регістром, мають дати два окремі dead-letter (NTFS регістр не розрізняє); у DeadLetter: $(@($dlCaseSnapshot | ForEach-Object { $_.Name + '=' + $_.Marker }) -join ', '), outbox=$($dlCaseOutboxLeft.Count), HTTP=$($global:BRAVOOpsSelfTestHttpCalls.Count), виняток='$dlCaseThrew'"

    # (d) Відсутній / порожній / whitespace / null EventId — кожен у
    # DeadLetter під іменем missing-eventid-*, з причиною про EventId, без
    # надсилання; справний сусід доставляється.
    $dlBlankDir = Join-Path $opsSelfTestRoot 'DeadLetterBlankEventId'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $dlBlankDir
    $dlBlankOutboxDir = & $outboxDirFn
    New-Item -ItemType Directory -Path $dlBlankOutboxDir -Force | Out-Null
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'accepted' }
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlBlankOutboxDir -FileBase ('0000-blank-absent-' + [guid]::NewGuid().ToString('N')) -Marker 'dl397-blank-absent' -OmitEventId -EnqueuedOffsetSeconds -40)
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlBlankOutboxDir -FileBase ('0000-blank-empty-' + [guid]::NewGuid().ToString('N')) -Marker 'dl397-blank-empty' -EventId '' -EnqueuedOffsetSeconds -30)
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlBlankOutboxDir -FileBase ('0000-blank-space-' + [guid]::NewGuid().ToString('N')) -Marker 'dl397-blank-space' -EventId '   ' -EnqueuedOffsetSeconds -20)
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlBlankOutboxDir -FileBase ('0000-blank-null-' + [guid]::NewGuid().ToString('N')) -Marker 'dl397-blank-null' -EventId $null -EnqueuedOffsetSeconds -15)
    $dlBlankGoodEventId = [guid]::NewGuid().ToString()
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlBlankOutboxDir -FileBase $dlBlankGoodEventId -Marker 'dl397-blank-good' -EventId $dlBlankGoodEventId -EnqueuedOffsetSeconds -5)
    $dlBlankThrew = Invoke-BRAVOOpsSelfTestDrainQuietly
    $dlBlankSnapshot = @(Get-BRAVOOpsSelfTestDeadLetterSnapshot -Directory (& $deadLetterDirFn))
    $dlBlankMarkers = @($dlBlankSnapshot | ForEach-Object { $_.Marker })
    $dlBlankOutboxLeft = @(Get-ChildItem -LiteralPath $dlBlankOutboxDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition (
        $dlBlankThrew -eq '' -and
        $dlBlankSnapshot.Count -eq 4 -and
        @($dlBlankSnapshot | Where-Object { $_.Name -like 'missing-eventid-*' -and $_.Reason -match 'EventId відсутній' }).Count -eq 4 -and
        $dlBlankMarkers -contains 'dl397-blank-absent' -and
        $dlBlankMarkers -contains 'dl397-blank-empty' -and
        $dlBlankMarkers -contains 'dl397-blank-space' -and
        $dlBlankMarkers -contains 'dl397-blank-null' -and
        $dlBlankOutboxLeft.Count -eq 0 -and
        $global:BRAVOOpsSelfTestHttpCalls.Count -eq 1
    ) -Name 'Operations/DeadLetterMissingEmptyWhitespaceNullEventIdUseMissingEventIdName' `
      -Failure "#397: відсутній/порожній/whitespace/null EventId -- кожен елемент у DeadLetter як missing-eventid-* з причиною про EventId, без надсилання; справний сусід доставлено (1 HTTP); у DeadLetter: $(@($dlBlankSnapshot | ForEach-Object { $_.Name + '=' + $_.Marker }) -join ', '), outbox=$($dlBlankOutboxLeft.Count), HTTP=$($global:BRAVOOpsSelfTestHttpCalls.Count), виняток='$dlBlankThrew'"

    # (e) Чужа ServerId + відсутній EventId: гілка карантину ідентичності
    # (раніше за перевірку EventId), той самий файл двічі.
    $dlForeignDir = Join-Path $opsSelfTestRoot 'DeadLetterForeignNoEventId'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $dlForeignDir
    $dlForeignOutboxDir = & $outboxDirFn
    New-Item -ItemType Directory -Path $dlForeignOutboxDir -Force | Out-Null
    $dlForeignDrainServerId = [string](& $opsSelfTestModule { Get-BRAVOOperationsServerId })
    $dlForeignServerId = [guid]::NewGuid().ToString()
    $dlForeignBase = '0000-foreign-' + [guid]::NewGuid().ToString('N')
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlForeignOutboxDir -FileBase $dlForeignBase -Marker 'dl397-foreign-first' -OmitEventId -ServerId $dlForeignServerId)
    $dlForeignThrew = Invoke-BRAVOOpsSelfTestDrainQuietly
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlForeignOutboxDir -FileBase $dlForeignBase -Marker 'dl397-foreign-second' -OmitEventId -ServerId $dlForeignServerId)
    $dlForeignThrew += Invoke-BRAVOOpsSelfTestDrainQuietly
    $dlForeignSnapshot = @(Get-BRAVOOpsSelfTestDeadLetterSnapshot -Directory (& $deadLetterDirFn))
    $dlForeignMarkers = @($dlForeignSnapshot | ForEach-Object { $_.Marker })
    $dlForeignOutboxLeft = @(Get-ChildItem -LiteralPath $dlForeignOutboxDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition (
        $dlForeignThrew -eq '' -and
        -not [string]::IsNullOrWhiteSpace($dlForeignDrainServerId) -and
        $dlForeignSnapshot.Count -eq 2 -and
        @($dlForeignSnapshot | Where-Object { $_.Name -like 'missing-eventid-*' -and $_.Reason -match [regex]::Escape($dlForeignServerId) }).Count -eq 2 -and
        $dlForeignMarkers -contains 'dl397-foreign-first' -and
        $dlForeignMarkers -contains 'dl397-foreign-second' -and
        $dlForeignOutboxLeft.Count -eq 0 -and
        $global:BRAVOOpsSelfTestHttpCalls.Count -eq 0
    ) -Name 'Operations/DeadLetterForeignServerIdWithoutEventIdKeepsEveryArtifact' `
      -Failure "#397: елемент чужої ідентичності без EventId карантиниться гілкою ідентичності (причина з чужою ServerId), без надсилання, а повтор того самого файлу не перезаписує попередній dead-letter; у DeadLetter: $(@($dlForeignSnapshot | ForEach-Object { $_.Name + '=' + $_.Marker }) -join ', '), outbox=$($dlForeignOutboxLeft.Count), HTTP=$($global:BRAVOOpsSelfTestHttpCalls.Count), виняток='$dlForeignThrew'"

    # (f) Нерядковий EventId (масив/об'єкт/число/bool): продюсери пишуть
    # лише рядок-GUID ([string]$EventId у Add-BRAVOOperationsOutboxItem),
    # тож такий елемент — пошкоджений: dead-letter, а не надсилання.
    $dlTypeDir = Join-Path $opsSelfTestRoot 'DeadLetterMalformedEventIdType'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $dlTypeDir
    $dlTypeOutboxDir = & $outboxDirFn
    New-Item -ItemType Directory -Path $dlTypeOutboxDir -Force | Out-Null
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    for ($dlTypeIndex = 0; $dlTypeIndex -lt 5; $dlTypeIndex++) { Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'accepted' } }
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlTypeOutboxDir -FileBase ('0000-type-array-' + [guid]::NewGuid().ToString('N')) -Marker 'dl397-type-array' -EventId @('evt-part-a', 'evt-part-b') -EnqueuedOffsetSeconds -40)
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlTypeOutboxDir -FileBase ('0000-type-object-' + [guid]::NewGuid().ToString('N')) -Marker 'dl397-type-object' -EventId @{ nested = 'evt-nested' } -EnqueuedOffsetSeconds -30)
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlTypeOutboxDir -FileBase ('0000-type-number-' + [guid]::NewGuid().ToString('N')) -Marker 'dl397-type-number' -EventId 12345 -EnqueuedOffsetSeconds -20)
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlTypeOutboxDir -FileBase ('0000-type-bool-' + [guid]::NewGuid().ToString('N')) -Marker 'dl397-type-bool' -EventId $true -EnqueuedOffsetSeconds -15)
    $dlTypeGoodEventId = [guid]::NewGuid().ToString()
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlTypeOutboxDir -FileBase $dlTypeGoodEventId -Marker 'dl397-type-good' -EventId $dlTypeGoodEventId -EnqueuedOffsetSeconds -5)
    $dlTypeThrew = Invoke-BRAVOOpsSelfTestDrainQuietly
    $dlTypeSnapshot = @(Get-BRAVOOpsSelfTestDeadLetterSnapshot -Directory (& $deadLetterDirFn))
    $dlTypeMarkers = @($dlTypeSnapshot | ForEach-Object { $_.Marker })
    $dlTypeOutboxLeft = @(Get-ChildItem -LiteralPath $dlTypeOutboxDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition (
        $dlTypeThrew -eq '' -and
        $dlTypeSnapshot.Count -eq 4 -and
        @($dlTypeSnapshot | Where-Object { $_.Name -like 'missing-eventid-*' -and $_.Reason -match 'EventId відсутній' }).Count -eq 4 -and
        $dlTypeMarkers -contains 'dl397-type-array' -and
        $dlTypeMarkers -contains 'dl397-type-object' -and
        $dlTypeMarkers -contains 'dl397-type-number' -and
        $dlTypeMarkers -contains 'dl397-type-bool' -and
        $dlTypeOutboxLeft.Count -eq 0 -and
        $global:BRAVOOpsSelfTestHttpCalls.Count -eq 1
    ) -Name 'Operations/MalformedEventIdTypeIsDeadLetteredNotSent' `
      -Failure "#397: EventId не-рядок (масив/об'єкт/число/bool) -- пошкоджений елемент: DeadLetter missing-eventid-* з причиною про EventId і без надсилання; доставлено лише справний рядковий EventId (1 HTTP); у DeadLetter: $(@($dlTypeSnapshot | ForEach-Object { $_.Name + '=' + $_.Marker }) -join ', '), outbox=$($dlTypeOutboxLeft.Count), HTTP=$($global:BRAVOOpsSelfTestHttpCalls.Count), виняток='$dlTypeThrew'"

    # (g) Валідний EventId, що вже має dead-letter (ручне повернення
    # пошкодженої події): той самий інваріант для канонічного імені.
    $dlSameIdDir = Join-Path $opsSelfTestRoot 'DeadLetterRepeatedEventId'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $dlSameIdDir
    $dlSameIdOutboxDir = & $outboxDirFn
    New-Item -ItemType Directory -Path $dlSameIdOutboxDir -Force | Out-Null
    $dlSameIdDeadLetterDir = & $deadLetterDirFn
    New-Item -ItemType Directory -Path $dlSameIdDeadLetterDir -Force | Out-Null
    $dlSameIdEventId = [guid]::NewGuid().ToString()
    $dlSameIdEarlierPath = Join-Path $dlSameIdDeadLetterDir "$dlSameIdEventId.json"
    [IO.File]::WriteAllText($dlSameIdEarlierPath, (([pscustomobject]@{
        Kind = 'event'; EventId = $dlSameIdEventId; ApiPath = '/api/v1/events'
        RequestBody = 'not-an-object-earlier'; LastError = 'dl397-sameid-earlier'
        DeadLetteredAtUtc = (Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o')
        DeadLetterReason = 'Пошкоджений outbox item (earlier)'; DeadLetterKind = 'Rejected'
    }) | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    [void](New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlSameIdOutboxDir -FileBase $dlSameIdEventId -Marker 'dl397-sameid-later' -EventId $dlSameIdEventId -RequestBody 'not-an-object-later')
    $dlSameIdThrew = Invoke-BRAVOOpsSelfTestDrainQuietly
    $dlSameIdSnapshot = @(Get-BRAVOOpsSelfTestDeadLetterSnapshot -Directory $dlSameIdDeadLetterDir)
    $dlSameIdEarlier = @($dlSameIdSnapshot | Where-Object { $_.Name -eq "$dlSameIdEventId.json" })
    $dlSameIdLater = @($dlSameIdSnapshot | Where-Object { $_.Name -like "$dlSameIdEventId*" -and $_.Marker -eq 'dl397-sameid-later' })
    $dlSameIdOutboxLeft = @(Get-ChildItem -LiteralPath $dlSameIdOutboxDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition (
        $dlSameIdThrew -eq '' -and
        $dlSameIdSnapshot.Count -eq 2 -and
        $dlSameIdEarlier.Count -eq 1 -and
        $dlSameIdEarlier[0].Marker -eq 'dl397-sameid-earlier' -and
        $dlSameIdLater.Count -eq 1 -and
        $dlSameIdOutboxLeft.Count -eq 0 -and
        $global:BRAVOOpsSelfTestHttpCalls.Count -eq 0
    ) -Name 'Operations/DeadLetterRepeatedEventIdKeepsEarlierArtifact' `
      -Failure "#397: повторний карантин події з тим самим EventId не має перезаписувати попередній dead-letter <EventId>.json; новий артефакт -- окремий файл з тим самим префіксом; у DeadLetter: $(@($dlSameIdSnapshot | ForEach-Object { $_.Name + '=' + $_.Marker }) -join ', '), outbox=$($dlSameIdOutboxLeft.Count), HTTP=$($global:BRAVOOpsSelfTestHttpCalls.Count), виняток='$dlSameIdThrew'"

    # (h) Запис dead-letter не вдається (канонічне ім'я зайняте КАТАЛОГОМ:
    # File.Move кидає, а File.Exists для каталогу -- $false, тож це не
    # колізія, а справжня помилка). Інваріант #397: outbox-файл лишається,
    # без надсилання, WARNING з причиною, попередній артефакт не змінено;
    # лог дренажу не має стверджувати "переміщено в dead-letter".
    $dlFailDir = Join-Path $opsSelfTestRoot 'DeadLetterWriteFailure'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $dlFailDir
    $dlFailOutboxDir = & $outboxDirFn
    New-Item -ItemType Directory -Path $dlFailOutboxDir -Force | Out-Null
    $dlFailDeadLetterDir = & $deadLetterDirFn
    New-Item -ItemType Directory -Path $dlFailDeadLetterDir -Force | Out-Null
    [void](& $opsSelfTestModule { Get-BRAVOOperationsServerId })
    $dlFailPoisonBase = '0000-wfail-poison-' + [guid]::NewGuid().ToString('N')
    $dlFailForeignBase = '0000-wfail-foreign-' + [guid]::NewGuid().ToString('N')
    $dlFailPoisonPath = New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlFailOutboxDir -FileBase $dlFailPoisonBase -Marker 'dl397-wfail-poison' -OmitEventId -EnqueuedOffsetSeconds -20
    $dlFailForeignPath = New-BRAVOOpsSelfTestRawOutboxItem -Directory $dlFailOutboxDir -FileBase $dlFailForeignBase -Marker 'dl397-wfail-foreign' -OmitEventId -ServerId ([guid]::NewGuid().ToString()) -EnqueuedOffsetSeconds -10
    $dlFailPoisonBytesBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($dlFailPoisonPath))
    $dlFailForeignBytesBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($dlFailForeignPath))
    $dlFailBlockers = @(
        (Join-Path $dlFailDeadLetterDir "missing-eventid-$dlFailPoisonBase.json"),
        (Join-Path $dlFailDeadLetterDir "missing-eventid-$dlFailForeignBase.json")
    )
    foreach ($dlFailBlocker in $dlFailBlockers) { New-Item -ItemType Directory -Path $dlFailBlocker -Force | Out-Null }
    $dlFailEarlierPath = Join-Path $dlFailDeadLetterDir ('missing-eventid-0000-earlier-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($dlFailEarlierPath, (([pscustomobject]@{
        Kind = 'event'; LastError = 'dl397-wfail-earlier'
        DeadLetteredAtUtc = (Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o')
        DeadLetterReason = 'EventId відсутній (earlier)'; DeadLetterKind = 'Rejected'
    }) | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    $dlFailEarlierBytesBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($dlFailEarlierPath))

    $global:BRAVOOpsSelfTestDeadLetterWarnings = New-Object System.Collections.Generic.List[object]
    $originalWriteBravoLogForDeadLetterTest = Get-Command -Name Write-BRAVOLog -CommandType Function -ErrorAction SilentlyContinue
    [void](New-Module -ScriptBlock {
        function Write-BRAVOLog {
            param([string]$Component, [string]$Level, [string]$Message, [switch]$Secondary)
            if ($Component -eq 'Operations' -and $Level -eq 'WARNING') {
                [void]$global:BRAVOOpsSelfTestDeadLetterWarnings.Add($Message)
            }
        }
    })
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    $dlFailThrew = Invoke-BRAVOOpsSelfTestDrainQuietly
    if ($null -ne $originalWriteBravoLogForDeadLetterTest) {
        Set-Item -Path function:Write-BRAVOLog -Value $originalWriteBravoLogForDeadLetterTest.ScriptBlock -Force
    } else {
        Remove-Item -Path function:Write-BRAVOLog -Force -ErrorAction SilentlyContinue
    }
    $dlFailWarnings = $global:BRAVOOpsSelfTestDeadLetterWarnings.ToArray()
    $dlFailMoveWarnings = @($dlFailWarnings | Where-Object { $_ -like '*Не вдалося перемістити*dead-letter*' })
    $dlFailPoisonKept = (Test-Path -LiteralPath $dlFailPoisonPath -PathType Leaf) -and ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dlFailPoisonPath)) -eq $dlFailPoisonBytesBefore)
    $dlFailForeignKept = (Test-Path -LiteralPath $dlFailForeignPath -PathType Leaf) -and ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dlFailForeignPath)) -eq $dlFailForeignBytesBefore)
    $dlFailEarlierKept = (Test-Path -LiteralPath $dlFailEarlierPath -PathType Leaf) -and ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dlFailEarlierPath)) -eq $dlFailEarlierBytesBefore)
    $dlFailBlockersKept = @($dlFailBlockers | Where-Object { Test-Path -LiteralPath $_ -PathType Container }).Count -eq 2
    $dlFailDeadLetterFiles = @(Get-ChildItem -LiteralPath $dlFailDeadLetterDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition (
        $dlFailThrew -eq '' -and
        $dlFailPoisonKept -and
        $dlFailForeignKept -and
        $dlFailEarlierKept -and
        $dlFailBlockersKept -and
        $dlFailDeadLetterFiles.Count -eq 1 -and
        $dlFailMoveWarnings.Count -eq 2 -and
        $global:BRAVOOpsSelfTestHttpCalls.Count -eq 0
    ) -Name 'Operations/DeadLetterWriteFailureKeepsOutboxItemAndEarlierArtifact' `
      -Failure "#397: якщо dead-letter не записався, outbox-файл має лишитися без змін, без надсилання, з WARNING про невдале переміщення, а попередні dead-letter-артефакти -- незмінними; poisonKept=$dlFailPoisonKept foreignKept=$dlFailForeignKept earlierKept=$dlFailEarlierKept blockersKept=$dlFailBlockersKept deadLetterFiles=$($dlFailDeadLetterFiles.Count) moveWarnings=$($dlFailMoveWarnings.Count) HTTP=$($global:BRAVOOpsSelfTestHttpCalls.Count) виняток='$dlFailThrew'"
    $dlFailClaimedMoved = @($dlFailWarnings | Where-Object { $_ -like '*переміщено в dead-letter*' })
    $dlFailStayed = @($dlFailWarnings | Where-Object { $_ -like '*лишається в outbox*' })
    Test-BRAVOCondition -Condition (
        $dlFailClaimedMoved.Count -eq 0 -and
        $dlFailStayed.Count -eq 2
    ) -Name 'Operations/DeadLetterWriteFailureIsNotLoggedAsMoved' `
      -Failure "#397: після невдалого карантину (гілки ідентичності й пошкодженого конверта) лог дренажу не має казати 'переміщено в dead-letter', а має казати, що item лишається в outbox; WARNING: $($dlFailWarnings -join ' | ')"
    Remove-Variable -Name BRAVOOpsSelfTestDeadLetterWarnings -Scope Global -Force -ErrorAction SilentlyContinue
    } catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'Operations/ApprovedWithoutApiKeyMeansTtlExpiredReturnsNullNoThrow' } }
    if (Enter-BRAVOSelfTestSection -Name 'Operations/EnabledWithEmptyApiBaseUrlFailsClosedReturnsNull' -DependsOn 'Operations/UrlNormalizationTrailingSlashInvariant') { try {

    # ---------------------------------------------------------------------
    # Thread 6/P2 (review): Enabled=true + порожній ApiBaseUrl -- НЕ
    # мовчазний no-op. Throttled WARNING (LastApiBaseUrlMissingLoggedAtUtc),
    # та сама throttle-політика, що pending/404/TTL-expired (типово 15 хв):
    # перший виклик логує, ПОВТОРНИЙ виклик у межах throttle-вікна -- ні.
    # ---------------------------------------------------------------------
    $emptyUrlDir = Join-Path $opsSelfTestRoot 'EmptyApiBaseUrl'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $emptyUrlDir
    $global:BRAVOOpsSelfTestCredentialStore = @{}
    $emptyUrlSettings = @{ Enabled = $true; ApiBaseUrl = ''; ProductType = 'LIMS'; RequestTimeoutSeconds = 5 }

    $emptyUrlWarnings = New-Object System.Collections.Generic.List[object]
    $originalWriteBravoLog = Get-Command -Name Write-BRAVOLog -CommandType Function -ErrorAction SilentlyContinue
    [void](New-Module -ScriptBlock {
        function Write-BRAVOLog {
            param([string]$Component, [string]$Level, [string]$Message, [switch]$Secondary)
            if ($Component -eq 'Operations' -and $Level -eq 'WARNING' -and $Message -like '*ApiBaseUrl порожній*') {
                [void]$global:BRAVOOpsSelfTestApiBaseUrlWarnings.Add($Message)
            }
        }
    })
    $global:BRAVOOpsSelfTestApiBaseUrlWarnings = $emptyUrlWarnings

    # Перший виклик: Enabled=true, ApiBaseUrl порожній -> має повернути
    # $null (fail-closed, не намагається енролитись без URL) І залогувати
    # РІВНО один throttled WARNING (не мовчазний no-op, review P2).
    $emptyUrl1 = Invoke-BRAVOOperationsEnrollment -OperationsReportingSettings $emptyUrlSettings `
        -CredentialTargets $opsCredentialTargets -InstitutionCode 'INST1'
    $emptyUrlWarningsAfterFirst = $emptyUrlWarnings.Count

    # Другий виклик одразу за першим (у межах throttle-вікна) -- НЕ повинен
    # додати ще один WARNING (throttle працює), лишаючись при цьому
    # so само fail-closed ($null).
    $emptyUrl2 = Invoke-BRAVOOperationsEnrollment -OperationsReportingSettings $emptyUrlSettings `
        -CredentialTargets $opsCredentialTargets -InstitutionCode 'INST1'
    $emptyUrlWarningsAfterSecond = $emptyUrlWarnings.Count

    # Pre-existing self-test harness bug (виявлено регресійними тестами
    # PR #225 раунд 3, thread 4/5 нижче): $originalWriteBravoLog вище
    # захоплював РЕАЛЬНИЙ Write-BRAVOLog ДО перевизначення, але ніколи не
    # використовувався для відновлення -- голий Remove-Item просто видаляв
    # global Function:-drive entry ПОВНІСТЮ (New-Module -ScriptBlock
    # матеріалізує функцію напряму в $global:Function:-drive, замінюючи
    # той самий entry, що Import-Module BRAVO.Logging туди поклав; Remove-
    # Item після цього лишає ІМ'Я взагалі без жодного визначення -- не
    # "падіння" назад до module-exported версії). Будь-який Operations-код,
    # що викликає Write-BRAVOLog ПІСЛЯ цього блоку (наприклад,
    # Invoke-BRAVOOperationsOutboxDrain у тестах нижче), падав з "term
    # 'Write-BRAVOLog' is not recognized". Фікс: відновити РЕАЛЬНИЙ
    # ScriptBlock, захоплений вище, замість видалення entry.
    if ($null -ne $originalWriteBravoLog) {
        Set-Item -Path function:Write-BRAVOLog -Value $originalWriteBravoLog.ScriptBlock -Force
    } else {
        Remove-Item -Path function:Write-BRAVOLog -Force -ErrorAction SilentlyContinue
    }

    Test-BRAVOCondition -Condition ($null -eq $emptyUrl1 -and $null -eq $emptyUrl2) `
        -Name 'Operations/EnabledWithEmptyApiBaseUrlFailsClosedReturnsNull' `
        -Failure 'Enabled=true з порожнім ApiBaseUrl має повернути $null (fail-closed), без спроби реального enrollment'
    Test-BRAVOCondition -Condition ($emptyUrlWarningsAfterFirst -eq 1) `
        -Name 'Operations/EnabledWithEmptyApiBaseUrlLogsWarningNotSilent' `
        -Failure "Enabled=true + порожній ApiBaseUrl МАЄ залогувати WARNING (review P2: раніше цей шлях був повністю мовчазним) -- очікувано рівно 1 WARNING після першого виклику, отримано $emptyUrlWarningsAfterFirst"
    Test-BRAVOCondition -Condition ($emptyUrlWarningsAfterSecond -eq 1) `
        -Name 'Operations/EnabledWithEmptyApiBaseUrlWarningIsThrottledNotSpammed' `
        -Failure "повторний виклик у межах throttle-вікна (типово 15 хв) НЕ повинен додавати ще один WARNING -- очікувано лишити лічильник=1, отримано $emptyUrlWarningsAfterSecond"

    Remove-Variable -Name BRAVOOpsSelfTestApiBaseUrlWarnings -Scope Global -Force -ErrorAction SilentlyContinue

    # =====================================================================
    # PR #225 review-фікси (раунд 3): regression-тести для двох виправлень
    # без попереднього committed покриття -- unbounded outbox drain (thread
    # 4) і втрата подій під час pending-enrollment (thread 5).
    # =====================================================================

    # ---------------------------------------------------------------------
    # Thread 4 (review): unbounded outbox drain -- MaxItemsPerDrain/
    # MaxDrainDurationSeconds обмежують ОДИН виклик Invoke-BRAVOOperationsOutboxDrain,
    # щоб черга, що накопичилась під час тривалого простою backend, не
    # блокувала Archive/Health/Maintenance-прогін на необмежений час,
    # намагаючись здренувати все одразу.
    # ---------------------------------------------------------------------
    $boundedDrainDir = Join-Path $opsSelfTestRoot 'BoundedDrain'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $boundedDrainDir
    $global:BRAVOOpsSelfTestCredentialStore = @{ 'OpsSelfTestApiKey' = 'bounded-drain-api-key' }
    $boundedOutboxDirFn = & $opsSelfTestModule { ${function:Get-BRAVOOperationsOutboxDirectory} }
    $boundedOutboxDir = & $boundedOutboxDirFn
    New-Item -ItemType Directory -Path $boundedOutboxDir -Force | Out-Null

    # 5 валідних, усі due (NextRetryAtUtc у минулому), EnqueuedAtUtc
    # зростає (FIFO), записані напряму на диск -- той самий формат, що
    # Add-BRAVOOperationsOutboxItem продукує (той самий прийом, що
    # PoisonOutbox-тест вище).
    for ($i = 0; $i -lt 5; $i++) {
        $boundedEventId = "bounded-item-$i-" + [guid]::NewGuid().ToString()
        $boundedItemPath = Join-Path $boundedOutboxDir "$boundedEventId.json"
        $boundedPayload = [pscustomobject]@{
            Kind = 'event'; EventId = $boundedEventId
            OccurredAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            SchemaVersion = 1; ApiPath = '/api/v1/events'
            RequestBody = @{ category = 'health'; severity = 'SUCCESS' }
            EnqueuedAtUtc = (Get-Date).ToUniversalTime().AddSeconds(-100 + $i).ToString('o')
            AttemptCount = 1
            NextRetryAtUtc = (Get-Date).ToUniversalTime().AddSeconds(-5).ToString('o')
            LastError = $null
        }
        [IO.File]::WriteAllText($boundedItemPath, ($boundedPayload | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    }

    # (a) MaxItemsPerDrain: рівно 2 замокованих HTTP-успіхи в черзі -- якщо
    # дренаж спробує обробити 3-й item, фейковий Invoke-WebRequest кине
    # "жодної замокованої відповіді в черзі" (перевіряється нижче через
    # -not $itemCountDrainThrew).
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'accepted' }
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'accepted' }
    $itemCountDrainThrew = $false
    try {
        Invoke-BRAVOOperationsOutboxDrain -ApiBaseUrl $opsSettings.ApiBaseUrl -ApiKey 'bounded-drain-api-key' `
            -CredentialTargets $opsCredentialTargets -TimeoutSeconds 5 -MaxItemsPerDrain 2
    } catch {
        $itemCountDrainThrew = $true
    }
    $boundedItemsAfterCountLimit = @(Get-ChildItem -LiteralPath $boundedOutboxDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition (-not $itemCountDrainThrew) `
        -Name 'Operations/DrainMaxItemsPerDrainDoesNotThrow' `
        -Failure 'дренаж з -MaxItemsPerDrain 2 не повинен кидати виняток (never-throw invariant)'
    Test-BRAVOCondition -Condition ($boundedItemsAfterCountLimit.Count -eq 3) `
        -Name 'Operations/DrainMaxItemsPerDrainStopsAtLimitLeavesRestForNextDrain' `
        -Failure "-MaxItemsPerDrain 2 має обробити РІВНО 2 з 5 due-items за один виклик, лишивши 3 для наступного дренажу; знайдено $($boundedItemsAfterCountLimit.Count) (очікувано 3)"

    # (b) MaxDrainDurationSeconds: 0 -> stopwatch.Elapsed.TotalSeconds
    # (>= 0.0 одразу після StartNew()) негайно перевищує ліміт -- дренаж
    # має зупинитись ДО обробки першого ж item, без жодного HTTP-виклику
    # (порожня черга замокованих відповідей -- будь-яка спроба виклику
    # Invoke-WebRequest кинула б виняток, який тест ловить нижче).
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    $durationDrainThrew = $false
    try {
        Invoke-BRAVOOperationsOutboxDrain -ApiBaseUrl $opsSettings.ApiBaseUrl -ApiKey 'bounded-drain-api-key' `
            -CredentialTargets $opsCredentialTargets -TimeoutSeconds 5 -MaxItemsPerDrain 500 -MaxDrainDurationSeconds 0
    } catch {
        $durationDrainThrew = $true
    }
    $boundedItemsAfterDurationLimit = @(Get-ChildItem -LiteralPath $boundedOutboxDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition (-not $durationDrainThrew -and $global:BRAVOOpsSelfTestHttpCalls.Count -eq 0) `
        -Name 'Operations/DrainMaxDrainDurationSecondsStopsBeforeAnyHttpCall' `
        -Failure "-MaxDrainDurationSeconds 0 має зупинити дренаж ДО будь-якого HTTP-виклику (never-throw, 0 HTTP calls); threw=$durationDrainThrew httpCalls=$($global:BRAVOOpsSelfTestHttpCalls.Count)"
    Test-BRAVOCondition -Condition ($boundedItemsAfterDurationLimit.Count -eq 3) `
        -Name 'Operations/DrainMaxDrainDurationSecondsLeavesQueueForNextDrain' `
        -Failure "-MaxDrainDurationSeconds 0 не повинен видаляти жодного item з Outbox\ (та сама черга з 3 items з попередньої перевірки); знайдено $($boundedItemsAfterDurationLimit.Count)"

    # ---------------------------------------------------------------------
    # Companion (Add-BRAVOOperationsOutboxItem, module-internal): bounded
    # outbox size -- найстаріший item (за FIFO/EnqueuedAtUtc) витісняється в
    # DeadLetter\, коли черга досягає MaxOutboxItems, замість необмеженого
    # росту (постійно pending/revoked ідентичність могла б накопичувати
    # items назавжди без цієї межі).
    # ---------------------------------------------------------------------
    $evictDir = Join-Path $opsSelfTestRoot 'OutboxEviction'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $evictDir
    $addOutboxItemFn = & $opsSelfTestModule { ${function:Add-BRAVOOperationsOutboxItem} }

    $evictEventId1 = 'evict-oldest-' + [guid]::NewGuid().ToString()
    $evictEventId2 = 'evict-middle-' + [guid]::NewGuid().ToString()
    $evictEventId3 = 'evict-newest-' + [guid]::NewGuid().ToString()
    & $addOutboxItemFn -Kind 'event' -EventId $evictEventId1 -OccurredAtUtc (Get-Date).ToUniversalTime().ToString('o') `
        -SchemaVersion 1 -ApiPath '/api/v1/events' -RequestBody @{ category = 'health'; severity = 'SUCCESS' } -MaxOutboxItems 2
    Start-Sleep -Milliseconds 20
    & $addOutboxItemFn -Kind 'event' -EventId $evictEventId2 -OccurredAtUtc (Get-Date).ToUniversalTime().ToString('o') `
        -SchemaVersion 1 -ApiPath '/api/v1/events' -RequestBody @{ category = 'health'; severity = 'SUCCESS' } -MaxOutboxItems 2
    Start-Sleep -Milliseconds 20
    # Третій item переповнює ліміт (MaxOutboxItems=2, уже 2 на диску) ->
    # найстаріший (evictEventId1) має бути витіснений у DeadLetter\ ПЕРЕД
    # записом цього item.
    & $addOutboxItemFn -Kind 'event' -EventId $evictEventId3 -OccurredAtUtc (Get-Date).ToUniversalTime().ToString('o') `
        -SchemaVersion 1 -ApiPath '/api/v1/events' -RequestBody @{ category = 'health'; severity = 'SUCCESS' } -MaxOutboxItems 2

    $evictOutboxDirFn = & $opsSelfTestModule { ${function:Get-BRAVOOperationsOutboxDirectory} }
    $evictDeadLetterDirFn = & $opsSelfTestModule { ${function:Get-BRAVOOperationsOutboxDeadLetterDirectory} }
    $evictOutboxDir = & $evictOutboxDirFn
    $evictDeadLetterDir = & $evictDeadLetterDirFn
    $evictOutboxItems = @(Get-ChildItem -LiteralPath $evictOutboxDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $evictDeadLetterItems = @(Get-ChildItem -LiteralPath $evictDeadLetterDir -Filter '*.json' -File -ErrorAction SilentlyContinue)

    Test-BRAVOCondition -Condition ($evictOutboxItems.Count -eq 2 -and $evictDeadLetterItems.Count -eq 1) `
        -Name 'Operations/OutboxEvictsOldestWhenMaxOutboxItemsExceeded' `
        -Failure "3-й item з -MaxOutboxItems 2 має витіснити 1 найстаріший item у DeadLetter\, лишивши рівно 2 в Outbox\; отримано outbox=$($evictOutboxItems.Count) deadLetter=$($evictDeadLetterItems.Count)"
    Test-BRAVOCondition -Condition (
        -not (Test-Path -LiteralPath (Join-Path $evictOutboxDir "$evictEventId1.json") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $evictDeadLetterDir "$evictEventId1.json") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $evictOutboxDir "$evictEventId2.json") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $evictOutboxDir "$evictEventId3.json") -PathType Leaf)
    ) -Name 'Operations/OutboxEvictionPicksOldestByEnqueuedAtUtcNotNewest' `
      -Failure "витіснений item має бути САМЕ найстаріший ($evictEventId1, FIFO/EnqueuedAtUtc) -- новіші items ($evictEventId2/$evictEventId3) мають лишитись в активному Outbox\"

    # ---------------------------------------------------------------------
    # #280 (рішення власника): події, витіснені переповненням outbox, після
    # enrollment одноразово повертаються з DeadLetter у дренаж; відхилені
    # бекендом (4xx) і чужої ідентичності лишаються в DeadLetter. Події,
    # остаточно видалені ретенцією DeadLetter чи пошкоджені, рахуються в
    # лічильнику втрачених подій.
    # ---------------------------------------------------------------------
    $evictDeadLetterItem = $null
    $evictDeadLetterPath = Join-Path $evictDeadLetterDir "$evictEventId1.json"
    if (Test-Path -LiteralPath $evictDeadLetterPath -PathType Leaf) {
        $evictDeadLetterItem = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($evictDeadLetterPath))
    }
    Test-BRAVOCondition -Condition (
        $null -ne $evictDeadLetterItem -and
        $null -ne $evictDeadLetterItem.PSObject.Properties['DeadLetterKind'] -and
        [string]$evictDeadLetterItem.DeadLetterKind -eq 'Overflow'
    ) -Name 'Operations/OverflowEvictionMarksDeadLetterKindOverflow' `
      -Failure '#280: item, витіснений переповненням, має нести DeadLetterKind=Overflow (лише такі повертаються в дренаж)'

    $redrainDir = Join-Path $opsSelfTestRoot 'OverflowRedrain'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $redrainDir
    $redrainServerId = Get-BRAVOOperationsServerId
    $redrainDeadLetterDir = & $evictDeadLetterDirFn
    $redrainOutboxDir = & $evictOutboxDirFn
    New-Item -ItemType Directory -Path $redrainDeadLetterDir -Force | Out-Null
    function New-BRAVOOpsSelfTestDeadLetterFile {
        param([string]$EventId, [string]$ServerId, [string]$Reason, [string]$Kind)
        $payload = [ordered]@{
            Kind = 'event'; ServerId = $ServerId; EventId = $EventId
            OccurredAtUtc = (Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o')
            SchemaVersion = 1; ApiPath = '/api/v1/events'
            RequestBody = @{ category = 'health'; severity = 'SUCCESS' }
            EnqueuedAtUtc = (Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o')
            AttemptCount = 0
            NextRetryAtUtc = (Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o')
            LastError = $null
            DeadLetteredAtUtc = (Get-Date).ToUniversalTime().AddMinutes(-20).ToString('o')
            DeadLetterReason = $Reason
        }
        if (-not [string]::IsNullOrWhiteSpace($Kind)) { $payload['DeadLetterKind'] = $Kind }
        [IO.File]::WriteAllText((Join-Path $redrainDeadLetterDir "$EventId.json"), (([pscustomobject]$payload) | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    }
    $redrainOverflowId = 'redrain-overflow-' + [guid]::NewGuid().ToString()
    $redrainLegacyId = 'redrain-legacy-' + [guid]::NewGuid().ToString()
    $redrainRejectedId = 'redrain-rejected-' + [guid]::NewGuid().ToString()
    $redrainForeignId = 'redrain-foreign-' + [guid]::NewGuid().ToString()
    New-BRAVOOpsSelfTestDeadLetterFile -EventId $redrainOverflowId -ServerId $redrainServerId -Reason 'Outbox переповнено (ліміт 500 items) — найстаріший item витіснено' -Kind 'Overflow'
    New-BRAVOOpsSelfTestDeadLetterFile -EventId $redrainLegacyId -ServerId $redrainServerId -Reason 'Outbox переповнено (ліміт 500 items) — найстаріший item витіснено' -Kind ''
    New-BRAVOOpsSelfTestDeadLetterFile -EventId $redrainRejectedId -ServerId $redrainServerId -Reason 'HTTP 400 при дренажі: Bad Request' -Kind 'Rejected'
    New-BRAVOOpsSelfTestDeadLetterFile -EventId $redrainForeignId -ServerId ([guid]::NewGuid().ToString()) -Reason 'Outbox переповнено (ліміт 500 items) — найстаріший item витіснено' -Kind 'Overflow'

    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'accepted' }
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'accepted' }
    $redrainThrew = $null
    try {
        [void](Invoke-BRAVOOperationsOutboxDrain -ApiBaseUrl $opsSettings.ApiBaseUrl -ApiKey 'redrain-api-key' `
            -CredentialTargets $opsCredentialTargets -TimeoutSeconds 5)
    } catch {
        $redrainThrew = $_.Exception.Message
    }
    # List[object]: лише .Count напряму; обгортка масивом кидає ArgumentException у PS 5.1.
    $redrainHttpCallCount = $global:BRAVOOpsSelfTestHttpCalls.Count
    $redrainDeadLetterNames = New-Object 'System.Collections.Generic.List[string]'
    foreach ($redrainFile in @(Get-ChildItem -LiteralPath $redrainDeadLetterDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $redrainDeadLetterNames.Add([IO.Path]::GetFileNameWithoutExtension($redrainFile.Name))
    }
    $redrainOutboxCount = @(Get-ChildItem -LiteralPath $redrainOutboxDir -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    Test-BRAVOCondition -Condition (
        $null -eq $redrainThrew -and
        $redrainHttpCallCount -eq 2 -and
        -not $redrainDeadLetterNames.Contains($redrainOverflowId) -and
        -not $redrainDeadLetterNames.Contains($redrainLegacyId) -and
        $redrainOutboxCount -eq 0
    ) -Name 'Operations/DeadLetterOverflowRedrainedOnceAfterEnrollment' `
      -Failure "#280: витіснені переповненням події (з DeadLetterKind=Overflow і старі з причиною 'Outbox переповнено') мають повернутися з DeadLetter і бути доставлені першим дренажем після enrollment; HTTP-викликів=$redrainHttpCallCount (очікувано 2), у DeadLetter: $($redrainDeadLetterNames -join ', '), в outbox=$redrainOutboxCount, виняток=$redrainThrew"
    Test-BRAVOCondition -Condition (
        $redrainDeadLetterNames.Contains($redrainRejectedId) -and
        $redrainDeadLetterNames.Contains($redrainForeignId)
    ) -Name 'Operations/DeadLetterRedrainSkipsRejectedAndForeignIdentity' `
      -Failure "#280: подія, відхилена бекендом (4xx), і подія іншої серверної ідентичності мають лишитися в DeadLetter; у DeadLetter: $($redrainDeadLetterNames -join ', ')"

    $redrainSecondId = 'redrain-second-' + [guid]::NewGuid().ToString()
    New-BRAVOOpsSelfTestDeadLetterFile -EventId $redrainSecondId -ServerId $redrainServerId -Reason 'Outbox переповнено (ліміт 500 items) — найстаріший item витіснено' -Kind 'Overflow'
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'accepted' }
    try {
        [void](Invoke-BRAVOOperationsOutboxDrain -ApiBaseUrl $opsSettings.ApiBaseUrl -ApiKey 'redrain-api-key' `
            -CredentialTargets $opsCredentialTargets -TimeoutSeconds 5)
    } catch {
        $redrainThrew = $_.Exception.Message
    }
    Test-BRAVOCondition -Condition (
        $null -eq $redrainThrew -and
        $global:BRAVOOpsSelfTestHttpCalls.Count -eq 0 -and
        (Test-Path -LiteralPath (Join-Path $redrainDeadLetterDir "$redrainSecondId.json") -PathType Leaf)
    ) -Name 'Operations/DeadLetterRedrainRunsOncePerServerIdentity' `
      -Failure "#280: повернення з DeadLetter одноразове для серверної ідентичності — повторний дренаж не має знову забирати витіснені події; HTTP-викликів=$($global:BRAVOOpsSelfTestHttpCalls.Count)"

    # Повний outbox (типовий випадок переповнення): повернення не має місця,
    # тож позначка «виконано» не ставиться; щойно місце звільняється,
    # наступний виклик повертає подію і ставить позначку.
    $redrainFullDir = Join-Path $opsSelfTestRoot 'OverflowRedrainFullOutbox'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $redrainFullDir
    $redrainServerId = Get-BRAVOOperationsServerId
    $redrainDeadLetterDir = & $evictDeadLetterDirFn
    $redrainFullOutboxDir = & $evictOutboxDirFn
    New-Item -ItemType Directory -Path $redrainDeadLetterDir -Force | Out-Null
    $redrainFullBlockerId = 'redrain-full-blocker-' + [guid]::NewGuid().ToString()
    & $addOutboxItemFn -Kind 'event' -EventId $redrainFullBlockerId -OccurredAtUtc (Get-Date).ToUniversalTime().ToString('o') `
        -SchemaVersion 1 -ApiPath '/api/v1/events' -RequestBody @{ category = 'health'; severity = 'SUCCESS' } -MaxOutboxItems 1
    $redrainFullId = 'redrain-full-' + [guid]::NewGuid().ToString()
    New-BRAVOOpsSelfTestDeadLetterFile -EventId $redrainFullId -ServerId $redrainServerId -Reason 'Outbox переповнено (ліміт 1 items) — найстаріший item витіснено' -Kind 'Overflow'
    $redrainFn = & $opsSelfTestModule { ${function:Invoke-BRAVOOperationsOverflowDeadLetterRedrain} }
    $redrainStatePath = Join-Path $redrainFullDir 'BRAVO_OPERATIONS_OUTBOX_REDRAIN.json'
    $redrainFullFirstMarker = $null
    $redrainFullFirstInDeadLetter = $null
    if ($null -ne $redrainFn) {
        & $redrainFn -MaxOutboxItems 1
        $redrainFullFirstMarker = Test-Path -LiteralPath $redrainStatePath -PathType Leaf
        $redrainFullFirstInDeadLetter = Test-Path -LiteralPath (Join-Path $redrainDeadLetterDir "$redrainFullId.json") -PathType Leaf
        Remove-Item -LiteralPath (Join-Path $redrainFullOutboxDir "$redrainFullBlockerId.json") -Force
        & $redrainFn -MaxOutboxItems 1
    }
    Test-BRAVOCondition -Condition (
        $null -ne $redrainFn -and
        $redrainFullFirstMarker -eq $false -and
        $redrainFullFirstInDeadLetter -eq $true -and
        (Test-Path -LiteralPath (Join-Path $redrainFullOutboxDir "$redrainFullId.json") -PathType Leaf) -and
        -not (Test-Path -LiteralPath (Join-Path $redrainDeadLetterDir "$redrainFullId.json") -PathType Leaf) -and
        (Test-Path -LiteralPath $redrainStatePath -PathType Leaf)
    ) -Name 'Operations/DeadLetterRedrainWaitsForFreeOutboxSlots' `
      -Failure "#280: коли outbox повний, витіснена подія лишається в DeadLetter без позначки «виконано» і повертається, щойно звільняється місце; перший виклик: позначка=$redrainFullFirstMarker, у DeadLetter=$redrainFullFirstInDeadLetter"
    Remove-Item -Path function:New-BRAVOOpsSelfTestDeadLetterFile -Force -ErrorAction SilentlyContinue

    # Лічильник втрачених подій: ретенція DeadLetter (200 найновіших)
    # видаляє файл -> +1; пошкоджений outbox-файл видаляється -> +1.
    $lossDir = Join-Path $opsSelfTestRoot 'OutboxLossCounter'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $lossDir
    $lossDeadLetterDir = & $evictDeadLetterDirFn
    $lossOutboxDir = & $evictOutboxDirFn
    New-Item -ItemType Directory -Path $lossDeadLetterDir -Force | Out-Null
    $lossOldTime = (Get-Date).AddDays(-2)
    for ($lossIndex = 0; $lossIndex -lt 200; $lossIndex++) {
        $lossFile = Join-Path $lossDeadLetterDir ("old-dead-letter-{0:D3}.json" -f $lossIndex)
        [IO.File]::WriteAllText($lossFile, '{"EventId":"old","DeadLetterReason":"HTTP 400"}', (New-Object Text.UTF8Encoding($false)))
        [IO.File]::SetLastWriteTimeUtc($lossFile, $lossOldTime.ToUniversalTime().AddSeconds($lossIndex))
    }
    & $addOutboxItemFn -Kind 'event' -EventId ('loss-first-' + [guid]::NewGuid().ToString()) -OccurredAtUtc (Get-Date).ToUniversalTime().ToString('o') `
        -SchemaVersion 1 -ApiPath '/api/v1/events' -RequestBody @{ category = 'health'; severity = 'SUCCESS' } -MaxOutboxItems 1
    Start-Sleep -Milliseconds 20
    & $addOutboxItemFn -Kind 'event' -EventId ('loss-second-' + [guid]::NewGuid().ToString()) -OccurredAtUtc (Get-Date).ToUniversalTime().ToString('o') `
        -SchemaVersion 1 -ApiPath '/api/v1/events' -RequestBody @{ category = 'health'; severity = 'SUCCESS' } -MaxOutboxItems 1
    $lossSummaryCommand = Get-Command -Name 'Get-BRAVOOperationsOutboxLossSummary' -ErrorAction SilentlyContinue
    $lossAfterRetention = $null
    if ($null -ne $lossSummaryCommand) { $lossAfterRetention = Get-BRAVOOperationsOutboxLossSummary }
    Test-BRAVOCondition -Condition (
        $null -ne $lossAfterRetention -and [int]$lossAfterRetention.LostEventCount -eq 1 -and
        @(Get-ChildItem -LiteralPath $lossDeadLetterDir -Filter '*.json' -File).Count -eq 200
    ) -Name 'Operations/DeadLetterRetentionCountsLostEvents' `
      -Failure "#280: файл, видалений ретенцією DeadLetter, має збільшити лічильник втрачених подій (Get-BRAVOOperationsOutboxLossSummary.LostEventCount=1); факт: $(if ($null -eq $lossSummaryCommand) { 'функцію не експортовано' } elseif ($null -eq $lossAfterRetention) { 'результату немає' } else { $lossAfterRetention.LostEventCount })"

    [IO.File]::WriteAllText((Join-Path $lossOutboxDir 'corrupt-item.json'), '{ not json', (New-Object Text.UTF8Encoding($false)))
    $lossOutboxItemsFn = & $opsSelfTestModule { ${function:Get-BRAVOOperationsOutboxItems} }
    [void](& $lossOutboxItemsFn)
    $lossAfterCorrupt = $null
    if ($null -ne $lossSummaryCommand) { $lossAfterCorrupt = Get-BRAVOOperationsOutboxLossSummary }
    Test-BRAVOCondition -Condition (
        $null -ne $lossAfterCorrupt -and [int]$lossAfterCorrupt.LostEventCount -eq 2 -and
        -not [string]::IsNullOrWhiteSpace([string]$lossAfterCorrupt.LastLostAtUtc)
    ) -Name 'Operations/CorruptOutboxItemCountsAsLostEvent' `
      -Failure "#280: пошкоджений outbox-файл, який видаляється, теж має рахуватися втраченою подією (LostEventCount=2, LastLostAtUtc заповнено); факт: $(if ($null -eq $lossAfterCorrupt) { 'результату немає' } else { $lossAfterCorrupt.LostEventCount })"

    # ---------------------------------------------------------------------
    # Thread 5 (review): event loss during pending enrollment -- подія,
    # надіслана поки enrollment ще pending/не сконфігуровано (apiKey
    # порожній, apiKey ще НЕ намагались отримати мережею в цьому сценарії,
    # bootstrap-секрет просто відсутній у Credential Manager), раніше
    # губилась НАЗАВЖДИ (лише лог, без outbox). Тепер вона потрапляє в
    # ТОЙ САМИЙ durable outbox, що обслуговує transient HTTP-збої.
    # ---------------------------------------------------------------------
    $pendingLossDir = Join-Path $opsSelfTestRoot 'PendingEnrollmentEventLoss'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $pendingLossDir
    # Порожній credential store -- жодного bootstrap-секрету -> Invoke-
    # BRAVOOperationsEnrollment повертає $null ОДРАЗУ (WARNING-лог), БЕЗ
    # жодної спроби мережевого виклику -- саме тому черга замокованих HTTP-
    # відповідей нижче лишається порожньою: будь-який несподіваний HTTP-
    # виклик кинув би виняток і тест впав би на -not $pendingLossThrew.
    $global:BRAVOOpsSelfTestCredentialStore = @{}
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    $pendingLossThrew = $false
    try {
        Send-BRAVOOperationsEvent -OperationsReportingSettings $opsSettings -CredentialTargets $opsCredentialTargets `
            -InstitutionCode 'INST1' -Category 'health' -Severity 'WARNING' -Component 'Health' `
            -Message 'pending enrollment event loss regression test'
    } catch {
        $pendingLossThrew = $true
    }

    $pendingLossOutboxItems = @(Get-ChildItem -LiteralPath (Join-Path $pendingLossDir 'Outbox') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition (-not $pendingLossThrew -and $global:BRAVOOpsSelfTestHttpCalls.Count -eq 0) `
        -Name 'Operations/EventDuringPendingEnrollmentNeverThrowsNoNetworkAttempt' `
        -Failure "подія під час pending enrollment (без bootstrap-секрету) має повернутись без винятку і БЕЗ жодної мережевої спроби; threw=$pendingLossThrew httpCalls=$($global:BRAVOOpsSelfTestHttpCalls.Count)"
    Test-BRAVOCondition -Condition ($pendingLossOutboxItems.Count -eq 1) `
        -Name 'Operations/EventDuringPendingEnrollmentIsBufferedToOutboxNotDropped' `
        -Failure "подія, надіслана поки enrollment pending, раніше губилась НАЗАВЖДИ (review finding) -- тепер має бути буферизована в durable Outbox\; знайдено $($pendingLossOutboxItems.Count) файлів (очікувано 1)"

    if ($pendingLossOutboxItems.Count -eq 1) {
        $pendingLossItemRaw = ([IO.File]::ReadAllText($pendingLossOutboxItems[0].FullName, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
        Test-BRAVOCondition -Condition (
            $pendingLossItemRaw.RequestBody.category -eq 'health' -and
            $pendingLossItemRaw.RequestBody.severity -eq 'WARNING' -and
            $pendingLossItemRaw.RequestBody.payload.message -eq 'pending enrollment event loss regression test' -and
            $pendingLossItemRaw.RequestBody.payload.component -eq 'Health' -and
            $pendingLossItemRaw.AttemptCount -eq 0
        ) -Name 'Operations/EventDuringPendingEnrollmentOutboxItemCarriesOriginalPayload' `
          -Failure "буферизований item має нести ОРИГІНАЛЬНІ category/severity/message/component цієї події, з AttemptCount=0 (без штучного стартового затримання); отримано $($pendingLossItemRaw | ConvertTo-Json -Compress -Depth 6)"
    }

    # ---------------------------------------------------------------------
    # Review PR #225: heartbeat під час недоступного enrollment. Шлях подій
    # уже буферизувався (тест вище), а heartbeat під ТОЮ САМОЮ умовою просто
    # зникав разом зі своїм eventId/occurredAt -- контракт durability
    # виконувався лише наполовину. Та сама асиметрія була і в межах самої
    # Send-BRAVOOperationsHeartbeat: на 'transient' від дренажу heartbeat у
    # outbox ставився, а на відсутній ключ -- ні.
    # ---------------------------------------------------------------------
    $heartbeatPendingDir = Join-Path $opsSelfTestRoot 'PendingEnrollmentHeartbeatLoss'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $heartbeatPendingDir
    $global:BRAVOOpsSelfTestCredentialStore = @{}
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    $heartbeatPendingThrew = $false
    try {
        Send-BRAVOOperationsHeartbeat -OperationsReportingSettings $opsSettings `
            -CredentialTargets $opsCredentialTargets -InstitutionCode 'INST1' -BravoVersion '5.3.0-test'
    } catch {
        $heartbeatPendingThrew = $true
    }

    $heartbeatPendingItems = @(Get-ChildItem -LiteralPath (Join-Path $heartbeatPendingDir 'Outbox') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Test-BRAVOCondition -Condition (-not $heartbeatPendingThrew -and $global:BRAVOOpsSelfTestHttpCalls.Count -eq 0 -and $heartbeatPendingItems.Count -eq 1) `
        -Name 'Operations/HeartbeatDuringPendingEnrollmentIsBufferedToOutboxNotDropped' `
        -Failure "heartbeat під час pending enrollment має буферизуватись у durable Outbox (як подія), без винятку і без мережевої спроби; threw=$heartbeatPendingThrew httpCalls=$($global:BRAVOOpsSelfTestHttpCalls.Count) items=$($heartbeatPendingItems.Count)"

    if ($heartbeatPendingItems.Count -eq 1) {
        $heartbeatPendingRaw = ([IO.File]::ReadAllText($heartbeatPendingItems[0].FullName, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
        Test-BRAVOCondition -Condition (
            [string]$heartbeatPendingRaw.Kind -eq 'heartbeat' -and
            [string]$heartbeatPendingRaw.ApiPath -eq '/api/v1/heartbeat' -and
            [string]$heartbeatPendingRaw.RequestBody.bravoVersion -eq '5.3.0-test' -and
            [string]$heartbeatPendingRaw.RequestBody.eventId -eq [string]$heartbeatPendingRaw.EventId -and
            [string]$heartbeatPendingRaw.RequestBody.occurredAt -eq [string]$heartbeatPendingRaw.OccurredAtUtc -and
            [int]$heartbeatPendingRaw.AttemptCount -eq 0
        ) -Name 'Operations/BufferedHeartbeatKeepsOriginalEnvelopeAndVersion' `
          -Failure "буферизований heartbeat має нести ОРИГІНАЛЬНІ eventId/occurredAt цього heartbeat (E4/E7, а не час майбутнього дренажу), bravoVersion і AttemptCount=0; отримано $($heartbeatPendingRaw | ConvertTo-Json -Compress -Depth 6)"
    }

    # ---------------------------------------------------------------------
    # Review PR #225 (P1): Operations -- ДРУГОРЯДНИЙ канал звітності. Його
    # WARNING-и не сміють важити в спільному лічильнику попереджень, бо
    # BRAVO_ARCHIV резолвить будь-яке попередження прогону в exit code 10
    # (SuccessWithWarnings, статус ЧАСТКОВО): недоступність телеметрії
    # змінювала рапортований результат УСПІШНОГО бекапу.
    #
    # Перевірка СТРУКТУРНА: інваріант мусить триматись на вигляді коду, а
    # не на дисциплінованості кожного майбутнього call-site. Модуль має
    # РІВНО одну згадку Write-BRAVOLog у виконуваному коді -- усередині
    # Write-BRAVOOperationsLog, і саме з -Secondary.
    # ---------------------------------------------------------------------
    $opsModuleText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Operations\BRAVO.Operations.psm1'), [Text.Encoding]::UTF8)
    $opsModuleCodeLines = @(
        @($opsModuleText -split "`r?`n") |
            Where-Object { $_ -notmatch '^\s*#' }
    )
    $opsDirectLogLines = @(@($opsModuleCodeLines) | Where-Object { $_ -match 'Write-BRAVOLog\b' })
    $opsWrapperCallLines = @(@($opsModuleCodeLines) | Where-Object { $_ -match 'Write-BRAVOOperationsLog\b' })
    Test-BRAVOCondition -Condition (
        $opsDirectLogLines.Count -eq 1 -and
        $opsDirectLogLines[0] -match "-Component\s+'Operations'" -and
        $opsDirectLogLines[0] -match '-Secondary' -and
        $opsWrapperCallLines.Count -ge 30
    ) -Name 'Operations/ModuleLogsOnlyThroughSecondaryWrapper' `
      -Failure ("уся діагностика BRAVO.Operations мусить іти через Write-BRAVOOperationsLog (який додає -Secondary), інакше збій вторинної телеметрії " +
        "знову підніматиме лічильник попереджень і даватиме успішному бекапу exit code 10; прямих Write-BRAVOLog рядків=$($opsDirectLogLines.Count) " +
        "(очікувано рівно 1 -- усередині обгортки, з -Secondary), викликів обгортки=$($opsWrapperCallLines.Count)")

    # ---------------------------------------------------------------
    # Прибирання: зняти всі self-test overrides з function:-drive (той
    # самий клас cleanup, що Clear-BRAVOSelfTestOwnedRuntimeModules робить
    # централізовано для New-BRAVOSelfTestRuntimeModule-виходів; тут -- ручні
    # global-scope shadow-функції, знімаємо явно, щоб не протікати в
    # наступні suite-фрагменти).
    # ---------------------------------------------------------------
    Remove-Item -Path function:Invoke-WebRequest -Force -ErrorAction SilentlyContinue
    Remove-Item -Path function:Get-BRAVOCredentialSecret -Force -ErrorAction SilentlyContinue
    Remove-Item -Path function:Set-BRAVOCredential -Force -ErrorAction SilentlyContinue
    Remove-Item -Path function:Remove-BRAVOCredential -Force -ErrorAction SilentlyContinue
    Remove-Item -Path function:Set-BRAVOOpsSelfTestStateDirectory -Force -ErrorAction SilentlyContinue
    Remove-Item -Path function:New-BRAVOOpsSelfTestFakeHttpError -Force -ErrorAction SilentlyContinue
    Remove-Item -Path function:Enqueue-BRAVOOpsSelfTestHttpSuccess -Force -ErrorAction SilentlyContinue
    Remove-Item -Path function:Enqueue-BRAVOOpsSelfTestHttpError -Force -ErrorAction SilentlyContinue
    Remove-Item -Path function:Enqueue-BRAVOOpsSelfTestHttpNetworkError -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name BRAVOOpsSelfTestCredentialStore -Scope Global -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name BRAVOOpsSelfTestHttpQueue -Scope Global -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name BRAVOOpsSelfTestHttpCalls -Scope Global -Force -ErrorAction SilentlyContinue
    [Environment]::SetEnvironmentVariable('BRAVO_OPERATIONS_TEST_STATE_DIR', $null)
    Remove-Module -Name 'BRAVO.Operations' -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $opsSelfTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    } catch { Register-BRAVOSelfTestSectionFault -ErrorRecord $_ } finally { Complete-BRAVOSelfTestSection -Name 'Operations/EnabledWithEmptyApiBaseUrlFailsClosedReturnsNull' } }
