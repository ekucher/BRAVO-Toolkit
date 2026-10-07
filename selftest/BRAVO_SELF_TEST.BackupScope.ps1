# ============================================================
# BackupScope: резервне копіювання лише наявних компонентів
# ============================================================
# Рішення власника 2026-10-01 (опис дизайну - у CHANGELOG, запис про
# бекап лише наявних компонентів):
# прапорець компонента означає «копіювати, якщо компонент є на сервері».
# Канонічна класифікація — Resolve-BRAVOBackupComponentScope
# (modules\BRAVO.Discovery) поверх матриці Test-BRAVODiscoveryComponentDrift.
# Тут перевіряється реальний модуль на синтетичних presence-результатах;
# BRAVO_ARCHIV, BRAVO_HEALTH, BRAVO_SETUP і BRAVO_DRY_RUN — статично, бо їхні runtime-и
# потребують Windows-служб, VSS і Credential Manager.

Import-Module -Name (Join-Path $root 'modules\BRAVO.Discovery\BRAVO.Discovery.psd1') -Force -ErrorAction Stop

function New-BRAVOSelfTestScopePresence {
    param([string]$Component, [string]$Presence, [string]$Path)
    return [pscustomobject]@{
        Component = $Component
        Presence = $Presence
        Source = $(if ($Presence -eq 'Present') { 'BravoIni' } else { 'None' })
        Path = $(if ($Presence -eq 'Present') { $Path } else { $null })
        Reason = "синтетичний стан $Presence"
    }
}

function New-BRAVOSelfTestScopeDiscovery {
    # Синтетичний результат discovery з presence-контрактом. Шляхи —
    # вигадані, на диск не звертаються.
    param([hashtable]$Presence)
    $paths = @{
        MODEL = 'C:\ExampleLims\Model'
        BLOG = 'C:\ExampleLims\BLOG'
        BRAVOEXCH = 'C:\ExampleLims\bravoexch'
        BAZA_APP = 'C:\ExampleLims\BAZA'
        BAZA_WWW = 'C:\ExampleWeb\www\BAZA'
    }
    $fields = @{ MODEL = 'MODEL_SOURCE'; BLOG = 'BLOG_SOURCE'; BRAVOEXCH = 'BRAVOEXCH_SOURCE'; BAZA_APP = 'BAZA_APP'; BAZA_WWW = 'BAZA_WWW' }
    $result = [ordered]@{
        BRAVO_ROOT = 'C:\ExampleLims'
        WEB_ROOT = 'C:\ExampleWeb'
        BACKUP_ROOT = 'C:\ExampleLims\ARCHIV'
    }
    $components = @{}
    foreach ($name in $paths.Keys) {
        $state = [string]$Presence[$name]
        $result[$fields[$name]] = $(if ($state -eq 'Present') { $paths[$name] } else { '' })
        $components[$name] = New-BRAVOSelfTestScopePresence -Component $name -Presence $state -Path $paths[$name]
    }
    $result['Components'] = $components
    return [pscustomobject]$result
}

$scopeAllEnabled = @{ MODEL = $true; BLOG = $true; BRAVOEXCH = $true; BAZA_APP = $true; BAZA_WWW = $true }
$scopeVetOfficePresence = @{ MODEL = 'Present'; BLOG = 'Present'; BRAVOEXCH = 'Absent'; BAZA_APP = 'Absent'; BAZA_WWW = 'Present' }

# (1) Продукт без BRAVOEXCH і BAZA_APP: увімкнені за замовчуванням, але не
# встановлені компоненти пропускаються без помилки.
$scopeVetOffice = Resolve-BRAVOBackupComponentScope `
    -DiscoveryResult (New-BRAVOSelfTestScopeDiscovery -Presence $scopeVetOfficePresence) `
    -EnabledComponents $scopeAllEnabled
Test-BRAVOCondition -Condition (
    [string]$scopeVetOffice.Components['MODEL'] -eq 'Planned' -and
    [string]$scopeVetOffice.Components['BLOG'] -eq 'Planned' -and
    [string]$scopeVetOffice.Components['BAZA_WWW'] -eq 'Planned' -and
    [string]$scopeVetOffice.Components['BRAVOEXCH'] -eq 'NotInstalled' -and
    [string]$scopeVetOffice.Components['BAZA_APP'] -eq 'NotInstalled' -and
    @($scopeVetOffice.Findings | Where-Object { [string]$_.Severity -eq 'Error' }).Count -eq 0 -and
    -not [bool]$scopeVetOffice.EmptyComposition -and
    -not [bool]$scopeVetOffice.EffectiveEnabledComponents['BRAVOEXCH'] -and
    -not [bool]$scopeVetOffice.EffectiveEnabledComponents['BAZA_APP'] -and
    [bool]$scopeVetOffice.EffectiveEnabledComponents['MODEL']
) -Name 'BackupScope/NotInstalledComponentsSkippedWithoutError' `
    -Failure 'увімкнений, але не встановлений компонент без запису в baseline має бути NotInstalled (Info), а не помилкою прогону'

# (2) Компонент, підтверджений у baseline, зник -> Missing (Error), як і до
# цієї зміни. Інваріант #158 не послаблено.
$scopeBlogVanished = Resolve-BRAVOBackupComponentScope `
    -DiscoveryResult (New-BRAVOSelfTestScopeDiscovery -Presence @{ MODEL = 'Present'; BLOG = 'Absent'; BRAVOEXCH = 'Absent'; BAZA_APP = 'Absent'; BAZA_WWW = 'Present' }) `
    -Baseline ([pscustomobject]@{ MODEL_SOURCE = 'C:\ExampleLims\Model'; BLOG_SOURCE = 'C:\ExampleLims\BLOG' }) `
    -BaselineSourceKind 'Canonical' `
    -EnabledComponents $scopeAllEnabled
Test-BRAVOCondition -Condition (
    [string]$scopeBlogVanished.Components['BLOG'] -eq 'Missing' -and
    @($scopeBlogVanished.Findings | Where-Object { [string]$_.Severity -eq 'Error' -and [string]$_.Component -eq 'BLOG' }).Count -eq 1 -and
    @($scopeBlogVanished.NotInstalled) -notcontains 'BLOG'
) -Name 'BackupScope/BaselineConfirmedComponentVanishedIsError' `
    -Failure 'компонент, підтверджений у baseline, який зник, має лишатись помилкою (Missing), а не тихим NotInstalled'

# (2b) Сервер без baseline, але BLOG мав архів в останній COMPLETE generation
# і тепер Absent: другий доказ присутності -> Missing (Error), а не
# NotInstalled. Без цього доказу той самий стан лишається NotInstalled.
$scopeBlogAbsentPresence = @{ MODEL = 'Present'; BLOG = 'Absent'; BRAVOEXCH = 'Absent'; BAZA_APP = 'Absent'; BAZA_WWW = 'Present' }
$scopePreviousBlog = Resolve-BRAVOBackupComponentScope `
    -DiscoveryResult (New-BRAVOSelfTestScopeDiscovery -Presence $scopeBlogAbsentPresence) `
    -EnabledComponents $scopeAllEnabled `
    -PreviousCompleteComponents @('MODEL', 'BLOG')
$scopeNoPreviousBlog = Resolve-BRAVOBackupComponentScope `
    -DiscoveryResult (New-BRAVOSelfTestScopeDiscovery -Presence $scopeBlogAbsentPresence) `
    -EnabledComponents $scopeAllEnabled `
    -PreviousCompleteComponents @('MODEL')
