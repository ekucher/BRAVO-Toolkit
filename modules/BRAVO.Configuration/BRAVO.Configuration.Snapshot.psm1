Set-StrictMode -Version 2.0

# BRAVO.Configuration.Snapshot - canonical знімок ЕФЕКТИВНОЇ конфігурації
# (#154, підготовка pilot migration).
#
# ВІДПОВІДАЛЬНІСТЬ: відповісти на питання "які саме значення діють на
# ЦЬОМУ хості ПІСЛЯ завантаження конфігурації". Це не завантаження
# (BRAVO.Configuration.psm1), не порівняння двох графів
# (BRAVO.Configuration.Delta.psm1) і не дельта site-значень відносно
# дефолтів (deploy\Get-BRAVOConfigSiteDelta.ps1, який дивиться на RAW
# primary-шар ДО злиття). Той самий поділ, що вже застосовано для
# Derivation/Delta/Schema.
#
# НАВІЩО ВОНО ІСНУЄ. Критерій приймання міграції site-значень з
# BRAVO.config у BRAVO.local.config - "ефективні значення не змінились".
# Довести це можна лише над ПОВНИМ графом: ефективна конфігурація - це
# 77 іменованих $global:-змінних, а не три корені. Без канонічного
# переліку кожен інструмент вів би власну копію цього списку, і мовчазне
# розходження копій знецінило б сам доказ.
#
# МОДУЛЬ НІЧОГО НЕ ЗАВАНТАЖУЄ. Він читає вже виставлені змінні поточної
# сесії; викликач сам вирішує, коли й як виконати Import-BravoConfiguration.
# Це тримає напрямок залежностей від entrypoint-а до домену, а не навпаки.

function Get-BRAVOEffectiveConfigurationVariableName {
    <#
        Канонічний перелік імен $global:-змінних, які складають ефективну
        конфігурацію BRAVO.

        ЄДИНЕ ДЖЕРЕЛО ІСТИНИ для цього переліку. Раніше він існував лише
        як літерал усередині ci\Test-BRAVOConfigFoundationParity.ps1;
        поки споживач був один, це було нормально, але доказ міграції
        потрібен і на сервері, де git-залежний harness не запускається.

        Порядок імен збережено з тієї реалізації навмисно: він визначає
        порядок ключів у знімку, тобто й у файлах доказів, які оператор
        порівнюватиме побайтово.
    #>
    return @(
        'BravoConfigurationMetadata', 'BravoLocalConfigOverrideState',
        'ScriptVersion', 'ScriptDate', 'ScriptBuildId', 'archivePrefix',
        'backupConsistency', 'backupMonitoring', 'bravoSettings',
        'componentSettings', 'credentialSettings', 'discoverySettings',
        'maintenanceSettings', 'pathSettings', 'restoreVerifySettings',
        'runtimeRoot', 'schedulerSettings', 'sftpDirectories',
        'storageEffective', 'toolIntegritySettings', 'LogLevel',
        'archiveFileFilter', 'archiveParams', 'archiveRetentionDays',
        'archiveTimestampFormat', 'consoleSettings', 'defaultLogLevel',
        'durationFormat', 'elevationSettings', 'enableArchiveDeletion',
        'enableFailedArchiveDeletion', 'enableLunchArchiveCleanup',
        'enableOrphanTempCleanup', 'failedArchiveRetentionDays',
        'hashFileEncoding', 'hashFileExtension', 'hashFileFilter',
        'hostInformationSettings', 'logColors', 'logFileDateFormat',
        'logFileEncoding', 'logFileFilter', 'logFileNameTemplate',
        'logLevels', 'logRetentionDays', 'logSeparatorLength',
        'logTimestampFormat', 'lunchArchiveCleanupDirectories',
        'lunchArchiveCleanupPath', 'lunchArchiveRetentionMonths',
        'minimumRetainedVerifiedBackups', 'operationLockSettings',
        'orphanTempRetentionHours', 'progressSettings',
        'requireAdministrator', 'robocopyMaxSuccessExitCode',
        'robocopyOptions', 'robocopyPath', 'robocopyWindowStyle',
        'sftpConnectionTimeoutSeconds', 'sftpHostKey', 'sftpHostTemplate',
        'sftpPort', 'sftpSynchronizationOptions', 'smbSettings',
        'synchronizationSafety', 'winSCPIniPath', 'winSCPScriptEncoding',
        'effectiveLimsRoot', 'systemLogRoot', 'backupRootPath',
        'archiveDefinitions', 'archiveDirs', 'bazaAppPaths',
        'bazaWWWPaths', 'sourcePaths', 'bazaSyncEffective'
    )
}

function Get-BRAVOEffectiveConfigurationSnapshot {
    <#
        Знімок ефективної конфігурації з ПОТОЧНОЇ сесії.

        Викликається ПІСЛЯ Import-BravoConfiguration: без завантаження
        поверне знімок, у якому кожне поле має маркер відсутності, а не
        помилку - відсутність змінної тут є валідним станом (не кожна
        змінна виставляється в кожному режимі завантаження).

        Маркер відсутності - рядок '<<ABSENT>>'. Саме рядок, а не $null:
        $null є ЛЕГАЛЬНИМ значенням конфігурації, і плутати "поля немає"
        з "поле дорівнює $null" у доказі міграції не можна.
    #>
    param(
        # Перелік імен. За замовчуванням - канонічний; параметр існує для
        # вузьких діагностичних зрізів, а не для ведення другого переліку.
        [string[]]$VariableName
    )

    $names = if ($null -eq $VariableName -or $VariableName.Count -eq 0) {
        @(Get-BRAVOEffectiveConfigurationVariableName)
    } else {
        @($VariableName)
    }

    $snapshot = [ordered]@{}
    foreach ($name in $names) {
        $variable = Get-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
        $snapshot[$name] = if ($null -ne $variable) { $variable.Value } else { '<<ABSENT>>' }
    }
    return $snapshot
}
