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
    # E11: 401 на надсиланні -> локальний API-ключ видаляється, подія НЕ
    # потрапляє в нескінченний outbox-retry (запис не з'являється в Outbox\).
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
    Test-BRAVOCondition -Condition ($e11OutboxItems.Count -eq 0) `
        -Name 'Operations/HttpUnauthorizedDoesNotEnqueueOutboxRetry' `
        -Failure "401 НЕ повинен ставити подію в outbox для нескінченного марного retry тим самим невалідним ключем; знайдено $($e11OutboxItems.Count) файлів"

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
            param([string]$Component, [string]$Level, [string]$Message)
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
