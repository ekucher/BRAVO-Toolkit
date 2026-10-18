# BRAVO.Configurator.Presets — топологічні пресети як чисті model-
# трансформації. Жоден preset НЕ пише файл — лише повертає новий Model[]
# (той самий Set/Clear-BRAVOConfiguratorOverride контракт, що ручне
# редагування в UI), і UI/Persistence відповідає за подальший
# Update-BRAVOConfiguratorEffective/Invoke-BRAVOConfiguratorValidation/
# Invoke-BRAVOConfiguratorApply — так само, як для будь-якої іншої зміни.
#
# Master-switch semantics (P1.6): LocalPlusSMB, Current і Manual
# торкаються ЛИШЕ componentSettings.SFTP.Enabled/SMB.Enabled (або
# взагалі нічого) — ніколи дочірніх прапорців (ArchiveUpload/ArchiveCopy).
# Це узгоджується з canonical дизайном 5.2.2: master НІКОЛИ не мутує
# дочірні прапорці; вимикання/вмикання SFTP чи SMB через preset — лише
# перемикання master, а не "стирання"/"відновлення" child-налаштувань.
#
# feat/bravo-configurator-preset-baza-local: LocalOnly, LocalPlusSFTP і
# LocalPlusSFTPAndSMB ДОДАТКОВО виставляють до 4 незалежних BAZA-прапорців
# (componentSettings.Synchronization.BAZA_APP_LOCAL/BAZA_APP_SFTP/
# BAZA_WWW_LOCAL/BAZA_WWW_SFTP) — свідоме розширення контракту, не
# порушення "master не мутує дочірні прапорці" (ArchiveUpload/ArchiveCopy
# і далі не чіпаються жодним preset). Детальне обґрунтування — у
# докстрінгу Invoke-BRAVOConfiguratorPreset нижче.
#
# Хвиля 2 «куди копіювати» (#282): набір значень кожного preset-а винесено
# в чисту Get-BRAVOConfiguratorPresetOverrideSet; профілі напрямків
# інсталятора (Get-BRAVOConfiguratorBackupDestinationProfile:
# Cloud/CloudAndSamba/SambaOnly/LocalOnly) мають власні явні набори, бо
# свідомо відрізняються від UI-пресетів: BAZA_*_SFTP лишаються на
# конфігураційних дефолтах (див. докстрінг функції).

Set-StrictMode -Version 2.0

$script:BRAVOConfiguratorPresetNames = @(
    'LocalOnly', 'LocalPlusSMB', 'LocalPlusSFTP', 'LocalPlusSFTPAndSMB', 'Current', 'Manual'
)

function Get-BRAVOConfiguratorPresetCatalog {
    <#
    .SYNOPSIS
        Канонічний перелік пресетів для UI (Name, Label, опис) — єдине
        джерело назв/порядку, щоб UI не хардкодив список окремо.
    #>
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject]@{ Name = 'LocalOnly'; Label = 'Тільки локально'; Description = 'SFTP і SMB вимкнено глобально (обидва master-switches = $false); BAZA APP/WWW синхронізуються локально — валідна production-конфігурація.' }
        [pscustomobject]@{ Name = 'LocalPlusSMB'; Label = 'Локально + SMB'; Description = 'SFTP вимкнено, SMB увімкнено глобально.' }
        [pscustomobject]@{ Name = 'LocalPlusSFTP'; Label = 'Локально + SFTP'; Description = 'SFTP увімкнено, SMB вимкнено глобально.' }
        [pscustomobject]@{ Name = 'LocalPlusSFTPAndSMB'; Label = 'Локально + SFTP + SMB'; Description = 'SFTP і SMB увімкнено глобально.' }
        [pscustomobject]@{ Name = 'Current'; Label = 'Поточна конфігурація'; Description = 'Нічого не змінює — лишає модель як є.' }
        [pscustomobject]@{ Name = 'Manual'; Label = 'Вручну'; Description = 'Нічого не змінює — оператор редагує окремі поля самостійно.' }
    )
}

