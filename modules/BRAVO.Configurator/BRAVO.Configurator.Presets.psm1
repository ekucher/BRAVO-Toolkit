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

    $sftpEnabled = $null
    $smbEnabled = $null
    switch ($PresetName) {
        'LocalOnly'            { $sftpEnabled = $false; $smbEnabled = $false }
        'LocalPlusSMB'         { $sftpEnabled = $false; $smbEnabled = $true }
        'LocalPlusSFTP'        { $sftpEnabled = $true;  $smbEnabled = $false }
        'LocalPlusSFTPAndSMB'  { $sftpEnabled = $true;  $smbEnabled = $true }
        'Current'              { return $Model }
        'Manual'               { return $Model }
    }

    $updated = Set-BRAVOConfiguratorOverride -Model $Model -Path 'componentSettings.SFTP.Enabled' -Value $sftpEnabled
    $updated = Set-BRAVOConfiguratorOverride -Model $updated -Path 'componentSettings.SMB.Enabled' -Value $smbEnabled

    # feat/bravo-configurator-preset-baza-local: 3 з 4 нетривіальних
    # пресетів (крім LocalPlusSMB — див. докстрінг вище щодо відсутності
    # BAZA-over-SMB transport) додатково виставляють явні BAZA-override,
    # узгоджені з обраною топологією синхронізації.
    switch ($PresetName) {
        'LocalOnly' {
            $updated = Set-BRAVOConfiguratorOverride -Model $updated -Path 'componentSettings.Synchronization.BAZA_APP_LOCAL' -Value $true
            $updated = Set-BRAVOConfiguratorOverride -Model $updated -Path 'componentSettings.Synchronization.BAZA_WWW_LOCAL' -Value $true
        }
        { $_ -in @('LocalPlusSFTP', 'LocalPlusSFTPAndSMB') } {
            $updated = Set-BRAVOConfiguratorOverride -Model $updated -Path 'componentSettings.Synchronization.BAZA_APP_LOCAL' -Value $false
            $updated = Set-BRAVOConfiguratorOverride -Model $updated -Path 'componentSettings.Synchronization.BAZA_APP_SFTP' -Value $true
            $updated = Set-BRAVOConfiguratorOverride -Model $updated -Path 'componentSettings.Synchronization.BAZA_WWW_LOCAL' -Value $false
            $updated = Set-BRAVOConfiguratorOverride -Model $updated -Path 'componentSettings.Synchronization.BAZA_WWW_SFTP' -Value $true
        }
    }

    return $updated
}

Export-ModuleMember -Function @(
    'Get-BRAVOConfiguratorPresetCatalog',
    'Invoke-BRAVOConfiguratorPreset'
)
