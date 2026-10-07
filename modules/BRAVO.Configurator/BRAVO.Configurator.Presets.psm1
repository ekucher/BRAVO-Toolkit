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

Export-ModuleMember -Function @(
    'Get-BRAVOConfiguratorPresetCatalog',
    'Invoke-BRAVOConfiguratorPreset',
    'Get-BRAVOConfiguratorPresetOverrideSet',
    'Get-BRAVOConfiguratorBackupDestinationProfile'
)