function Invoke-BRAVOConfiguratorPreset {
    <#
    .SYNOPSIS
        Застосовує named preset до Model — повертає НОВИЙ масив-модель
        (той самий immutable-snapshot контракт, що Set/Clear-BRAVOConfiguratorOverride).
    .DESCRIPTION
        Ідемпотентний: повторне застосування того самого preset до вже
        трансформованої моделі дає ту саму пару override-значень (Set
        override — детермінована операція, не накопичувальна).

        LocalPlusSMB/Current/Manual торкаються ЛИШЕ
        componentSettings.SFTP.Enabled/SMB.Enabled (або взагалі нічого).

        LocalOnly/LocalPlusSFTP/LocalPlusSFTPAndSMB (feat/bravo-configurator-
        preset-baza-local) ДОДАТКОВО виставляють до 4 BAZA-прапорців:
          - LocalOnly: BAZA_APP_LOCAL=true, BAZA_WWW_LOCAL=true — "усі
            локальні опції увімкнено", коли SFTP/SMB глобально вимкнені
            (BAZA_*_SFTP не чіпається — master і так вимкнений, тому їх
            raw-значення не впливає на Effective).
          - LocalPlusSFTP/LocalPlusSFTPAndSMB: BAZA_APP_LOCAL=false,
            BAZA_APP_SFTP=true, BAZA_WWW_LOCAL=false, BAZA_WWW_SFTP=true —
            локальна копія BAZA не потрібна, коли SFTP-синхронізація вже
            покриває обидва компоненти. BAZA_WWW_SFTP форсується true
            РАЗОМ з BAZA_WWW_LOCAL=false навмисно: на відміну від
            BAZA_APP_SFTP (schema default = $true), BAZA_WWW_SFTP має
            default = $false ("вмикайте свідомо") — без цього форсування
            вимкнення BAZA_WWW_LOCAL лишило б WWW-компонент БЕЗ жодного
            активного каналу синхронізації (ні локально, ні по SFTP).
          - LocalPlusSMB навмисно НЕ входить у цей список: BAZA-over-SMB
            transport не існує в кодовій базі (лише BAZA_*_LOCAL і
            BAZA_*_SFTP) — вимкнення BAZA_*_LOCAL тут осиротило б BAZA
            без жодного каналу. Побудова BAZA-over-SMB — окрема, значно
            більша backend-задача, свідомо поза межами цієї зміни.

        У кожному разі preset і далі НІКОЛИ не торкається ArchiveUpload/
        ArchiveCopy — жоден інший override у моделі, крім явно
        перелічених вище шляхів, не змінюється й не видаляється.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array]$Model,
        [Parameter(Mandatory = $true)]
        [ValidateSet('LocalOnly', 'LocalPlusSMB', 'LocalPlusSFTP', 'LocalPlusSFTPAndSMB', 'Current', 'Manual')]
        [string]$PresetName
    )

    # Набір override-значень preset-а має одне джерело —
    # Get-BRAVOConfiguratorPresetOverrideSet (профілі напрямків інсталятора
    # мають власні явні набори — див. Get-BRAVOConfiguratorBackupDestinationProfile).
    # Порядок застосування й шляхи ті самі, що й до винесення.
    $overrideSet = Get-BRAVOConfiguratorPresetOverrideSet -PresetName $PresetName
    if ($overrideSet.Count -eq 0) {
        return $Model
    }

    $updated = $Model
    foreach ($overridePath in @($overrideSet.Keys)) {
        $updated = Set-BRAVOConfiguratorOverride -Model $updated -Path $overridePath -Value $overrideSet[$overridePath]
    }

    return $updated
}

