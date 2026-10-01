# ============================================================
# BackupScope: резервне копіювання лише наявних компонентів
# ============================================================
# Рішення власника 2026-10-01 (designs/backup-scope-by-environment.md):
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
    $scopeArchiveText.Contains('$_.Enabled -and $notInstalledComponents -notcontains [string]$_.Type') -and
    $scopeArchiveText.Contains('$discoveryDriftFindings = @($backupScope.Findings)') -and
    $scopeArchiveText.Contains('-ComponentScope $(if ($null -ne $backupScope) { $backupScope.Components } else { $null })') -and
    $scopeArchiveText.Contains("`$manifest['componentScope'] = `$componentScopeProperty.Value") -and
    $scopeArchiveText.Contains('$baselineUpdate = Update-BRAVODiscoveryBaselineFromScope')
) -Name 'BackupScope/ArchiveUsesCanonicalScope' `
    -Failure 'BRAVO_ARCHIV має обчислювати склад до гілки -SyncBAZA, фільтрувати NotInstalled, писати componentScope у manifest і доповнювати baseline лише через канонічні функції'
Test-BRAVOCondition -Condition (
    $scopeHealthText.Contains('function Get-BRAVOHealthExpectedArchiveDefinitions') -and
    $scopeHealthText.Contains('$healthComponentScope = Get-BRAVOBackupNotInstalledComponents') -and
    -not $scopeHealthText.Contains('@($archiveDefinitions | Where-Object { $_.Enabled })')
) -Name 'BackupScope/HealthExpectsOnlyInstalledComponents' `
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
    $scopeDryRunText.Contains('foreach ($definition in $dryRunArchiveDefinitions)') -and
    -not $scopeDryRunText.Contains('@($archiveDefinitions | Where-Object { Test-SettingEnabled $_.Enabled })')
) -Name 'BackupScope/DryRunChecksOnlyInstalledComponents' `
    -Failure 'Dry Run має перевіряти джерела й призначення лише встановлених компонентів через Get-BRAVOBackupNotInstalledComponents'
Test-BRAVOCondition -Condition (
    $scopeSetupText.Contains('$discoveryScope = Resolve-BRAVOBackupComponentScope') -and
    $scopeSetupText.Contains('-EnabledComponents $discoveryScope.EffectiveEnabledComponents')
) -Name 'BackupScope/SetupValidatesEffectiveComposition' `
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
) -Name 'BackupScope/ArchiveSummaryCountsOnlyInstalledComponents' `
    -Failure 'status JSON componentsTotal, секція "Архіви", план і лог мають використовувати $enabledArchives: NotInstalled не рахується і не друкується як "Архів не створено"'