Test-BRAVOCondition -Condition (
    [string]$scopePreviousBlog.Components['BLOG'] -eq 'Missing' -and
    @($scopePreviousBlog.Findings | Where-Object { [string]$_.Severity -eq 'Error' -and [string]$_.Component -eq 'BLOG' }).Count -eq 1 -and
    @($scopePreviousBlog.NotInstalled) -notcontains 'BLOG' -and
    [bool]$scopePreviousBlog.EffectiveEnabledComponents['BLOG'] -and
    [string]$scopePreviousBlog.Components['BRAVOEXCH'] -eq 'NotInstalled' -and
    [string]$scopeNoPreviousBlog.Components['BLOG'] -eq 'NotInstalled'
) -Name 'BackupScope/PreviouslyBackedUpComponentVanishedWithoutBaselineIsError' `
    -Failure 'без baseline компонент, що мав архів в останній COMPLETE generation і зник, має бути Missing (Error), а не NotInstalled'

# (2c) P2-1 (безпека даних): оголошене, але недоступне джерело ніколи не
# стає NotInstalled. Структурна перевірка відрізняє «не існує/порожньо» від
# «не вдалося прочитати», а presence оголошеного шляху без підтвердження —
# Error (не Absent), тому компонент лишається в складі й падає гучно.
$scopeDirRoot = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_SELFTEST_SCOPE_DIR_' + [guid]::NewGuid().ToString('N'))
try {
    $scopeDirFull = Join-Path $scopeDirRoot 'full'
    $scopeDirEmpty = Join-Path $scopeDirRoot 'empty'
    $scopeDirMissing = Join-Path $scopeDirRoot 'missing'
    [void](New-Item -ItemType Directory -Path $scopeDirFull -Force)
    [void](New-Item -ItemType Directory -Path $scopeDirEmpty -Force)
    [IO.File]::WriteAllText((Join-Path $scopeDirFull 'data.txt'), 'x')
    $scopeKindFull = Test-BRAVODiscoverySourceDirectory -Path $scopeDirFull
    $scopeKindEmpty = Test-BRAVODiscoverySourceDirectory -Path $scopeDirEmpty
    $scopeKindMissing = Test-BRAVODiscoverySourceDirectory -Path $scopeDirMissing
    Test-BRAVOCondition -Condition (
        $scopeKindFull.Valid -and [string]$scopeKindFull.Kind -eq 'Ok' -and
        -not $scopeKindEmpty.Valid -and [string]$scopeKindEmpty.Kind -eq 'Empty' -and
        -not $scopeKindMissing.Valid -and [string]$scopeKindMissing.Kind -eq 'NotFound'
    ) -Name 'BackupScope/SourceDirectoryDistinguishesMissingFromUnreadable' `
        -Failure 'Test-BRAVODiscoverySourceDirectory має повертати Kind: Ok / Empty / NotFound (а Unreadable/Reparse - для нечитабельного)'

    $scopeDiscoveryModule = Get-Module -Name 'BRAVO.Discovery'
    # Нечитабельний каталог (відмова в доступі) імітується підміною
    # Get-Item/Get-ChildItem у scope модуля: від root Linux справжню
    # відмову не відтворити. Це той самий код-шлях catch у production.
    $scopeUnreadableGetItem = & $scopeDiscoveryModule {
        param($p)
        function Get-Item { throw (New-Object System.UnauthorizedAccessException 'Access denied (synthetic)') }
        Test-BRAVODiscoverySourceDirectory -Path $p
    } $scopeDirFull
    $scopeUnreadableList = & $scopeDiscoveryModule {
        param($p)
        function Get-ChildItem { throw (New-Object System.UnauthorizedAccessException 'Access denied (synthetic)') }
        Test-BRAVODiscoverySourceDirectory -Path $p
    } $scopeDirFull
    $scopeDeclaredUnreadable = & $scopeDiscoveryModule {
        param($p)
        function Get-Item { throw (New-Object System.UnauthorizedAccessException 'Access denied (synthetic)') }
        Resolve-BRAVODiscoveryPathComponentPresence -Component 'BLOG' -Path $p -Source 'BravoIni' -Reason 'bravo.ini'
    } $scopeDirFull
    $scopeDeclaredMissing = & $scopeDiscoveryModule {
        param($p)
        Resolve-BRAVODiscoveryPathComponentPresence -Component 'BLOG' -Path $p -Source 'BravoIni' -Reason 'bravo.ini'
    } $scopeDirMissing
    $scopeDeclaredPresent = & $scopeDiscoveryModule {
        param($p)
        Resolve-BRAVODiscoveryPathComponentPresence -Component 'BLOG' -Path $p -Source 'BravoIni' -Reason 'bravo.ini'
    } $scopeDirFull
    Test-BRAVOCondition -Condition (
        -not $scopeUnreadableGetItem.Valid -and [string]$scopeUnreadableGetItem.Kind -eq 'Unreadable' -and
        -not $scopeUnreadableList.Valid -and [string]$scopeUnreadableList.Kind -eq 'Unreadable' -and
        [string]$scopeDeclaredUnreadable.Presence -eq 'Error' -and
        [string]$scopeDeclaredMissing.Presence -eq 'Absent' -and
        [string]$scopeDeclaredPresent.Presence -eq 'Present'
    ) -Name 'BackupScope/DeclaredButUnreadableSourceIsErrorNotAbsent' `
        -Failure 'оголошений шлях, який не вдалося прочитати (доступ/помилка), має давати Kind Unreadable і presence Error; лише достовірно відсутній - Absent'
} finally {
    if (Test-Path -LiteralPath $scopeDirRoot) {
        Remove-Item -LiteralPath $scopeDirRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$scopeDeclaredDiscovery = New-BRAVOSelfTestScopeDiscovery -Presence $scopeBlogAbsentPresence
$scopeDeclaredDiscovery.Components['BLOG'] = [pscustomobject]@{
    Component = 'BLOG'; Presence = 'Absent'; Source = 'BravoIni'; Path = $null
    Reason = 'шлях з bravo.ini недоступний (синтетично)'
}
$scopeDeclaredAbsent = Resolve-BRAVOBackupComponentScope `
    -DiscoveryResult $scopeDeclaredDiscovery `
    -EnabledComponents $scopeAllEnabled
Test-BRAVOCondition -Condition (
    [string]$scopeDeclaredAbsent.Components['BLOG'] -eq 'Missing' -and
    @($scopeDeclaredAbsent.NotInstalled) -notcontains 'BLOG' -and
    [bool]$scopeDeclaredAbsent.EffectiveEnabledComponents['BLOG'] -and
    @($scopeDeclaredAbsent.Findings | Where-Object { [string]$_.Severity -eq 'Error' -and [string]$_.Component -eq 'BLOG' }).Count -eq 1 -and
    [string]$scopeDeclaredAbsent.Components['BRAVOEXCH'] -eq 'NotInstalled'
) -Name 'BackupScope/DeclaredSourceAbsentWithoutBaselineIsNeverNotInstalled' `
    -Failure 'Absent з оголошеним джерелом (BravoIni/ServiceDiscovery/ExplicitOverride) без baseline не може стати NotInstalled: компонент має лишитись у складі як Missing (Error)'

# (2d) P3: доказ з попереднього COMPLETE manifest діє й коли baseline є, але
# старіший за цей manifest і не містить компонента. Новіший baseline
# (оператор підтвердив зникнення) доказ скасовує, тож deadlock немає.
$scopeOldBaseline = [pscustomobject]@{ SavedAt = '2026-01-01T00:00:00.0000000Z'; MODEL_SOURCE = 'C:\ExampleLims\Model' }
$scopeNewBaseline = [pscustomobject]@{ SavedAt = '2026-03-01T00:00:00.0000000Z'; MODEL_SOURCE = 'C:\ExampleLims\Model' }
$scopeManifestAt = [datetime]::Parse('2026-02-01T00:00:00Z').ToUniversalTime()
$scopeStaleBaselineRun = Resolve-BRAVOBackupComponentScope `
    -DiscoveryResult (New-BRAVOSelfTestScopeDiscovery -Presence $scopeBlogAbsentPresence) `
    -Baseline $scopeOldBaseline -BaselineSourceKind 'Canonical' `
    -EnabledComponents $scopeAllEnabled `
    -PreviousCompleteComponents @('MODEL', 'BLOG') -PreviousCompleteAt $scopeManifestAt
$scopeFreshBaselineRun = Resolve-BRAVOBackupComponentScope `
    -DiscoveryResult (New-BRAVOSelfTestScopeDiscovery -Presence $scopeBlogAbsentPresence) `
    -Baseline $scopeNewBaseline -BaselineSourceKind 'Canonical' `
    -EnabledComponents $scopeAllEnabled `
    -PreviousCompleteComponents @('MODEL', 'BLOG') -PreviousCompleteAt $scopeManifestAt
$scopeNoTimeRun = Resolve-BRAVOBackupComponentScope `
    -DiscoveryResult (New-BRAVOSelfTestScopeDiscovery -Presence $scopeBlogAbsentPresence) `
    -Baseline $scopeOldBaseline -BaselineSourceKind 'Canonical' `
    -EnabledComponents $scopeAllEnabled `
    -PreviousCompleteComponents @('MODEL', 'BLOG')