function Get-BRAVOConfiguratorPresetOverrideSet {
    <#
    .SYNOPSIS
        Чиста функція: повертає впорядкований набір «dot-шлях -> значення»,
        який виставляє preset. Нічого не читає й не пише.
    .DESCRIPTION
        Канонічне визначення пресетів (контракт описано в докстрінгу
        Invoke-BRAVOConfiguratorPreset): master-вимикачі SFTP/SMB і, для
        LocalOnly/LocalPlusSFTP/LocalPlusSFTPAndSMB, BAZA-прапорці.
        ArchiveUpload/ArchiveCopy не входять у жоден набір. Current і
        Manual повертають порожній набір.
    .OUTPUTS
        [System.Collections.Specialized.OrderedDictionary]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('LocalOnly', 'LocalPlusSMB', 'LocalPlusSFTP', 'LocalPlusSFTPAndSMB', 'Current', 'Manual')]
        [string]$PresetName
    )

    $overrideSet = [ordered]@{}
    switch ($PresetName) {
        'LocalOnly'            { $overrideSet['componentSettings.SFTP.Enabled'] = $false; $overrideSet['componentSettings.SMB.Enabled'] = $false }
        'LocalPlusSMB'         { $overrideSet['componentSettings.SFTP.Enabled'] = $false; $overrideSet['componentSettings.SMB.Enabled'] = $true }
        'LocalPlusSFTP'        { $overrideSet['componentSettings.SFTP.Enabled'] = $true;  $overrideSet['componentSettings.SMB.Enabled'] = $false }
        'LocalPlusSFTPAndSMB'  { $overrideSet['componentSettings.SFTP.Enabled'] = $true;  $overrideSet['componentSettings.SMB.Enabled'] = $true }
    }

    # feat/bravo-configurator-preset-baza-local: 3 з 4 нетривіальних
    # пресетів (крім LocalPlusSMB — див. докстрінг Invoke-BRAVOConfiguratorPreset
    # щодо відсутності BAZA-over-SMB transport) додатково виставляють явні
    # BAZA-override, узгоджені з обраною топологією синхронізації.
    switch ($PresetName) {
        'LocalOnly' {
            $overrideSet['componentSettings.Synchronization.BAZA_APP_LOCAL'] = $true
            $overrideSet['componentSettings.Synchronization.BAZA_WWW_LOCAL'] = $true
        }
        { $_ -in @('LocalPlusSFTP', 'LocalPlusSFTPAndSMB') } {
            $overrideSet['componentSettings.Synchronization.BAZA_APP_LOCAL'] = $false
            $overrideSet['componentSettings.Synchronization.BAZA_APP_SFTP'] = $true
            $overrideSet['componentSettings.Synchronization.BAZA_WWW_LOCAL'] = $false
            $overrideSet['componentSettings.Synchronization.BAZA_WWW_SFTP'] = $true
        }
    }

    return $overrideSet
}

function Get-BRAVOConfiguratorBackupDestinationProfile {
    <#
    .SYNOPSIS
        Чиста функція: профіль напрямків резервного копіювання -> набір
        override-значень для НОВОГО BRAVO.local.config.
    .DESCRIPTION
        Рішення власника (хвиля 2 «куди копіювати»): чотири профілі
        інсталятора відповідають топологіям наявних пресетів Configurator
        і не вводять нових листів конфігурації:

          Cloud          (Хмара, дефолт)  ~ LocalPlusSFTP
          CloudAndSamba  (Хмара + Samba)  ~ LocalPlusSFTPAndSMB
          SambaOnly      (Лише Samba)     ~ LocalPlusSMB
          LocalOnly      (Лише локально)  ~ LocalOnly

        Набори значень профілів визначено ЯВНО, а не похідно від
        Get-BRAVOConfiguratorPresetOverrideSet, бо вони свідомо
        відрізняються від UI-пресетів (сам UI-preset лишається без змін):

          * правило власника: дефолти нової інсталяції дорівнюють
            дефолтам конфігурації, крім вимикачів напрямків. Тому профілі
            з SFTP НЕ пишуть BAZA-прапорців: BAZA_*_SFTP лишаються на
            конфігураційних дефолтах (BAZA_WWW_SFTP за замовчуванням
            $false і вмикається свідомо для конкретного сервера), тоді як
            UI-пресети LocalPlusSFTP/LocalPlusSFTPAndSMB вмикають
            BAZA_APP_SFTP/BAZA_WWW_SFTP;
          * профілі з Samba пишуть componentSettings.SMB.ArchiveCopy =
            $true. Дефолт ArchiveCopy — $false, а SMB.Enabled сам по собі
            нічого не копіює (Get-BRAVOEffectiveStorageConfiguration:
            ArchiveCopy = Enabled AND child), тож профіль «Samba» без
            цього прапорця мовчки не давав би жодної копії на NAS;
          * профілі без SFTP (SambaOnly, LocalOnly) пишуть
            BAZA_APP_LOCAL/BAZA_WWW_LOCAL = $true: BAZA-over-SMB transport
            не існує, а BAZA_*_SFTP при вимкненому SFTP ефективно вимкнені,
            тож без локальної синхронізації BAZA лишилась би без жодної
            копії.

        PresetName — довідкова відповідність UI-пресету для повідомлень,
        а не джерело значень.
    .OUTPUTS
        [pscustomobject] { Destination; PresetName; Label; Overrides }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Cloud', 'CloudAndSamba', 'SambaOnly', 'LocalOnly')]
        [string]$Destination
    )

    $presetName = $null
    $label = $null
    $overrides = [ordered]@{}
    switch ($Destination) {
        'Cloud' {
            $presetName = 'LocalPlusSFTP'
            $label = 'Хмара (SFTP)'
            $overrides['componentSettings.SFTP.Enabled'] = $true
            $overrides['componentSettings.SMB.Enabled'] = $false
        }
        'CloudAndSamba' {
            $presetName = 'LocalPlusSFTPAndSMB'
            $label = 'Хмара (SFTP) + Samba (NAS/SMB)'
            $overrides['componentSettings.SFTP.Enabled'] = $true
            $overrides['componentSettings.SMB.Enabled'] = $true
            $overrides['componentSettings.SMB.ArchiveCopy'] = $true
        }
        'SambaOnly' {
            $presetName = 'LocalPlusSMB'
            $label = 'Лише Samba (NAS/SMB)'
            $overrides['componentSettings.SFTP.Enabled'] = $false
            $overrides['componentSettings.SMB.Enabled'] = $true
            $overrides['componentSettings.SMB.ArchiveCopy'] = $true
            $overrides['componentSettings.Synchronization.BAZA_APP_LOCAL'] = $true
            $overrides['componentSettings.Synchronization.BAZA_WWW_LOCAL'] = $true
        }
        'LocalOnly' {
            $presetName = 'LocalOnly'
            $label = 'Лише локально'
            $overrides['componentSettings.SFTP.Enabled'] = $false
            $overrides['componentSettings.SMB.Enabled'] = $false
            $overrides['componentSettings.Synchronization.BAZA_APP_LOCAL'] = $true
            $overrides['componentSettings.Synchronization.BAZA_WWW_LOCAL'] = $true
        }
    }

    return [pscustomobject]@{
        Destination = $Destination
        PresetName = $presetName
        Label = $label
        Overrides = $overrides
    }
}

