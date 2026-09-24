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
    # ENROLLMENT: header-only bootstrap secret (POST-тіло БЕЗ
    # bootstrapSecret), claimToken persisted + переданий у GET як
    # X-Enrollment-Claim, TTL-expired (approved БЕЗ apiKey) не падає в
    # нескінченний тісний цикл (повертає $null, не кидає).
    # =====================================================================
    $enrollDir = Join-Path $opsSelfTestRoot 'Enroll'
    Set-BRAVOOpsSelfTestStateDirectory -Directory $enrollDir
    $global:BRAVOOpsSelfTestCredentialStore = @{ 'OpsSelfTestBootstrap' = 'fleet-bootstrap-secret' }
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    $global:BRAVOOpsSelfTestHttpCalls.Clear()
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'pending'; claimToken = 'claim_abc123' }
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
        $getEnrollCall.Headers['X-Enrollment-Claim'] -eq 'claim_abc123' -and
        $getEnrollCall.Headers['X-Bootstrap-Secret'] -eq 'fleet-bootstrap-secret'
    ) -Name 'Operations/GetEnrollPollSendsClaimTokenFromPostResponse' `
      -Failure 'GET /enroll/:id має нести X-Enrollment-Claim, отриманий з попереднього POST /enroll (claimToken), плюс X-Bootstrap-Secret'

    # 404 на poll (D7: невідрізнюваний "не готово"/revoked/wrong-claim) не
    # кидає і не губить локальний pending-стан (claim лишається на диску).
    $global:BRAVOOpsSelfTestHttpQueue.Clear()
    Enqueue-BRAVOOpsSelfTestHttpSuccess -ContentObject @{ status = 'pending'; claimToken = 'claim_xyz789' }
    Enqueue-BRAVOOpsSelfTestHttpError -StatusCode 404 -BodyObject @{ error = 'not_found' }
    $enroll404Result = $null
    $enroll404Threw = $false
    try {
        $enroll404Result = Invoke-BRAVOOperationsEnrollment -OperationsReportingSettings $opsSettings `
            -CredentialTargets $opsCredentialTargets -InstitutionCode 'INST1'
    } catch {
        $enroll404Threw = $true
    }
    Test-BRAVOCondition -Condition (-not $enroll404Threw -and $null -eq $enroll404Result) `
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