Test-BRAVOCondition -Condition (
    [string]$scopeStaleBaselineRun.Components['BLOG'] -eq 'Missing' -and
    [string]$scopeFreshBaselineRun.Components['BLOG'] -eq 'NotInstalled' -and
    [string]$scopeNoTimeRun.Components['BLOG'] -eq 'NotInstalled'
) -Name 'BackupScope/PreviousManifestEvidenceCoversBaselineThatPredatesComponent' `
    -Failure 'компонент з архівом у COMPLETE manifest, який новіший за baseline без цього компонента, має бути Missing; новіший baseline або відсутність часу manifest - NotInstalled'

# Той самий читач, що годує Resolve: останній COMPLETE manifest у MANIFESTS\.
$scopeManifestRoot = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_SELFTEST_SCOPE_BACKUP_' + [guid]::NewGuid().ToString('N'))
try {
    $scopeManifestDir = Join-Path $scopeManifestRoot 'MANIFESTS'
    [void](New-Item -ItemType Directory -Path $scopeManifestDir -Force)
    $scopeUtf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $scopeManifestDir 'BRAVO_BACKUP_20260101_020000.json'), (@{
        generationId = '20260101_020000'; status = 'COMPLETE'; createdAt = '2026-01-01T02:00:00Z'
        components = @{ MODEL = @{ CreateSuccess = $true; ArchivePath = 'C:\ExampleLims\ARCHIV\MODEL\m.7z' } }
    } | ConvertTo-Json -Depth 5), $scopeUtf8)
    [IO.File]::WriteAllText((Join-Path $scopeManifestDir 'BRAVO_BACKUP_20260102_020000.json'), (@{
        generationId = '20260102_020000'; status = 'COMPLETE'; createdAt = '2026-01-02T02:00:00Z'
        components = @{
            MODEL = @{ CreateSuccess = $true; ArchivePath = 'C:\ExampleLims\ARCHIV\MODEL\m2.7z' }
            BLOG = @{ CreateSuccess = $true; ArchivePath = 'C:\ExampleLims\ARCHIV\BLOG\b2.7z' }
            BRAVOEXCH = @{ CreateSuccess = $false; ArchivePath = '' }
        }
    } | ConvertTo-Json -Depth 5), $scopeUtf8)
    [IO.File]::WriteAllText((Join-Path $scopeManifestDir 'BRAVO_BACKUP_20260103_020000.json'), (@{
        generationId = '20260103_020000'; status = 'INCOMPLETE'; createdAt = '2026-01-03T02:00:00Z'
        components = @{ BAZA_APP = @{ CreateSuccess = $true; ArchivePath = 'C:\x.7z' } }
    } | ConvertTo-Json -Depth 5), $scopeUtf8)
    $scopeLastNames = @(Get-BRAVOLastCompleteBackupComponents -BackupRoot $scopeManifestRoot)
    $scopeLastEvidence = Get-BRAVOLastCompleteBackupEvidence -BackupRoot $scopeManifestRoot
    Test-BRAVOCondition -Condition (
        $null -ne $scopeLastEvidence.CreatedAtUtc -and
        ([datetime]$scopeLastEvidence.CreatedAtUtc).ToUniversalTime().Date -eq [datetime]::Parse('2026-01-02').Date -and
        @($scopeLastEvidence.Components).Count -eq 2 -and
        $null -eq (Get-BRAVOLastCompleteBackupEvidence -BackupRoot (Join-Path $scopeManifestRoot 'немає')).CreatedAtUtc
    ) -Name 'BackupScope/LastCompleteEvidenceCarriesManifestTime' `
        -Failure 'Get-BRAVOLastCompleteBackupEvidence має повертати час найновішого COMPLETE manifest разом з компонентами'
    # null-компонент у COMPLETE manifest (StrictMode, BRAVO_SETUP -ValidateOnly кличе без try/catch).
    $scopeNullRoot = Join-Path $scopeManifestRoot 'NULLCOMP'
    $scopeNullDir = Join-Path $scopeNullRoot 'MANIFESTS'
    [void](New-Item -ItemType Directory -Path $scopeNullDir -Force)
    [IO.File]::WriteAllText((Join-Path $scopeNullDir 'BRAVO_BACKUP_20260104_020000.json'),
        '{"generationId":"20260104_020000","status":"COMPLETE","createdAt":"2026-01-04T02:00:00Z","components":{"MODEL":null,"BLOG":{"CreateSuccess":true,"ArchivePath":"C:\\ExampleLims\\ARCHIV\\BLOG\\b4.7z"}}}', $scopeUtf8)
    $scopeNullEvidence = $null
    $scopeNullError = $null
    try {
        $scopeNullEvidence = & { Set-StrictMode -Version 2.0; Get-BRAVOLastCompleteBackupEvidence -BackupRoot $scopeNullRoot }
    } catch {
        $scopeNullError = $_.Exception.Message
    }
    Test-BRAVOCondition -Condition (
        $null -eq $scopeNullError -and $null -ne $scopeNullEvidence -and
        @($scopeNullEvidence.Components).Count -eq 1 -and @($scopeNullEvidence.Components)[0] -eq 'BLOG'
    ) -Name 'BackupScope/LastCompleteEvidenceSkipsNullComponent' `
        -Failure "null-компонент у COMPLETE manifest пропускається без винятку, решта компонентів зберігається: $scopeNullError"
    Test-BRAVOCondition -Condition (
        $scopeLastNames.Count -eq 2 -and
        $scopeLastNames -contains 'MODEL' -and
        $scopeLastNames -contains 'BLOG' -and
        @(Get-BRAVOLastCompleteBackupComponents -BackupRoot (Join-Path $scopeManifestRoot 'немає')).Count -eq 0
    ) -Name 'BackupScope/LastCompleteManifestComponentsReader' `
        -Failure 'Get-BRAVOLastCompleteBackupComponents має брати найновіший COMPLETE manifest (не INCOMPLETE) і лише компоненти з архівом'
} finally {
    if (Test-Path -LiteralPath $scopeManifestRoot) {
        Remove-Item -LiteralPath $scopeManifestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# (3) MODEL обов'язковий: його відсутність — помилка навіть без baseline.
$scopeModelAbsent = Resolve-BRAVOBackupComponentScope `
    -DiscoveryResult (New-BRAVOSelfTestScopeDiscovery -Presence @{ MODEL = 'Absent'; BLOG = 'Present'; BRAVOEXCH = 'Absent'; BAZA_APP = 'Absent'; BAZA_WWW = 'Absent' }) `
    -EnabledComponents $scopeAllEnabled
Test-BRAVOCondition -Condition (
    [string]$scopeModelAbsent.Components['MODEL'] -eq 'Missing' -and
    @($scopeModelAbsent.Findings | Where-Object { [string]$_.Severity -eq 'Error' -and [string]$_.Component -eq 'MODEL' }).Count -eq 1 -and
    @($scopeModelAbsent.NotInstalled) -notcontains 'MODEL'
) -Name 'BackupScope/MandatoryModelAbsentIsErrorWithoutBaseline' `
    -Failure "увімкнений MODEL, якого немає на сервері, має бути помилкою навіть без baseline"

# (4) «Не вдалося визначити» не дорівнює «немає».
$scopeAmbiguous = Resolve-BRAVOBackupComponentScope `
    -DiscoveryResult (New-BRAVOSelfTestScopeDiscovery -Presence @{ MODEL = 'Present'; BLOG = 'Error'; BRAVOEXCH = 'Ambiguous'; BAZA_APP = 'Absent'; BAZA_WWW = 'Absent' }) `
    -EnabledComponents $scopeAllEnabled
Test-BRAVOCondition -Condition (
    [string]$scopeAmbiguous.Components['BLOG'] -eq 'Unknown' -and
    [string]$scopeAmbiguous.Components['BRAVOEXCH'] -eq 'Unknown' -and
    @($scopeAmbiguous.NotInstalled) -notcontains 'BLOG' -and
    @($scopeAmbiguous.NotInstalled) -notcontains 'BRAVOEXCH'
) -Name 'BackupScope/AmbiguousOrErrorPresenceIsNeverNotInstalled' `
    -Failure "presence Ambiguous/Error має бути Unknown (помилка), а не NotInstalled"

# (5) Вимкнений у конфігурації компонент не блокує прогін навіть у стані Error.
$scopeDisabled = Resolve-BRAVOBackupComponentScope `
    -DiscoveryResult (New-BRAVOSelfTestScopeDiscovery -Presence @{ MODEL = 'Present'; BLOG = 'Present'; BRAVOEXCH = 'Error'; BAZA_APP = 'Absent'; BAZA_WWW = 'Absent' }) `
    -EnabledComponents @{ MODEL = $true; BLOG = $true; BRAVOEXCH = $false; BAZA_APP = $false; BAZA_WWW = $false }
Test-BRAVOCondition -Condition (
    [string]$scopeDisabled.Components['BRAVOEXCH'] -eq 'DisabledByConfig' -and
    @($scopeDisabled.Findings | Where-Object { [string]$_.Severity -eq 'Error' }).Count -eq 0
) -Name 'BackupScope/DisabledByConfigNeverBlocks' `
    -Failure 'вимкнений у конфігурації компонент не має блокувати прогін'

# (6) Порожній склад: усе увімкнене не встановлено -> помилка, а не «успіх
# без жодного архіву».
$scopeEmpty = Resolve-BRAVOBackupComponentScope `
    -DiscoveryResult (New-BRAVOSelfTestScopeDiscovery -Presence @{ MODEL = 'Present'; BLOG = 'Absent'; BRAVOEXCH = 'Absent'; BAZA_APP = 'Absent'; BAZA_WWW = 'Absent' }) `
    -EnabledComponents @{ MODEL = $false; BLOG = $true; BRAVOEXCH = $true; BAZA_APP = $false; BAZA_WWW = $false }
Test-BRAVOCondition -Condition (
    [bool]$scopeEmpty.EmptyComposition -and
    @($scopeEmpty.Findings | Where-Object { [string]$_.Severity -eq 'Error' -and [string]$_.Component -eq 'BASELINE' }).Count -eq 1
) -Name 'BackupScope/EmptyCompositionIsGlobalError' `
    -Failure 'коли жоден увімкнений компонент не встановлено, має бути глобальна помилка складу (Component=BASELINE)'

# (7) Автоматичне створення й доповнення baseline.
$scopeStateRoot = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_SELFTEST_SCOPE_STATE_' + [guid]::NewGuid().ToString('N'))
$scopeRuntimeRoot = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_SELFTEST_SCOPE_RUNTIME_' + [guid]::NewGuid().ToString('N'))
try {
    $scopeVetOfficeDiscovery = New-BRAVOSelfTestScopeDiscovery -Presence $scopeVetOfficePresence
    # Read-only варіант для Health і Dry Run: той самий склад, але жодного
    # запису в State, навіть коли baseline ще немає.
    $scopeReadOnly = Get-BRAVOBackupNotInstalledComponents `
        -DiscoveryResult $scopeVetOfficeDiscovery -EnabledComponents $scopeAllEnabled `
        -StateRoot $scopeStateRoot -RuntimeRoot $scopeRuntimeRoot
    Test-BRAVOCondition -Condition (
        [string]::IsNullOrWhiteSpace([string]$scopeReadOnly.Error) -and
        @($scopeReadOnly.NotInstalled) -contains 'BRAVOEXCH' -and
        @($scopeReadOnly.NotInstalled) -contains 'BAZA_APP' -and
        @($scopeReadOnly.NotInstalled).Count -eq 2 -and
        -not (Test-Path -LiteralPath (Get-BRAVODiscoveryBaselinePath -StateRoot $scopeStateRoot))
    ) -Name 'BackupScope/ReadOnlyScopeWritesNothing' `
        -Failure 'Get-BRAVOBackupNotInstalledComponents має повертати той самий склад без жодного запису baseline'

    # Другий доказ присутності: останній COMPLETE manifest, де BLOG був у
    # складі. Тепер BLOG відсутній на сервері й baseline немає, але
    # компонент уже потрапляв у резервну копію, тож він не NotInstalled
    # (Health і Dry Run мають очікувати його й підняти тривогу).
    $scopeEvidenceBackupRoot = Join-Path $scopeStateRoot 'EvidenceBackupRoot'
    $scopeEvidenceManifestDir = Join-Path $scopeEvidenceBackupRoot 'MANIFESTS'
    [void](New-Item -ItemType Directory -Path $scopeEvidenceManifestDir -Force)
    [IO.File]::WriteAllText(
        (Join-Path $scopeEvidenceManifestDir 'BRAVO_BACKUP_20260102_020000.json'),
        (@{
            generationId = '20260102_020000'; status = 'COMPLETE'; createdAt = '2026-01-02T02:00:00Z'
            components = @{
                MODEL = @{ CreateSuccess = $true; ArchivePath = 'C:\ExampleLims\ARCHIV\MODEL\m.7z' }
                BLOG = @{ CreateSuccess = $true; ArchivePath = 'C:\ExampleLims\ARCHIV\BLOG\b.7z' }
            }
        } | ConvertTo-Json -Depth 5),
        (New-Object Text.UTF8Encoding($false)))
    $scopeBlogGoneDiscovery = New-BRAVOSelfTestScopeDiscovery -Presence @{ MODEL = 'Present'; BLOG = 'Absent'; BRAVOEXCH = 'Absent'; BAZA_APP = 'Absent'; BAZA_WWW = 'Present' }
    $scopeNoEvidence = Get-BRAVOBackupNotInstalledComponents `
        -DiscoveryResult $scopeBlogGoneDiscovery -EnabledComponents $scopeAllEnabled `
        -StateRoot $scopeStateRoot -RuntimeRoot $scopeRuntimeRoot
    $scopeWithEvidence = Get-BRAVOBackupNotInstalledComponents `
        -DiscoveryResult $scopeBlogGoneDiscovery -EnabledComponents $scopeAllEnabled `
        -StateRoot $scopeStateRoot -RuntimeRoot $scopeRuntimeRoot `
        -BackupRoot $scopeEvidenceBackupRoot
    Test-BRAVOCondition -Condition (
        @($scopeNoEvidence.NotInstalled) -contains 'BLOG' -and
        @($scopeWithEvidence.NotInstalled) -notcontains 'BLOG' -and
        @($scopeWithEvidence.NotInstalled) -contains 'BRAVOEXCH'
    ) -Name 'BackupScope/ReadOnlyScopeUsesPreviousCompleteManifestEvidence' `
        -Failure 'Get-BRAVOBackupNotInstalledComponents має брати останній COMPLETE manifest другим доказом: компонент, що вже був у копії, не стає NotInstalled'

    # Непридатний baseline: невизначеність дає порожній список (очікуємо всі
    # увімкнені), а не тихе «не встановлено».
    $scopeUnreadableStateRoot = Join-Path $scopeStateRoot 'UnreadableState'
    [void](New-Item -ItemType Directory -Path $scopeUnreadableStateRoot -Force)
    $scopeUnreadableBaselinePath = Get-BRAVODiscoveryBaselinePath -StateRoot $scopeUnreadableStateRoot
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $scopeUnreadableBaselinePath) -Force)
    [IO.File]::WriteAllText($scopeUnreadableBaselinePath, '{ не JSON', (New-Object Text.UTF8Encoding($false)))
    $scopeUnreadableReadOnly = Get-BRAVOBackupNotInstalledComponents `
        -DiscoveryResult $scopeVetOfficeDiscovery -EnabledComponents $scopeAllEnabled `
        -StateRoot $scopeUnreadableStateRoot -RuntimeRoot $scopeRuntimeRoot
    Test-BRAVOCondition -Condition (
        @($scopeUnreadableReadOnly.NotInstalled).Count -eq 0 -and
        [IO.File]::ReadAllText($scopeUnreadableBaselinePath) -eq '{ не JSON'
    ) -Name 'BackupScope/ReadOnlyScopeUnreadableBaselineFailsSafe' `
        -Failure 'за непридатного baseline Get-BRAVOBackupNotInstalledComponents має повертати порожній список (очікуються всі увімкнені) і нічого не перезаписувати'
    $scopeCreated = Update-BRAVODiscoveryBaselineFromScope `
        -DiscoveryResult $scopeVetOfficeDiscovery -ScopeResult $scopeVetOffice `
        -StateRoot $scopeStateRoot -RuntimeRoot $scopeRuntimeRoot
    $scopeBaselinePath = Get-BRAVODiscoveryBaselinePath -StateRoot $scopeStateRoot
    $scopeCreatedBaseline = (Get-Content -LiteralPath $scopeBaselinePath -Raw -Encoding UTF8) | ConvertFrom-Json
    Test-BRAVOCondition -Condition (
        [string]$scopeCreated.Action -eq 'Created' -and
        [string]$scopeCreatedBaseline.MODEL_SOURCE -eq 'C:\ExampleLims\Model' -and
        [string]::IsNullOrWhiteSpace([string]$scopeCreatedBaseline.BRAVOEXCH_SOURCE)
    ) -Name 'BackupScope/BaselineCreatedAfterFirstCompleteGeneration' `
        -Failure 'за відсутності baseline він має створюватись із фактичного складу; не встановлений компонент лишається порожнім'

    # Оператор раніше підтвердив інший шлях MODEL, а BAZA_WWW ще не був
    # під захистом: доповнюється лише порожнє поле, наявне не змінюється.
    $scopeExistingBaseline = [ordered]@{
        SavedAt = '2026-01-01T00:00:00.0000000+00:00'
        MODEL_SOURCE = 'C:\ExampleLims\ModelConfirmed'
        BLOG_SOURCE = 'C:\ExampleLims\BLOG'
        BAZA_WWW = ''
    }
    [IO.File]::WriteAllText($scopeBaselinePath, ([pscustomobject]$scopeExistingBaseline | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    $scopeExtended = Update-BRAVODiscoveryBaselineFromScope `
        -DiscoveryResult $scopeVetOfficeDiscovery -ScopeResult $scopeVetOffice `
        -StateRoot $scopeStateRoot -RuntimeRoot $scopeRuntimeRoot
    $scopeExtendedBaseline = (Get-Content -LiteralPath $scopeBaselinePath -Raw -Encoding UTF8) | ConvertFrom-Json
    $scopeUnchanged = Update-BRAVODiscoveryBaselineFromScope `
        -DiscoveryResult $scopeVetOfficeDiscovery -ScopeResult $scopeVetOffice `
        -StateRoot $scopeStateRoot -RuntimeRoot $scopeRuntimeRoot
    Test-BRAVOCondition -Condition (
        [string]$scopeExtended.Action -eq 'Extended' -and
        @($scopeExtended.AddedComponents) -contains 'BAZA_WWW' -and
        @($scopeExtended.AddedComponents) -notcontains 'MODEL' -and
        [string]$scopeExtendedBaseline.MODEL_SOURCE -eq 'C:\ExampleLims\ModelConfirmed' -and
        [string]$scopeExtendedBaseline.BAZA_WWW -eq 'C:\ExampleWeb\www\BAZA' -and
        [IO.File]::ReadAllText($scopeBaselinePath).Contains('2026-01-01T00:00:00') -and
        [string]$scopeUnchanged.Action -eq 'Unchanged'
    ) -Name 'BackupScope/BaselineExtendedOnlyForEmptyFields' `
        -Failure 'автоматичне доповнення має дописувати лише порожні поля Planned-компонентів і ніколи не змінювати наявні значення'

    # Перше створення baseline: DisabledByConfig-компонент (тут BAZA_WWW
    # вимкнено, хоч він є на сервері) не потрапляє в baseline.
    Remove-Item -LiteralPath $scopeBaselinePath -Force
    $scopeWwwDisabled = Resolve-BRAVOBackupComponentScope `
        -DiscoveryResult $scopeVetOfficeDiscovery `
        -EnabledComponents @{ MODEL = $true; BLOG = $true; BRAVOEXCH = $true; BAZA_APP = $true; BAZA_WWW = $false }
    $scopeCreatedPlannedOnly = Update-BRAVODiscoveryBaselineFromScope `
        -DiscoveryResult $scopeVetOfficeDiscovery -ScopeResult $scopeWwwDisabled `
        -StateRoot $scopeStateRoot -RuntimeRoot $scopeRuntimeRoot
    $scopePlannedOnlyBaseline = (Get-Content -LiteralPath $scopeBaselinePath -Raw -Encoding UTF8) | ConvertFrom-Json
    Test-BRAVOCondition -Condition (
        [string]$scopeWwwDisabled.Components['BAZA_WWW'] -eq 'DisabledByConfig' -and
        [string]$scopeCreatedPlannedOnly.Action -eq 'Created' -and
        @($scopeCreatedPlannedOnly.AddedComponents) -notcontains 'BAZA_WWW' -and
        [string]$scopePlannedOnlyBaseline.MODEL_SOURCE -eq 'C:\ExampleLims\Model' -and
        [string]$scopePlannedOnlyBaseline.BLOG_SOURCE -eq 'C:\ExampleLims\BLOG' -and
        [string]::IsNullOrWhiteSpace([string]$scopePlannedOnlyBaseline.BAZA_WWW)
    ) -Name 'BackupScope/FirstBaselineExcludesDisabledByConfig' `
        -Failure 'перший baseline має містити лише Planned-компоненти: вимкнений у конфігурації компонент не береться під захист'

    [IO.File]::WriteAllText($scopeBaselinePath, '{ не JSON', (New-Object Text.UTF8Encoding($false)))
    $scopeUnreadable = Update-BRAVODiscoveryBaselineFromScope `
        -DiscoveryResult $scopeVetOfficeDiscovery -ScopeResult $scopeVetOffice `
        -StateRoot $scopeStateRoot -RuntimeRoot $scopeRuntimeRoot
    Test-BRAVOCondition -Condition (
        [string]$scopeUnreadable.Action -eq 'Skipped' -and
        [IO.File]::ReadAllText($scopeBaselinePath) -eq '{ не JSON'
    ) -Name 'BackupScope/UnreadableBaselineNeverOverwritten' `
        -Failure 'непридатний baseline не має перезаписуватись автоматично (fail-closed)'
} finally {
    foreach ($scopeTempRoot in @($scopeStateRoot, $scopeRuntimeRoot)) {
        if (Test-Path -LiteralPath $scopeTempRoot) {
            Remove-Item -LiteralPath $scopeTempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# (8) #282: перевірка discovery не створює каталогів і не перевіряє
# призначення вимкнених компонентів.
$scopeDestinationRoot = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_SELFTEST_SCOPE_DEST_' + [guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path $scopeDestinationRoot -Force)
    $scopeSourceDirectory = Join-Path $scopeDestinationRoot 'source'
    [void](New-Item -ItemType Directory -Path $scopeSourceDirectory -Force)
    $scopeValidationDiscovery = [pscustomobject]@{
        MODEL_SOURCE = $scopeSourceDirectory
        BLOG_SOURCE = $null
        BRAVOEXCH_SOURCE = $null
        BAZA_APP = $null
        BAZA_WWW = $null
    }
    $scopeModelDestination = Join-Path $scopeDestinationRoot 'ARCHIV\MODEL'
    $scopeBlogDestination = Join-Path $scopeDestinationRoot 'ARCHIV\BLOG'
    $scopeValidationErrors = @(Test-BRAVODiscoveryResult `
        -DiscoveryResult $scopeValidationDiscovery `
        -EnabledComponents @{ MODEL = $true; BLOG = $false } `
        -DestinationPaths @{ MODEL = $scopeModelDestination; BLOG = $scopeBlogDestination })
    Test-BRAVOCondition -Condition (
        $scopeValidationErrors.Count -eq 0 -and
        -not (Test-Path -LiteralPath $scopeModelDestination) -and
        -not (Test-Path -LiteralPath $scopeBlogDestination) -and
        -not (Test-Path -LiteralPath (Join-Path $scopeDestinationRoot 'ARCHIV'))
    ) -Name 'BackupScope/DiscoveryValidationCreatesNoDirectories' `
        -Failure '#282: Test-BRAVODiscoveryResult не має створювати каталоги призначення, зокрема для вимкнених компонентів'
} finally {
    if (Test-Path -LiteralPath $scopeDestinationRoot) {
        Remove-Item -LiteralPath $scopeDestinationRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# (9) Підключення: ARCHIV, Health і SETUP користуються одним канонічним
# складом, а не власними копіями фільтра.
$scopeArchiveText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1'), [Text.Encoding]::UTF8)
$scopeHealthText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Health\BRAVO.Health.Runtime.ps1'), [Text.Encoding]::UTF8)
$scopeSetupText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_SETUP.ps1'), [Text.Encoding]::UTF8)
$scopeArchiveResolveIndex = $scopeArchiveText.IndexOf('$backupScope = Resolve-BRAVOBackupComponentScope')
$scopeArchiveSyncBazaIndex = $scopeArchiveText.IndexOf('if ($SyncBAZA) {', [Math]::Max(0, $scopeArchiveResolveIndex))
Test-BRAVOCondition -Condition (
    $scopeArchiveResolveIndex -ge 0 -and
    $scopeArchiveSyncBazaIndex -gt $scopeArchiveResolveIndex -and
    $scopeArchiveText.Contains('$enabledArchives = @(Select-BRAVOExpectedArchiveDefinition') -and
    $scopeArchiveText.Contains("Test-BRAVOBackupComponentInstalled -Component 'BAZA_APP'") -and
    $scopeArchiveText.Contains('if (Test-BRAVOBackupBaselineUpdateAllowed') -and
    $scopeArchiveText.Contains('$discoveryDriftFindings = @($backupScope.Findings)') -and
    $scopeArchiveText.Contains('-ComponentScope $(if ($null -ne $backupScope) { $backupScope.Components } else { $null })') -and
    $scopeArchiveText.Contains("`$manifest['componentScope'] = `$componentScopeProperty.Value") -and
    $scopeArchiveText.Contains('$baselineUpdate = Update-BRAVODiscoveryBaselineFromScope')
) -Name 'BackupScope/ArchiveUsesCanonicalScopeWired' `
    -Failure 'BRAVO_ARCHIV має обчислювати склад до гілки -SyncBAZA, фільтрувати NotInstalled, писати componentScope у manifest і доповнювати baseline лише через канонічні функції'
Test-BRAVOCondition -Condition (
    $scopeHealthText.Contains('function Get-BRAVOHealthExpectedArchiveDefinitions') -and
    $scopeHealthText.Contains('$healthComponentScope = Get-BRAVOBackupNotInstalledComponents') -and
    $scopeHealthText.Contains('Select-BRAVOExpectedArchiveDefinition') -and
    -not $scopeHealthText.Contains('@($archiveDefinitions | Where-Object { $_.Enabled })')
) -Name 'BackupScope/HealthExpectsOnlyInstalledComponentsWired' `
    -Failure 'Health має очікувати лише встановлені компоненти через Get-BRAVOHealthExpectedArchiveDefinitions і read-only Get-BRAVOBackupNotInstalledComponents'
Test-BRAVOCondition -Condition (
    $scopeArchiveText.Contains('Test-SFTPConfig -NotInstalledComponents $notInstalledComponents') -and
    $scopeArchiveText.Contains('Test-SFTPConfig -SynchronizationOnly -NotInstalledComponents $manualNotInstalled') -and
    $scopeArchiveText.Contains('$_.Enabled -and @($NotInstalledComponents) -notcontains [string]$_.Type') -and
    $scopeArchiveText.Contains('Get-BRAVOLastCompleteBackupEvidence -BackupRoot $backupRootPath') -and
    $scopeArchiveText.Contains('-PreviousCompleteAt $previousCompleteEvidence.CreatedAtUtc') -and
    $scopeHealthText.Contains('-BackupRoot $backupRootPath')
) -Name 'BackupScope/SftpConfigSkipsNotInstalledAndPreviousProofWired' `
    -Failure 'Test-SFTPConfig не має вимагати SFTP-каталоги NotInstalled-компонентів; Archive і Health мають передавати останній COMPLETE manifest як другий доказ'
$scopeDryRunText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_DRY_RUN.ps1'), [Text.Encoding]::UTF8)
Test-BRAVOCondition -Condition (
    $scopeDryRunText.Contains('$dryRunComponentScope = Get-BRAVOBackupNotInstalledComponents') -and
    $scopeDryRunText.Contains('$dryRunArchiveDefinitions = @(Select-BRAVOExpectedArchiveDefinition') -and
    $scopeDryRunText.Contains('-NotInstalledComponents $dryRunNotInstalledComponents)') -and
    $scopeDryRunText.Contains('foreach ($definition in $dryRunArchiveDefinitions)') -and
    -not $scopeDryRunText.Contains('@($archiveDefinitions | Where-Object { Test-SettingEnabled $_.Enabled })')
) -Name 'BackupScope/DryRunChecksOnlyInstalledComponentsWired' `
    -Failure 'Dry Run має перевіряти джерела й призначення лише встановлених компонентів через Get-BRAVOBackupNotInstalledComponents'
Test-BRAVOCondition -Condition (
    $scopeSetupText.Contains('$discoveryScope = Resolve-BRAVOBackupComponentScope') -and
    $scopeSetupText.Contains('$discoveryDestinationPaths = Get-BRAVODiscoveryDestinationPaths') -and
    $scopeSetupText.Contains('-EnabledComponents $discoveryScope.EffectiveEnabledComponents')
) -Name 'BackupScope/SetupValidatesEffectiveCompositionWired' `
    -Failure 'BRAVO_SETUP -ValidateOnly має перевіряти склад через Resolve-BRAVOBackupComponentScope'
Test-BRAVOCondition -Condition (
    $scopeSetupText.Contains('Get-BRAVOLastCompleteBackupEvidence') -and
    $scopeSetupText.Contains('-PreviousCompleteComponents @($discoveryPreviousEvidence.Components)') -and
    $scopeSetupText.Contains('-PreviousCompleteAt $discoveryPreviousEvidence.CreatedAtUtc')
) -Name 'BackupScope/SetupPassesPreviousCompleteEvidenceLikeArchive' `
    -Failure 'BRAVO_SETUP має передавати той самий другий доказ (останній COMPLETE manifest), що й BRAVO_ARCHIV, щоб SETUP і нічний прогін погоджувались'

# (10) P2-2: підсумок ARCHIV (status JSON, секція "Архіви", план, лог) рахує
# і друкує лише реальний склад $enabledArchives, а не NotInstalled-компоненти.
$scopeResultStart = $scopeArchiveText.IndexOf("Write-BRAVOResultSection -Title 'Архіви'")
$scopeResultBlock = $(if ($scopeResultStart -ge 0) { $scopeArchiveText.Substring([Math]::Max(0, $scopeResultStart - 120), 700) } else { '' })
Test-BRAVOCondition -Condition (
    $scopeResultStart -ge 0 -and
    $scopeResultBlock.Contains('if ($enabledArchives.Count -gt 0)') -and
    $scopeResultBlock.Contains('foreach ($definition in $enabledArchives)') -and
    -not $scopeResultBlock.Contains('foreach ($definition in $archiveDefinitions)') -and
    $scopeArchiveText.Contains('$statusComponentsTotal = @($enabledArchives).Count') -and
    -not $scopeArchiveText.Contains('$statusComponentsTotal = @($archiveDefinitions') -and
    $scopeArchiveText.Contains('$notInstalledComponents -notcontains [string]$archiveDefinition.Type') -and
    $scopeArchiveText.Contains("'НЕ ВСТАНОВЛЕНО (пропущено)'")
) -Name 'BackupScope/ArchiveSummaryCountsOnlyInstalledComponentsWired' `
    -Failure 'status JSON componentsTotal, секція "Архіви", план і лог мають використовувати $enabledArchives: NotInstalled не рахується і не друкується як "Архів не створено"'

# (11) Поведінкові перевірки фільтрів і охоронців (замість пошуку тексту).
$scopeDefinitions = @(
    [pscustomobject]@{ Type = 'MODEL'; Enabled = $true },
    [pscustomobject]@{ Type = 'BLOG'; Enabled = $true },
    [pscustomobject]@{ Type = 'BRAVOEXCH'; Enabled = $true },
    [pscustomobject]@{ Type = 'BAZA_APP'; Enabled = 'false' }
)
$scopeSelected = @(Select-BRAVOExpectedArchiveDefinition -ArchiveDefinitions $scopeDefinitions -NotInstalledComponents @('BRAVOEXCH'))
$scopeSelectedAll = @(Select-BRAVOExpectedArchiveDefinition -ArchiveDefinitions $scopeDefinitions)
Test-BRAVOCondition -Condition (
    $scopeSelected.Count -eq 2 -and
    @($scopeSelected.Type) -contains 'MODEL' -and
    @($scopeSelected.Type) -contains 'BLOG' -and
    @($scopeSelected.Type) -notcontains 'BRAVOEXCH' -and
    @($scopeSelected.Type) -notcontains 'BAZA_APP' -and
    $scopeSelectedAll.Count -eq 3 -and
    @($scopeSelectedAll.Type) -contains 'BRAVOEXCH'
) -Name 'BackupScope/ExpectedArchiveDefinitionsExcludeNotInstalled' `
    -Failure 'Select-BRAVOExpectedArchiveDefinition (фільтр Archive/Health/Dry Run) має виключати NotInstalled і вимкнені (зокрема рядок "false"), а без NotInstalled повертати всі увімкнені'

# Health: реальна функція з Health runtime на фікстурі.
$scopeHealthModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText $scopeHealthText `
    -FunctionNames @('Get-BRAVOHealthExpectedArchiveDefinitions')
$scopeHealthExpected = & $scopeHealthModule {
    param($Definitions)
    Set-StrictMode -Version Latest
    $archiveDefinitions = $Definitions
    $unset = @(Get-BRAVOHealthExpectedArchiveDefinitions | ForEach-Object { [string]$_.Type })
    $script:healthNotInstalledComponents = @('BRAVOEXCH')
    $filtered = @(Get-BRAVOHealthExpectedArchiveDefinitions | ForEach-Object { [string]$_.Type })
    $script:healthNotInstalledComponents = @()
    $empty = @(Get-BRAVOHealthExpectedArchiveDefinitions | ForEach-Object { [string]$_.Type })
    return [pscustomobject]@{ Unset = $unset; Filtered = $filtered; Empty = $empty }
} $scopeDefinitions
Test-BRAVOCondition -Condition (
    @($scopeHealthExpected.Filtered).Count -eq 2 -and
    @($scopeHealthExpected.Filtered) -notcontains 'BRAVOEXCH' -and
    @($scopeHealthExpected.Filtered) -contains 'MODEL' -and
    @($scopeHealthExpected.Unset).Count -eq 3 -and
    @($scopeHealthExpected.Empty).Count -eq 3
) -Name 'BackupScope/HealthExpectedArchivesExcludeNotInstalled' `
    -Failure 'Get-BRAVOHealthExpectedArchiveDefinitions має виключати NotInstalled-компонент; без стану прогону або з порожнім списком очікуються всі увімкнені'

# Dry Run: той самий канонічний фільтр з рядковими прапорцями Enabled.
$scopeDryRunSelected = @(Select-BRAVOExpectedArchiveDefinition `
    -ArchiveDefinitions @(
        [pscustomobject]@{ Type = 'MODEL'; Enabled = 'true' },
        [pscustomobject]@{ Type = 'BLOG'; Enabled = '1' },
        [pscustomobject]@{ Type = 'BRAVOEXCH'; Enabled = $true }
    ) `
    -NotInstalledComponents @('BLOG'))
Test-BRAVOCondition -Condition (
    $scopeDryRunSelected.Count -eq 2 -and
    @($scopeDryRunSelected.Type) -notcontains 'BLOG' -and
    @($scopeDryRunSelected.Type) -contains 'BRAVOEXCH'
) -Name 'BackupScope/DryRunFilterExcludesNotInstalled' `
    -Failure 'фільтр Dry Run має виключати NotInstalled і розуміти рядкові прапорці Enabled'

# Archive: охоронець автоматичного оновлення baseline.
$scopeGuardScope = [pscustomobject]@{ NotInstalled = @() }
Test-BRAVOCondition -Condition (
    (Test-BRAVOBackupBaselineUpdateAllowed -GenerationStatus 'COMPLETE' -BaselineValid $true -BackupScope $scopeGuardScope -GenerationManifestPath 'C:\ExampleLims\ARCHIV\GEN\manifest.json') -and
    -not (Test-BRAVOBackupBaselineUpdateAllowed -GenerationStatus 'FAILED' -BaselineValid $true -BackupScope $scopeGuardScope -GenerationManifestPath 'C:\ExampleLims\ARCHIV\GEN\manifest.json') -and
    -not (Test-BRAVOBackupBaselineUpdateAllowed -GenerationStatus 'INCOMPLETE' -BaselineValid $true -BackupScope $scopeGuardScope -GenerationManifestPath 'C:\ExampleLims\ARCHIV\GEN\manifest.json') -and
    -not (Test-BRAVOBackupBaselineUpdateAllowed -GenerationStatus 'COMPLETE' -BaselineValid $false -BackupScope $scopeGuardScope -GenerationManifestPath 'C:\ExampleLims\ARCHIV\GEN\manifest.json') -and
    -not (Test-BRAVOBackupBaselineUpdateAllowed -GenerationStatus 'COMPLETE' -BaselineValid $true -BackupScope $null -GenerationManifestPath 'C:\ExampleLims\ARCHIV\GEN\manifest.json') -and
    -not (Test-BRAVOBackupBaselineUpdateAllowed -GenerationStatus 'COMPLETE' -BaselineValid $true -BackupScope $scopeGuardScope -GenerationManifestPath '')
) -Name 'BackupScope/ArchiveBaselineUpdateGuard' `
    -Failure 'baseline має оновлюватись лише після COMPLETE generation з придатним baseline, визначеним складом і записаним manifest'

# Archive: NotInstalled BAZA-компонент не синхронізується.
Test-BRAVOCondition -Condition (
    -not (Test-BRAVOBackupComponentInstalled -Component 'BAZA_APP' -NotInstalledComponents @('BAZA_APP', 'BRAVOEXCH')) -and
    (Test-BRAVOBackupComponentInstalled -Component 'BAZA_WWW' -NotInstalledComponents @('BAZA_APP')) -and
    (Test-BRAVOBackupComponentInstalled -Component 'BAZA_APP' -NotInstalledComponents @())
) -Name 'BackupScope/NotInstalledBazaComponentNotSynced' `
    -Failure 'Test-BRAVOBackupComponentInstalled має давати $false для NotInstalled BAZA_*, інакше ARCHIV синхронізував би відсутній компонент'

# SETUP: призначення BAZA_* перевіряються лише за увімкненої *_LOCAL
# синхронізації, а NotInstalled-компонент не перевіряється зовсім.
$scopeSetupArchiveDirs = @{ Model = 'C:\ExampleLims\ARCHIV\MODEL'; Blog = 'C:\ExampleLims\ARCHIV\BLOG'; BravoExch = 'C:\ExampleLims\ARCHIV\BRAVOEXCH' }
$scopeSetupPathsOff = Get-BRAVODiscoveryDestinationPaths -ArchiveDirectories $scopeSetupArchiveDirs `
    -BazaAppDestination 'C:\ExampleLims\BAZA_COPY' -BazaWwwDestination 'C:\ExampleWeb\BAZA_WWW_COPY' -BazaAppLocal $false -BazaWwwLocal 'false'
$scopeSetupPathsOn = Get-BRAVODiscoveryDestinationPaths -ArchiveDirectories $scopeSetupArchiveDirs `
    -BazaAppDestination 'C:\ExampleLims\BAZA_COPY' -BazaWwwDestination 'C:\ExampleWeb\BAZA_WWW_COPY' -BazaAppLocal $true -BazaWwwLocal 'true'
$scopeSetupSource = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_SELFTEST_SCOPE_SETUPSRC_' + [guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path $scopeSetupSource -Force)
    $scopeSetupDiscovery = [pscustomobject]@{
        MODEL_SOURCE = $null; BLOG_SOURCE = $null; BRAVOEXCH_SOURCE = $null
        BAZA_APP = $scopeSetupSource; BAZA_WWW = $null
    }
    # Призначення BAZA_APP збігається з джерелом: для встановленого
    # компонента це помилка, для NotInstalled - ні.
    $scopeSetupBadDestination = @{ BAZA_APP = $scopeSetupSource }
    $scopeSetupErrorsInstalled = @(Test-BRAVODiscoveryResult -DiscoveryResult $scopeSetupDiscovery `
        -EnabledComponents @{ BAZA_APP = $true } -DestinationPaths $scopeSetupBadDestination)
    $scopeSetupScopeNotInstalled = Resolve-BRAVOBackupComponentScope `
        -DiscoveryResult (New-BRAVOSelfTestScopeDiscovery -Presence @{ MODEL = 'Present'; BLOG = 'Present'; BRAVOEXCH = 'Present'; BAZA_APP = 'Absent'; BAZA_WWW = 'Present' }) `
        -EnabledComponents @{ BAZA_APP = $true }
    $scopeSetupErrorsNotInstalled = @(Test-BRAVODiscoveryResult -DiscoveryResult $scopeSetupDiscovery `
        -EnabledComponents $scopeSetupScopeNotInstalled.EffectiveEnabledComponents -DestinationPaths $scopeSetupBadDestination)
} finally {
    foreach ($scopeSetupTemp in @($scopeSetupSource)) {
        if (Test-Path -LiteralPath $scopeSetupTemp) { Remove-Item -LiteralPath $scopeSetupTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
Test-BRAVOCondition -Condition (
    -not $scopeSetupPathsOff.ContainsKey('BAZA_APP') -and
    -not $scopeSetupPathsOff.ContainsKey('BAZA_WWW') -and
    $scopeSetupPathsOff.ContainsKey('MODEL') -and
    $scopeSetupPathsOn.ContainsKey('BAZA_APP') -and
    $scopeSetupPathsOn.ContainsKey('BAZA_WWW') -and
    [string]$scopeSetupScopeNotInstalled.Components['BAZA_APP'] -eq 'NotInstalled' -and
    -not [bool]$scopeSetupScopeNotInstalled.EffectiveEnabledComponents['BAZA_APP'] -and
    $scopeSetupErrorsInstalled.Count -gt 0 -and
    $scopeSetupErrorsNotInstalled.Count -eq 0
) -Name 'BackupScope/SetupDestinationCheckHonoursNotInstalled' `
    -Failure 'SETUP має перевіряти призначення BAZA_* лише за увімкненої *_LOCAL синхронізації (рядок "false" = вимкнено) і не вимагати призначення для NotInstalled-компонента'

# (#301) Оголошений, але порожній каталог компонента (новий BLOG, порожня черга
# BEXCH). Рішення власника 2026-10-07: Warning, не блокує. Порожній каталог
# пропускається без Error; якщо компонент раніше був підтверджений (baseline
# або архів в останній COMPLETE generation), кожен прогін пише WARNING.
# Відсутній чи нечитабельний каталог, як і раніше, - Error; обов'язковий MODEL
# з порожнім каталогом - Error. Presence дає production-функція на справжніх
# каталогах, склад - Resolve-BRAVOBackupComponentScope, як у BRAVO_ARCHIV.
$scope301Root = Join-Path ([IO.Path]::GetTempPath()) ('BRAVO_SELFTEST_BASELINE301_' + [guid]::NewGuid().ToString('N'))
try {
    $scope301Full = Join-Path $scope301Root 'full'
    $scope301Empty = Join-Path $scope301Root 'empty'
    $scope301Missing = Join-Path $scope301Root 'missing'
    $scope301State = Join-Path $scope301Root 'state'
    $scope301Runtime = Join-Path $scope301Root 'runtime'
    foreach ($scope301Dir in @($scope301Full, $scope301Empty, $scope301State, $scope301Runtime)) {
        [void](New-Item -ItemType Directory -Path $scope301Dir -Force)
    }
    [IO.File]::WriteAllText((Join-Path $scope301Full 'data.txt'), 'x')

    function Resolve-BRAVOSelfTestScope301Presence {
        param([string]$Component, [string]$Path)
        $moduleScope = Get-Module -Name 'BRAVO.Discovery'
        return (& $moduleScope {
            param($c, $p)
            Resolve-BRAVODiscoveryPathComponentPresence -Component $c -Path $p -Source 'BravoIni' -Reason 'bravo.ini'
        } $Component $Path)
    }
    function New-BRAVOSelfTestScope301Discovery {
        # Discovery, де компонент береться з реального каталогу: presence дає
        # production-функція, а сире поле лишається шляхом (як у discovery).
        param([string]$BlogPath, [string]$ModelPath)
        $discovery = New-BRAVOSelfTestScopeDiscovery -Presence @{ MODEL = 'Present'; BLOG = 'Present'; BRAVOEXCH = 'Present'; BAZA_APP = 'Present'; BAZA_WWW = 'Present' }
        $discovery.BLOG_SOURCE = $BlogPath
        $discovery.Components['BLOG'] = Resolve-BRAVOSelfTestScope301Presence -Component 'BLOG' -Path $BlogPath
        if (-not [string]::IsNullOrWhiteSpace($ModelPath)) {
            $discovery.MODEL_SOURCE = $ModelPath
            $discovery.Components['MODEL'] = Resolve-BRAVOSelfTestScope301Presence -Component 'MODEL' -Path $ModelPath
        }
        return $discovery
    }
    function Get-BRAVOSelfTestScope301Findings {
        param([object]$Scope, [string]$Component, [string]$Severity)
        return @(@($Scope.Findings) | Where-Object {
            [string]$_.Component -eq $Component -and [string]$_.Severity -eq $Severity
        })
    }
    function Invoke-BRAVOSelfTestScope301Resolve {
        # Повертає scope або текст винятку: на старому коді тест має впасти
        # власною умовою, а не обірвати секцію.
        param([object]$Discovery, [object]$Baseline, [string]$BaselineSourceKind = 'None', [string[]]$Previous = @())
        try {
            return (Resolve-BRAVOBackupComponentScope -DiscoveryResult $Discovery -Baseline $Baseline `
                -BaselineSourceKind $BaselineSourceKind -EnabledComponents $scopeAllEnabled `
                -PreviousCompleteComponents $Previous)
        } catch {
            return [pscustomobject]@{ Components = @{}; NotInstalled = @(); Findings = @(); EffectiveEnabledComponents = @{}; Threw = $_.Exception.Message }
        }
    }
    $scope301ConfirmedBaseline = [pscustomobject]@{ MODEL_SOURCE = 'C:\ExampleLims\Model'; BLOG_SOURCE = $scope301Full }

    # (a) Порожній каталог, раніше не підтверджений: пропуск з Info, без Error.
    $scope301EmptyDiscovery = New-BRAVOSelfTestScope301Discovery -BlogPath $scope301Empty
    $scope301EmptyNew = Invoke-BRAVOSelfTestScope301Resolve -Discovery $scope301EmptyDiscovery
    $scope301EmptyNewThrewProperty = $scope301EmptyNew.PSObject.Properties['Threw']
    $scope301EmptyNewThrew = $(if ($null -ne $scope301EmptyNewThrewProperty) { [string]$scope301EmptyNewThrewProperty.Value } else { '' })
    Test-BRAVOCondition -Condition (
        [string]$scope301EmptyDiscovery.Components['BLOG'].Presence -eq 'Absent' -and
        [string]$scope301EmptyDiscovery.Components['BLOG'].Source -eq 'BravoIni' -and
        [string]$scope301EmptyNew.Components['BLOG'] -eq 'EmptySource' -and
        @($scope301EmptyNew.NotInstalled) -contains 'BLOG' -and
        -not [bool]$scope301EmptyNew.EffectiveEnabledComponents['BLOG'] -and
        @($scope301EmptyNew.Findings | Where-Object { [string]$_.Severity -in @('Error', 'Warning') }).Count -eq 0 -and
        @(Get-BRAVOSelfTestScope301Findings -Scope $scope301EmptyNew -Component 'BLOG' -Severity 'Info').Count -eq 1
    ) -Name 'BackupScope/DeclaredEmptySourceNeverConfirmedIsSkippedWithInfo' `
        -Failure "оголошений (bravo.ini), але порожній каталог без підтвердження має пропускатись з Info (scope EmptySource), без Error; scope='$($scope301EmptyNew.Components['BLOG'])' threw='$scope301EmptyNewThrew'"

    # (b) Компонент був підтверджений у baseline, тепер каталог порожній:
    # WARNING на кожному прогоні, без Error і без зупинки.
    $scope301Emptied = Invoke-BRAVOSelfTestScope301Resolve -Discovery $scope301EmptyDiscovery `
        -Baseline $scope301ConfirmedBaseline -BaselineSourceKind 'Canonical'
    Test-BRAVOCondition -Condition (
        [string]$scope301Emptied.Components['BLOG'] -eq 'EmptySource' -and
        @($scope301Emptied.NotInstalled) -contains 'BLOG' -and
        @($scope301Emptied.Findings | Where-Object { [string]$_.Severity -eq 'Error' }).Count -eq 0 -and
        @(Get-BRAVOSelfTestScope301Findings -Scope $scope301Emptied -Component 'BLOG' -Severity 'Warning').Count -eq 1
    ) -Name 'BackupScope/DeclaredEmptySourcePreviouslyConfirmedWarns' `
        -Failure "раніше підтверджений компонент з порожнім каталогом має давати Warning без Error (рішення власника #301); scope='$($scope301Emptied.Components['BLOG'])'"

    # (c) Baseline ще немає, але компонент мав архів в останній COMPLETE
    # generation: теж «раніше мав дані» -> Warning, не Error.
    $scope301PrevEmpty = Invoke-BRAVOSelfTestScope301Resolve -Discovery $scope301EmptyDiscovery -Previous @('MODEL', 'BLOG')
    Test-BRAVOCondition -Condition (
        [string]$scope301PrevEmpty.Components['BLOG'] -eq 'EmptySource' -and
        @($scope301PrevEmpty.Findings | Where-Object { [string]$_.Severity -eq 'Error' }).Count -eq 0 -and
        @(Get-BRAVOSelfTestScope301Findings -Scope $scope301PrevEmpty -Component 'BLOG' -Severity 'Warning').Count -eq 1
    ) -Name 'BackupScope/PreviouslyBackedUpEmptySourceWarnsWithoutBaseline' `
        -Failure "без baseline компонент, що мав архів в останній COMPLETE generation і тепер має порожній каталог, має давати Warning без Error; scope='$($scope301PrevEmpty.Components['BLOG'])'"

    # (d) Guard: відсутній оголошений каталог лишається Error з baseline і без.
    $scope301MissingDiscovery = New-BRAVOSelfTestScope301Discovery -BlogPath $scope301Missing
    $scope301MissingNew = Invoke-BRAVOSelfTestScope301Resolve -Discovery $scope301MissingDiscovery
    $scope301MissingConfirmed = Invoke-BRAVOSelfTestScope301Resolve -Discovery $scope301MissingDiscovery `
        -Baseline $scope301ConfirmedBaseline -BaselineSourceKind 'Canonical'
    Test-BRAVOCondition -Condition (
        [string]$scope301MissingNew.Components['BLOG'] -eq 'Missing' -and
        @(Get-BRAVOSelfTestScope301Findings -Scope $scope301MissingNew -Component 'BLOG' -Severity 'Error').Count -ge 1 -and
        @($scope301MissingNew.NotInstalled) -notcontains 'BLOG' -and
        [string]$scope301MissingConfirmed.Components['BLOG'] -eq 'Missing' -and
        @(Get-BRAVOSelfTestScope301Findings -Scope $scope301MissingConfirmed -Component 'BLOG' -Severity 'Error').Count -ge 1
    ) -Name 'BackupScope/DeclaredMissingSourceStaysError' `
        -Failure "відсутній оголошений каталог має лишатись Missing (Error) і з baseline, і без нього; без baseline='$($scope301MissingNew.Components['BLOG'])' з baseline='$($scope301MissingConfirmed.Components['BLOG'])'"

    # (e) Guard: обов'язковий MODEL з порожнім каталогом - Error.
    $scope301ModelEmpty = Invoke-BRAVOSelfTestScope301Resolve `
        -Discovery (New-BRAVOSelfTestScope301Discovery -BlogPath $scope301Full -ModelPath $scope301Empty)
    Test-BRAVOCondition -Condition (
        [string]$scope301ModelEmpty.Components['MODEL'] -eq 'Missing' -and
        @($scope301ModelEmpty.NotInstalled) -notcontains 'MODEL' -and
        @(Get-BRAVOSelfTestScope301Findings -Scope $scope301ModelEmpty -Component 'MODEL' -Severity 'Error').Count -eq 1
    ) -Name 'BackupScope/MandatoryModelEmptySourceStaysError' `
        -Failure "обов'язковий MODEL з порожнім каталогом має бути Missing (Error); scope='$($scope301ModelEmpty.Components['MODEL'])'"

    # (f) Baseline пише '' лише для доведено порожнього каталогу; Present,
    # відсутній каталог і Error/Ambiguous зберігають сире джерело.
    $scope301SaveDiscovery = New-BRAVOSelfTestScope301Discovery -BlogPath $scope301Empty
    $scope301SaveDiscovery.BRAVOEXCH_SOURCE = $scope301Missing
    $scope301SaveDiscovery.Components['BRAVOEXCH'] = Resolve-BRAVOSelfTestScope301Presence -Component 'BRAVOEXCH' -Path $scope301Missing
    $scope301SaveDiscovery.BAZA_APP = 'C:\ExampleLims\BAZA'
    $scope301SaveDiscovery.Components['BAZA_APP'] = [pscustomobject]@{
        Component = 'BAZA_APP'; Presence = 'Error'; Source = 'BravoIni'; Path = $null; Reason = 'синтетично: не прочитано'
    }
    $scope301BaselinePath = Get-BRAVODiscoveryBaselinePath -StateRoot $scope301State
    Save-BRAVODiscoveryBaseline -DiscoveryResult $scope301SaveDiscovery -BaselinePath $scope301BaselinePath
    $scope301SavedJson = Get-Content -LiteralPath $scope301BaselinePath -Raw | ConvertFrom-Json
    Test-BRAVOCondition -Condition (
        [string]$scope301SavedJson.BLOG_SOURCE -eq '' -and
        [string]$scope301SavedJson.MODEL_SOURCE -eq 'C:\ExampleLims\Model' -and
        [string]$scope301SavedJson.BRAVOEXCH_SOURCE -eq $scope301Missing -and
        [string]$scope301SavedJson.BAZA_APP -eq 'C:\ExampleLims\BAZA'
    ) -Name 'BackupScope/BaselineBlanksOnlyProvenEmptySource' `
        -Failure "baseline має писати '' лише для доведено порожнього каталогу; BLOG='$($scope301SavedJson.BLOG_SOURCE)' BRAVOEXCH='$($scope301SavedJson.BRAVOEXCH_SOURCE)' BAZA_APP='$($scope301SavedJson.BAZA_APP)'"

    # (g) Наскрізно #301: оператор підтвердив baseline з порожнім каталогом ->
    # наступний прогін дає Info без Warning і без Error.
    $scope301Import = Import-BRAVODiscoveryBaseline -StateRoot $scope301State -RuntimeRoot $scope301Runtime -ReadOnly
    $scope301Reconfirmed = Invoke-BRAVOSelfTestScope301Resolve -Discovery $scope301EmptyDiscovery `
        -Baseline $scope301Import.Baseline -BaselineSourceKind ([string]$scope301Import.Source)
    Test-BRAVOCondition -Condition (
        [string]$scope301Import.Source -eq 'Canonical' -and
        [string]$scope301Reconfirmed.Components['BLOG'] -eq 'EmptySource' -and
        @($scope301Reconfirmed.Findings | Where-Object { [string]$_.Severity -in @('Error', 'Warning') }).Count -eq 0 -and
        @(Get-BRAVOSelfTestScope301Findings -Scope $scope301Reconfirmed -Component 'BLOG' -Severity 'Info').Count -eq 1
    ) -Name 'BackupScope/ReconfirmedEmptySourceIsInfo' `
        -Failure "після підтвердження baseline з порожнім каталогом наступний прогін має дати Info без Warning/Error; scope='$($scope301Reconfirmed.Components['BLOG'])' source='$($scope301Import.Source)'"

    # (h) Попередній перегляд -ValidateOnly -ConfirmDiscoveryBaseline будує
    # baseline тією самою функцією, що й справжнє збереження.
    $scope301SnapshotCommand = Get-Command -Name 'New-BRAVODiscoveryBaselineSnapshot' -ErrorAction SilentlyContinue
    $scope301Snapshot = $null
    if ($null -ne $scope301SnapshotCommand) {
        $scope301Snapshot = New-BRAVODiscoveryBaselineSnapshot -DiscoveryResult $scope301SaveDiscovery
    }
    $scope301SetupText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_SETUP.ps1'))
    Test-BRAVOCondition -Condition (
        $null -ne $scope301Snapshot -and
        [string]$scope301Snapshot.BLOG_SOURCE -eq '' -and
        [string]$scope301Snapshot.MODEL_SOURCE -eq 'C:\ExampleLims\Model' -and
        $scope301SetupText -match 'New-BRAVODiscoveryBaselineSnapshot\s+-DiscoveryResult\s+\$bravoDiscoveryResult'
    ) -Name 'BackupScope/SetupPreviewUsesBaselineSnapshot' `
        -Failure 'BRAVO_SETUP -ValidateOnly -ConfirmDiscoveryBaseline має будувати попередній baseline через New-BRAVODiscoveryBaselineSnapshot (та сама логіка, що й Save-BRAVODiscoveryBaseline)'

    # (i) Warning-знахідки доходять до журналу Archive і виводу SETUP як
    # попередження, а не губляться як INFO.
    $scope301ArchiveText = [IO.File]::ReadAllText((Join-Path $root 'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1'))
    Test-BRAVOCondition -Condition (
        $scope301ArchiveText -match "Severity -eq 'Warning'\) \{ 'WARNING' \}" -and
        $scope301SetupText -match "Severity -eq 'Warning'\) \{ 'Yellow' \}"
    ) -Name 'BackupScope/DriftWarningReportedAsWarning' `
        -Failure 'Archive має писати Warning-знахідку складу рівнем WARNING, а SETUP - жовтим'

    function Get-BRAVOSelfTestScope301List {
        # Читання поля, якого на старому коді немає, без винятку StrictMode.
        param([object]$Object, [string]$Name)
        if ($null -eq $Object) { return @() }
        $property = $Object.PSObject.Properties[$Name]
        return @(if ($null -ne $property) { $property.Value })
    }
    function Get-BRAVOSelfTestScope301BaselineValue {
        param([object]$Import, [string]$Field)
        if ($null -eq $Import -or $null -eq $Import.Baseline) { return '' }
        $property = $Import.Baseline.PSObject.Properties[$Field]
        return $(if ($null -ne $property) { [string]$property.Value } else { '' })
    }

    # (j) Рев'ю #391: доказ присутності лише в останньому COMPLETE manifest.
    # Перший прогін (baseline немає) дає Warning; нова generation BLOG уже не
    # містить, тому доказ має перейти в baseline, і другий прогін теж дає
    # Warning, а не тихий Info. Обидва прогони - production-ланцюг
    # Resolve -> Update-BRAVODiscoveryBaselineFromScope -> Import -> Resolve.
    $scope301RunState = Join-Path $scope301Root 'state-runs'
    $scope301Night1 = Invoke-BRAVOSelfTestScope301Resolve -Discovery $scope301EmptyDiscovery -Previous @('MODEL', 'BLOG')
    $scope301Night1UpdateError = ''
    try {
        [void](Update-BRAVODiscoveryBaselineFromScope -DiscoveryResult $scope301EmptyDiscovery `
            -ScopeResult $scope301Night1 -StateRoot $scope301RunState -RuntimeRoot $scope301Runtime)
    } catch { $scope301Night1UpdateError = $_.Exception.Message }
    $scope301Night2Import = Import-BRAVODiscoveryBaseline -StateRoot $scope301RunState -RuntimeRoot $scope301Runtime -ReadOnly
    $scope301Night2BlogBaseline = Get-BRAVOSelfTestScope301BaselineValue -Import $scope301Night2Import -Field 'BLOG_SOURCE'
    $scope301Night2 = Invoke-BRAVOSelfTestScope301Resolve -Discovery $scope301EmptyDiscovery `
        -Baseline $scope301Night2Import.Baseline -BaselineSourceKind ([string]$scope301Night2Import.Source) -Previous @('MODEL')
    Test-BRAVOCondition -Condition (
        @(Get-BRAVOSelfTestScope301Findings -Scope $scope301Night1 -Component 'BLOG' -Severity 'Warning').Count -eq 1 -and
        $scope301Night1UpdateError -eq '' -and
        [string]$scope301Night2Import.Source -eq 'Canonical' -and
        $scope301Night2BlogBaseline -eq $scope301Empty -and
        [string]$scope301Night2.Components['BLOG'] -eq 'EmptySource' -and
        @($scope301Night2.Findings | Where-Object { [string]$_.Severity -eq 'Error' }).Count -eq 0 -and
        @(Get-BRAVOSelfTestScope301Findings -Scope $scope301Night2 -Component 'BLOG' -Severity 'Warning').Count -eq 1
    ) -Name 'BackupScope/EmptySourceWarningPersistsAfterFirstRun' `
        -Failure "Warning для порожнього каталогу, доведеного лише manifest, має повторитись і наступного прогону: baseline BLOG='$scope301Night2BlogBaseline' source='$($scope301Night2Import.Source)' scope='$($scope301Night2.Components['BLOG'])' update='$scope301Night1UpdateError'"

    # (k) Те саме, коли baseline уже є, але поле BLOG порожнє (baseline
    # старший за COMPLETE manifest): доказ дописується в наявний baseline.
    $scope301BlankState = Join-Path $scope301Root 'state-blank'
    Save-BRAVODiscoveryBaseline -DiscoveryResult $scope301EmptyDiscovery `
        -BaselinePath (Get-BRAVODiscoveryBaselinePath -StateRoot $scope301BlankState) -Components @('MODEL')
    $scope301BlankImport = Import-BRAVODiscoveryBaseline -StateRoot $scope301BlankState -RuntimeRoot $scope301Runtime -ReadOnly
    $scope301BlankNight1 = Resolve-BRAVOBackupComponentScope -DiscoveryResult $scope301EmptyDiscovery `
        -Baseline $scope301BlankImport.Baseline -BaselineSourceKind ([string]$scope301BlankImport.Source) `
        -EnabledComponents $scopeAllEnabled -PreviousCompleteComponents @('MODEL', 'BLOG') `
        -PreviousCompleteAt ((Get-Date).ToUniversalTime().AddMinutes(5))
    $scope301BlankUpdateError = ''
    try {
        [void](Update-BRAVODiscoveryBaselineFromScope -DiscoveryResult $scope301EmptyDiscovery `
            -ScopeResult $scope301BlankNight1 -StateRoot $scope301BlankState -RuntimeRoot $scope301Runtime)
    } catch { $scope301BlankUpdateError = $_.Exception.Message }
    $scope301BlankNight2Import = Import-BRAVODiscoveryBaseline -StateRoot $scope301BlankState -RuntimeRoot $scope301Runtime -ReadOnly
    $scope301BlankNight2BlogBaseline = Get-BRAVOSelfTestScope301BaselineValue -Import $scope301BlankNight2Import -Field 'BLOG_SOURCE'
    $scope301BlankNight2 = Invoke-BRAVOSelfTestScope301Resolve -Discovery $scope301EmptyDiscovery `
        -Baseline $scope301BlankNight2Import.Baseline -BaselineSourceKind ([string]$scope301BlankNight2Import.Source) -Previous @('MODEL')
    Test-BRAVOCondition -Condition (
        [string]$scope301BlankImport.Source -eq 'Canonical' -and
        @(Get-BRAVOSelfTestScope301Findings -Scope $scope301BlankNight1 -Component 'BLOG' -Severity 'Warning').Count -eq 1 -and
        $scope301BlankUpdateError -eq '' -and
        $scope301BlankNight2BlogBaseline -eq $scope301Empty -and
        (Get-BRAVOSelfTestScope301BaselineValue -Import $scope301BlankNight2Import -Field 'MODEL_SOURCE') -eq 'C:\ExampleLims\Model' -and
        @(Get-BRAVOSelfTestScope301Findings -Scope $scope301BlankNight2 -Component 'BLOG' -Severity 'Warning').Count -eq 1
    ) -Name 'BackupScope/EmptySourceEvidenceExtendsExistingBaseline' `
        -Failure "доказ manifest для порожнього каталогу має дописатись у наявний baseline з порожнім полем: BLOG='$scope301BlankNight2BlogBaseline' update='$scope301BlankUpdateError'"

    # (l) Рев'ю #391: read-only склад для Health і Dry Run розрізняє «не
    # встановлено» і «каталог порожній», а Warning-випадок видно окремо.
    $scope301RoWarnState = Join-Path $scope301Root 'state-ro-warn'
    Save-BRAVODiscoveryBaseline -DiscoveryResult (New-BRAVOSelfTestScope301Discovery -BlogPath $scope301Full) `
        -BaselinePath (Get-BRAVODiscoveryBaselinePath -StateRoot $scope301RoWarnState)
    $scope301RoWarn = Get-BRAVOBackupNotInstalledComponents -DiscoveryResult $scope301EmptyDiscovery `
        -EnabledComponents $scopeAllEnabled -StateRoot $scope301RoWarnState -RuntimeRoot $scope301Runtime
    $scope301RoInfo = Get-BRAVOBackupNotInstalledComponents -DiscoveryResult $scope301EmptyDiscovery `
        -EnabledComponents $scopeAllEnabled -StateRoot (Join-Path $scope301Root 'state-ro-none') -RuntimeRoot $scope301Runtime
    $scope301RoWarnEmpty = @(Get-BRAVOSelfTestScope301List -Object $scope301RoWarn -Name 'EmptySource')
    $scope301RoWarnWarning = @(Get-BRAVOSelfTestScope301List -Object $scope301RoWarn -Name 'EmptySourceWarning')
    $scope301RoInfoEmpty = @(Get-BRAVOSelfTestScope301List -Object $scope301RoInfo -Name 'EmptySource')
    $scope301RoInfoWarning = @(Get-BRAVOSelfTestScope301List -Object $scope301RoInfo -Name 'EmptySourceWarning')
    Test-BRAVOCondition -Condition (
        @($scope301RoWarn.NotInstalled) -contains 'BLOG' -and
        $scope301RoWarnEmpty -contains 'BLOG' -and
        $scope301RoWarnWarning -contains 'BLOG' -and
        @($scope301RoInfo.NotInstalled) -contains 'BLOG' -and
        $scope301RoInfoEmpty -contains 'BLOG' -and
        $scope301RoInfoWarning.Count -eq 0
    ) -Name 'BackupScope/ReadOnlyScopeReportsEmptySourceSeparately' `
        -Failure "Get-BRAVOBackupNotInstalledComponents має повертати EmptySource і EmptySourceWarning окремо від NotInstalled; warn: empty='$($scope301RoWarnEmpty -join ',')' warning='$($scope301RoWarnWarning -join ',')'; info: empty='$($scope301RoInfoEmpty -join ',')' warning='$($scope301RoInfoWarning -join ',')'"

    # (m) Guard: явне перевизначення шляху на порожній каталог лишається
    # Error (оператор указав шлях свідомо), як і до #301.
    $scope301OverrideDiscovery = New-BRAVOSelfTestScope301Discovery -BlogPath $scope301Full
    $scope301OverrideDiscovery.BLOG_SOURCE = $scope301Empty
    $scope301OverrideDiscovery.Components['BLOG'] = (& (Get-Module -Name 'BRAVO.Discovery') {
        param($p)
        Resolve-BRAVODiscoveryPathComponentPresence -Component 'BLOG' -Path $p -Source 'ExplicitOverride' -Reason 'override'
    } $scope301Empty)
    $scope301Override = Invoke-BRAVOSelfTestScope301Resolve -Discovery $scope301OverrideDiscovery
    Test-BRAVOCondition -Condition (
        [string]$scope301OverrideDiscovery.Components['BLOG'].Presence -eq 'Error' -and
        [string]$scope301Override.Components['BLOG'] -ne 'EmptySource' -and
        @($scope301Override.NotInstalled) -notcontains 'BLOG' -and
        @(Get-BRAVOSelfTestScope301Findings -Scope $scope301Override -Component 'BLOG' -Severity 'Error').Count -ge 1
    ) -Name 'BackupScope/ExplicitOverrideEmptySourceStaysError' `
        -Failure "явний override на порожній каталог має лишатись Error; presence='$($scope301OverrideDiscovery.Components['BLOG'].Presence)' scope='$($scope301Override.Components['BLOG'])'"

    # (n) Guard: MODEL, підтверджений у baseline, з порожнім каталогом -
    # Error (Warning зі знахідки дрейфу не послаблює обов'язковий компонент).
    $scope301ModelConfirmed = Invoke-BRAVOSelfTestScope301Resolve `
        -Discovery (New-BRAVOSelfTestScope301Discovery -BlogPath $scope301Full -ModelPath $scope301Empty) `
        -Baseline ([pscustomobject]@{ MODEL_SOURCE = $scope301Empty; BLOG_SOURCE = $scope301Full }) -BaselineSourceKind 'Canonical'
    Test-BRAVOCondition -Condition (
        [string]$scope301ModelConfirmed.Components['MODEL'] -eq 'Missing' -and
        @(Get-BRAVOSelfTestScope301Findings -Scope $scope301ModelConfirmed -Component 'MODEL' -Severity 'Error').Count -ge 1
    ) -Name 'BackupScope/ConfirmedModelEmptySourceStaysError' `
        -Failure "підтверджений у baseline MODEL з порожнім каталогом має бути Missing (Error); scope='$($scope301ModelConfirmed.Components['MODEL'])'"
} finally {
    if (Test-Path -LiteralPath $scope301Root) {
        Remove-Item -LiteralPath $scope301Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