function Test-BRAVOConfiguratorBackupDestinationEffective {
    <#
    .SYNOPSIS
        Чиста функція: чи ЕФЕКТИВНІ вимикачі напрямків відповідають
        профілю -BackupDestination (#434).
    .DESCRIPTION
        Рішення ухвалюється за ефективними значеннями, а не за текстом
        BRAVO.local.config: викликач передає результат канонічного
        Get-BRAVOEffectiveStorageConfiguration (BRAVO.Discovery), обчислений
        над Resolve-BRAVORawConfiguration (дефолти < BRAVO.local.config).
        Порівнюються головні вимикачі componentSettings.SFTP.Enabled і
        componentSettings.SMB.Enabled з набору профілю
        Get-BRAVOConfiguratorBackupDestinationProfile, а для SMB ще й
        ефективна копія архіву на NAS (SMB.ArchiveCopy). Очікувана копія
        дорівнює тому, що дав би свіжий seed профілю: SMB.Enabled профілю
        AND componentSettings.SMB.ArchiveCopy профілю (відсутній ключ —
        дефолт $false), тобто те саме правило, що в
        Get-BRAVOEffectiveStorageConfiguration. Для SFTP так само
        порівнюється ефективне вивантаження архіву (SFTP.ArchiveUpload):
        очікуване = SFTP.Enabled профілю AND componentSettings.SFTP.ArchiveUpload
        профілю, а коли профіль його не пише — дефолт
        Get-BRAVODefaultConfiguration (BRAVO.Configuration з того самого
        комплекту), бо саме його дав би свіжий seed. Для профілів без SFTP
        (SambaOnly, LocalOnly) очікуване вивантаження — $false, а ефективне
        за вимкненого SFTP теж $false, тож окремої відмови воно не дає.
        Профіль «в силі» лише тоді, коли збігаються всі чотири значення. Для
        LocalOnly це означає: SFTP і SMB ефективно вимкнені.

        -EffectiveSynchronization (опційно) — результат канонічного
        Get-BRAVOEffectiveSynchronizationConfiguration над тими самими злитими
        componentSettings.Synchronization (-GlobalSftpEnabled = ефективний
        SFTP.Enabled). Для профілів, що пишуть BAZA_*_LOCAL (SambaOnly,
        LocalOnly), Components[BAZA_APP|BAZA_WWW].LocalEnabled має дорівнювати
        значенню профілю: інакше BAZA лишилась би без жодного каналу копії
        (BAZA-over-SMB немає, SFTP вимкнено). Розбіжність дає конфлікт каналу
        'BAZA'. Без параметра BAZA не перевіряється (поведінка до #434 P1).

        Функція нічого не читає й не пише; відповідь — лише висновок і
        причини українською для діагностики викликача.
    .OUTPUTS
        [pscustomobject] { Destination; Compliant; ConflictingChannels; Reasons }
        ConflictingChannels — 'SFTP'/'SMB'/'BAZA', чий ефективний стан суперечить профілю.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Cloud', 'CloudAndSamba', 'SambaOnly', 'LocalOnly')]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $EffectiveStorage,

        [AllowNull()]
        $EffectiveSynchronization = $null
    )

    $destinationProfile = Get-BRAVOConfiguratorBackupDestinationProfile -Destination $Destination
    $conflicting = New-Object System.Collections.Generic.List[string]
    $reasons = New-Object System.Collections.Generic.List[string]
    if ($null -eq $EffectiveStorage) {
        [void]$reasons.Add('ефективні значення напрямків не обчислено — відповідність профілю ' + $Destination + ' не підтверджено.')
        return [pscustomobject]@{
            Destination = $Destination
            Compliant = $false
            ConflictingChannels = @()
            Reasons = @($reasons)
        }
    }

    foreach ($channel in @('SFTP', 'SMB')) {
        $expected = [bool]$destinationProfile.Overrides['componentSettings.' + $channel + '.Enabled']
        $channelNode = $EffectiveStorage.$channel
        $actual = $false
        if ($null -ne $channelNode) { $actual = [bool]$channelNode.Enabled }
        $channelConflict = $false
        if ($actual -ne $expected) {
            $channelConflict = $true
            $expectedText = $(if ($expected) { 'увімкнено' } else { 'вимкнено' })
            $actualText = $(if ($actual) { 'увімкнено' } else { 'вимкнено' })
            [void]$reasons.Add($channel + ': ефективно ' + $actualText + ', профіль ' + $Destination +
                ' вимагає «' + $expectedText + '» (componentSettings.' + $channel + '.Enabled = ' +
                $(if ($expected) { '$true' } else { '$false' }) + ').')
        }
        if ($channel -eq 'SFTP' -and $expected -and -not $channelConflict) {
            # Вивантаження архіву: SFTP.Enabled сам по собі архів у хмару не
            # відправляє, тож профіль із хмарою без ефективного ArchiveUpload
            # не «в силі». Профілі без SFTP сюди не доходять ($expected = $false).
            $expectedUploadRaw = $null
            if ($destinationProfile.Overrides.Contains('componentSettings.SFTP.ArchiveUpload')) {
                $expectedUploadRaw = $destinationProfile.Overrides['componentSettings.SFTP.ArchiveUpload']
            } else {
                Import-Module -Name (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'BRAVO.Configuration\BRAVO.Configuration.psd1') -ErrorAction Stop
                $defaultSftp = (Get-BRAVODefaultConfiguration)['componentSettings']['SFTP']
                if ($defaultSftp -is [System.Collections.IDictionary] -and $defaultSftp.Contains('ArchiveUpload')) {
                    $expectedUploadRaw = $defaultSftp['ArchiveUpload']
                }
            }
            # Те саме тлумачення значення, що в Get-BRAVOEffectiveStorageConfiguration:
            # відсутнє чи нерозпізнане = $false.
            $expectedUpload = $false
            if ($null -ne $expectedUploadRaw) {
                try { $expectedUpload = [System.Convert]::ToBoolean($expectedUploadRaw) } catch { $expectedUpload = $false }
            }
            $actualUpload = $false
            if ($channelNode -is [System.Collections.IDictionary]) {
                if ($channelNode.Contains('ArchiveUpload')) { $actualUpload = [bool]$channelNode['ArchiveUpload'] }
            } elseif ($null -ne $channelNode -and $null -ne $channelNode.PSObject.Properties['ArchiveUpload']) {
                $actualUpload = [bool]$channelNode.ArchiveUpload
            }
            if ($actualUpload -ne $expectedUpload) {
                $channelConflict = $true
                $expectedUploadText = $(if ($expectedUpload) { 'увімкнено' } else { 'вимкнено' })
                $actualUploadText = $(if ($actualUpload) { 'увімкнено' } else { 'вимкнено' })
                [void]$reasons.Add('SFTP: вивантаження архіву ефективно ' + $actualUploadText + ', профіль ' + $Destination +
                    ' вимагає «' + $expectedUploadText + '» (componentSettings.SFTP.ArchiveUpload = ' +
                    $(if ($expectedUpload) { '$true' } else { '$false' }) + ' при componentSettings.SFTP.Enabled = $true).')
            }
        }
        if ($channel -eq 'SMB') {
            # Копія на NAS: SMB.Enabled сам по собі нічого не копіює, тож
            # профіль із Samba без ефективного ArchiveCopy не «в силі».
            $expectedCopy = $expected -and [bool]$destinationProfile.Overrides['componentSettings.SMB.ArchiveCopy']
            $actualCopy = $false
            if ($channelNode -is [System.Collections.IDictionary]) {
                if ($channelNode.Contains('ArchiveCopy')) { $actualCopy = [bool]$channelNode['ArchiveCopy'] }
            } elseif ($null -ne $channelNode -and $null -ne $channelNode.PSObject.Properties['ArchiveCopy']) {
                $actualCopy = [bool]$channelNode.ArchiveCopy
            }
            if ($actualCopy -ne $expectedCopy) {
                $channelConflict = $true
                $expectedCopyText = $(if ($expectedCopy) { 'увімкнено' } else { 'вимкнено' })
                $actualCopyText = $(if ($actualCopy) { 'увімкнено' } else { 'вимкнено' })
                [void]$reasons.Add('SMB: копія архіву на NAS ефективно ' + $actualCopyText + ', профіль ' + $Destination +
                    ' вимагає «' + $expectedCopyText + '» (componentSettings.SMB.ArchiveCopy = ' +
                    $(if ($expectedCopy) { '$true' } else { '$false' }) + ' при componentSettings.SMB.Enabled = ' +
                    $(if ($expected) { '$true' } else { '$false' }) + ').')
            }
        }
        if ($channelConflict) { [void]$conflicting.Add($channel) }
    }

    if ($null -ne $EffectiveSynchronization) {
        # BAZA для профілів без SFTP (#434, Codex Security P1): єдиний канал
        # копії — локальна синхронізація BAZA_*_LOCAL. Відсутній компонент чи
        # Components — ефективно вимкнено (fail closed).
        $bazaConflict = $false
        $syncComponents = @()
        if ($null -ne $EffectiveSynchronization.PSObject.Properties['Components']) {
            $syncComponents = @($EffectiveSynchronization.Components)
        }
        foreach ($componentName in @('BAZA_APP', 'BAZA_WWW')) {
            $profileKey = 'componentSettings.Synchronization.' + $componentName + '_LOCAL'
            if (-not $destinationProfile.Overrides.Contains($profileKey)) { continue }
            $expectedLocal = [bool]$destinationProfile.Overrides[$profileKey]
            $actualLocal = $false
            foreach ($syncComponent in $syncComponents) {
                if ($null -ne $syncComponent -and $null -ne $syncComponent.PSObject.Properties['Name'] -and
                    [string]$syncComponent.Name -eq $componentName -and $null -ne $syncComponent.PSObject.Properties['LocalEnabled']) {
                    $actualLocal = [bool]$syncComponent.LocalEnabled
                }
            }
            if ($actualLocal -ne $expectedLocal) {
                $bazaConflict = $true
                $expectedLocalText = $(if ($expectedLocal) { 'увімкнено' } else { 'вимкнено' })
                $actualLocalText = $(if ($actualLocal) { 'увімкнено' } else { 'вимкнено' })
                [void]$reasons.Add('BAZA: локальна синхронізація ' + $componentName + ' ефективно ' + $actualLocalText +
                    ', профіль ' + $Destination + ' вимагає «' + $expectedLocalText + '» (' + $profileKey + ' = ' +
                    $(if ($expectedLocal) { '$true' } else { '$false' }) + '): без SFTP це єдиний канал копії BAZA.')
            }
        }
        if ($bazaConflict) { [void]$conflicting.Add('BAZA') }
    }

    return [pscustomobject]@{
        Destination = $Destination
        Compliant = ($conflicting.Count -eq 0)
        ConflictingChannels = @($conflicting)
        Reasons = @($reasons)
    }
}

Export-ModuleMember -Function @(
    'Get-BRAVOConfiguratorPresetCatalog',
    'Invoke-BRAVOConfiguratorPreset',
    'Get-BRAVOConfiguratorPresetOverrideSet',
    'Get-BRAVOConfiguratorBackupDestinationProfile',
    'Test-BRAVOConfiguratorBackupDestinationEffective'
)
