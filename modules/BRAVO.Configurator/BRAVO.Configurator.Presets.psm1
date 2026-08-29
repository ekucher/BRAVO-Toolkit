# BRAVO.Configurator.Presets — топологічні пресети як чисті model-
# трансформації. Жоден preset НЕ пише файл — лише повертає новий Model[]
# (той самий Set/Clear-BRAVOConfiguratorOverride контракт, що ручне
# редагування в UI), і UI/Persistence відповідає за подальший
# Update-BRAVOConfiguratorEffective/Invoke-BRAVOConfiguratorValidation/
# Invoke-BRAVOConfiguratorApply — так само, як для будь-якої іншої зміни.
#
# Master-switch semantics (P1.6): preset торкається ЛИШЕ двох шляхів
# (componentSettings.SFTP.Enabled/SMB.Enabled) — ніколи дочірніх
# прапорців (ArchiveUpload/ArchiveCopy/BAZA_*_SFTP). Це узгоджується з
# canonical дизайном 5.2.2: master НІКОЛИ не мутує дочірні прапорці;
# вимикання/вмикання SFTP чи SMB через preset — лише перемикання master,
# а не "стирання" чи "відновлення" child-налаштувань, які лишаються
# незмінними й самі керують ефективною поведінкою, коли master дозволяє.

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
        [pscustomobject]@{ Name = 'LocalOnly'; Label = 'Тільки локально'; Description = 'SFTP і SMB вимкнено глобально (обидва master-switches = $false) — валідна production-конфігурація.' }
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
        override — детермінована операція, не накопичувальна). Preset
        торкається ЛИШЕ componentSettings.SFTP.Enabled/SMB.Enabled —
        жоден інший override у моделі не змінюється й не видаляється.
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
    return $updated
}

Export-ModuleMember -Function @(
    'Get-BRAVOConfiguratorPresetCatalog',
    'Invoke-BRAVOConfiguratorPreset'
)
