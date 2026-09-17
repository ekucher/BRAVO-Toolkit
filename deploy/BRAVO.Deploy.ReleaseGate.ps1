# Канонічна політика гейта релізу для скриптів розкатки з deploy/.
#
# ЧОМУ ОКРЕМИЙ ФАЙЛ, А НЕ КОПІЯ В КОЖНОМУ СКРИПТІ. Install-BRAVOServer.ps1 і
# Update-BRAVOServer.ps1 ухвалюють ОДНЕ І ТЕ САМЕ рішення: чи можна розгортати
# цей артефакт у production. Дві незалежні копії такої політики розійшлися б
# саме там, де ціна розбіжності найвища, і це прямо заборонено
# .claude/rules/05-architecture.md («Політика дублікації»). Тому рішення живе
# тут в одному екземплярі, а скрипти лишаються оркестраторами.
#
# ЧОМУ ФУНКЦІЇ ПОВЕРТАЮТЬ ОБ'ЄКТ, А НЕ ДРУКУЮТЬ. Обидва скрипти мають власні
# Write-Ok/Write-Warn2/Write-Bad з однаковим форматом рядка. Якби гейт друкував
# сам, він або залежав би від функцій викликача (неявний контракт, який
# Set-StrictMode не ловить), або завів би третю копію писача. Натомість гейт
# будує КАНОНІЧНИЙ текст повідомлення й рівень, а викликач лише обирає writer —
# політика лишається в одному місці, презентація лишається за entrypoint-ом.
#
# ЦІНА: скрипт розкатки більше не є одним самодостатнім файлом — поруч має
# лежати цей. Це свідомий вибір: відсутність файлу політики зупиняє розкатку з
# явним повідомленням (fail-closed), а не тихо знімає гейт. Обидва файли
# входять у RUNTIME_MANIFEST.json, тож їхня цілісність перевіряється разом.

Set-StrictMode -Version 2.0

# Єдине місце, де записано, який канал вважається придатним для production.
$script:BRAVODeployProductionChannel = 'stable'

function Get-BRAVODeployMetadataValue {
    # Set-StrictMode 2.0 кидає на звернення до неіснуючої властивості, а
    # VERSION.json старішого комплекту може не мати поля взагалі. Одне місце
    # читання — одна семантика "немає значення" ($null), без розсипаних
    # PSObject.Properties по всьому гейту.
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Source,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Source) { return $null }
    if ($Source -is [System.Collections.IDictionary]) {
        if ($Source.Contains($Name)) { return $Source[$Name] }
        return $null
    }
    if ($null -eq $Source.PSObject -or $null -eq $Source.PSObject.Properties[$Name]) { return $null }
    return $Source.PSObject.Properties[$Name].Value
}

function Get-BRAVODeployReleaseChannelDecision {
    <#
        Рішення про канал релізу.

        КОНТРАКТ (fail-closed за замовчуванням):
            releaseChannel = 'stable'          -> дозволено
            будь-який інший, без override      -> ЗАБОРОНЕНО
            будь-який інший, з override        -> дозволено, гучний запис
            releaseChannel відсутній/порожній  -> ЗАБОРОНЕНО (невідомий канал
                                                  не є доказом стабільності)

        Попередня поведінка (Install лише попереджав, Update не перевіряв
        узагалі) призвела до того, що сервер парку тривало працював у production на
        5.2.0-rc.2 — версії, тега якої не існує.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$VersionMetadata,
        [switch]$AllowPrereleaseChannel
    )

    $channelValue = Get-BRAVODeployMetadataValue -Source $VersionMetadata -Name 'releaseChannel'
    $channel = if ($null -eq $channelValue) { '' } else { [string]$channelValue }

    if ($channel -eq $script:BRAVODeployProductionChannel) {
        return [pscustomobject]@{
            Allowed      = $true
            Channel      = $channel
            Severity     = 'Ok'
            OverrideUsed = $false
            Message      = ('канал релізу "{0}" — придатний для production' -f $channel)
        }
    }

    $shownChannel = if ([string]::IsNullOrWhiteSpace($channel)) { '(не вказано)' } else { $channel }

    if ($AllowPrereleaseChannel) {
        return [pscustomobject]@{
            Allowed      = $true
            Channel      = $channel
            Severity     = 'Warning'
            OverrideUsed = $true
            Message      = ('НЕ-STABLE КАНАЛ "{0}" РОЗГОРТАЄТЬСЯ ЗА ЯВНИМ РІШЕННЯМ ОПЕРАТОРА ' -f $shownChannel) +
                           '(-AllowPrereleaseChannel). Цей комплект не є stable-релізом: точного тега для ' +
                           'нього може не існувати, і жодна acceptance-процедура до нього не прив''язана. ' +
                           'Зафіксуйте це рішення в журналі розкатки.'
        }
    }

    return [pscustomobject]@{
        Allowed      = $false
        Channel      = $channel
        Severity     = 'Error'
        OverrideUsed = $false
        Message      = ('канал релізу "{0}", а не "{1}" — розгортання зупинено. ' -f $shownChannel, $script:BRAVODeployProductionChannel) +
                       'У production розгортається stable-реліз. Якщо це свідоме рішення (пілот, ' +
                       'перевірка виправлення), повторіть запуск із -AllowPrereleaseChannel і ' +
                       'зафіксуйте рішення в журналі розкатки.'
    }
}

function Get-BRAVODeployProvenanceVerdict {
    <#
        Перевірка провенансу артефакту, а не його друк.

        ДЖЕРЕЛО ІСТИНИ — release-manifest.json, який публікується ОКРЕМИМ
        ассетом релізу поруч із zip. Доти розкатка звіряла VERSION.json лише
        сам із собою: файл усередині архіву підтверджував архів, у якому лежав.

        Без маніфесту (локальний zip, реліз до появи маніфесту) лишаються
        внутрішні інваріанти, які накладає сам збирач артефакту
        (ci/New-BRAVOReleaseArtifact.ps1): sourceCommit — повний 40-символьний
        git-hash, buildId — його перші 7 символів. Їх порушення означає, що
        комплект зібраний не релізним конвеєром.

        Відсутність маніфесту — ПОПЕРЕДЖЕННЯ, не відмова: інакше оновлення з
        локального архіву (документований і робочий сценарій -ZipPath) зламалось
        би на серверах без доступу до GitHub.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$VersionMetadata,
        [AllowNull()]$ReleaseManifest = $null,
        [string]$ArtifactSha256 = '',
        [string]$ExpectedTag = ''
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $checks = New-Object System.Collections.Generic.List[string]

    $sourceCommitValue = Get-BRAVODeployMetadataValue -Source $VersionMetadata -Name 'sourceCommit'
    $buildIdValue = Get-BRAVODeployMetadataValue -Source $VersionMetadata -Name 'buildId'
    $packageVersionValue = Get-BRAVODeployMetadataValue -Source $VersionMetadata -Name 'packageVersion'
    $channelValue = Get-BRAVODeployMetadataValue -Source $VersionMetadata -Name 'releaseChannel'

    $sourceCommit = if ($null -eq $sourceCommitValue) { '' } else { ([string]$sourceCommitValue).Trim() }
    $buildId = if ($null -eq $buildIdValue) { '' } else { ([string]$buildIdValue).Trim() }
    $packageVersion = if ($null -eq $packageVersionValue) { '' } else { ([string]$packageVersionValue).Trim() }
    $channel = if ($null -eq $channelValue) { '' } else { ([string]$channelValue).Trim() }

    # --- Інваріанти, які накладає сам збирач артефакту -----------------------
    if ($sourceCommit -notmatch '^[0-9a-f]{40}$') {
        [void]$problems.Add(('VERSION.json.sourceCommit ("{0}") не є повним 40-символьним git-hash' -f $sourceCommit))
    } else {
        [void]$checks.Add('sourceCommit — повний git-hash')
        if ($buildId -ne $sourceCommit.Substring(0, 7)) {
            [void]$problems.Add(('VERSION.json.buildId ("{0}") не дорівнює short(sourceCommit) ("{1}")' -f
                $buildId, $sourceCommit.Substring(0, 7)))
        } else {
            [void]$checks.Add('buildId = short(sourceCommit)')
        }
    }

    # --- Звірка з незалежним release-manifest.json --------------------------
    if ($null -eq $ReleaseManifest) {
        $message = 'release-manifest.json недоступний — провенанс підтверджено лише самим комплектом ' +
                   '(sourceCommit/buildId), без незалежного джерела. Для stable-розкатки покладіть ' +
                   'release-manifest.json поруч з архівом.'
        if ($problems.Count -gt 0) {
            return [pscustomobject]@{
                IsValid  = $false
                Severity = 'Error'
                Checks   = $checks.ToArray()
                Problems = $problems.ToArray()
                Message  = ('провенанс відхилено: ' + [string]::Join('; ', $problems.ToArray()))
            }
        }
        return [pscustomobject]@{
            IsValid  = $true
            Severity = 'Warning'
            Checks   = $checks.ToArray()
            Problems = @()
            Message  = $message
        }
    }

    $manifestPairs = @(
        @{ Name = 'packageVersion'; Expected = $packageVersion },
        @{ Name = 'sourceCommit';   Expected = $sourceCommit },
        @{ Name = 'buildId';        Expected = $buildId },
        @{ Name = 'releaseChannel'; Expected = $channel }
    )
    foreach ($pair in $manifestPairs) {
        $manifestValueRaw = Get-BRAVODeployMetadataValue -Source $ReleaseManifest -Name $pair.Name
        $manifestValue = if ($null -eq $manifestValueRaw) { '' } else { ([string]$manifestValueRaw).Trim() }
        if ($manifestValue -ne [string]$pair.Expected) {
            [void]$problems.Add(('release-manifest.json.{0} ("{1}") не збігається з VERSION.json ("{2}")' -f
                $pair.Name, $manifestValue, [string]$pair.Expected))
        } else {
            [void]$checks.Add(('{0} збігається з release-manifest.json' -f $pair.Name))
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ArtifactSha256)) {
        $artifactNode = Get-BRAVODeployMetadataValue -Source $ReleaseManifest -Name 'artifact'
        $manifestShaRaw = Get-BRAVODeployMetadataValue -Source $artifactNode -Name 'sha256'
        $manifestSha = if ($null -eq $manifestShaRaw) { '' } else { ([string]$manifestShaRaw).Trim().ToLowerInvariant() }
        $actualSha = $ArtifactSha256.Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($manifestSha)) {
            [void]$problems.Add('release-manifest.json не містить artifact.sha256')
        } elseif ($manifestSha -ne $actualSha) {
            [void]$problems.Add(('release-manifest.json.artifact.sha256 ("{0}") не збігається з фактичним хешем архіву ("{1}")' -f
                $manifestSha, $actualSha))
        } else {
            [void]$checks.Add('SHA-256 архіву збігається з release-manifest.json')
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedTag)) {
        $manifestTagRaw = Get-BRAVODeployMetadataValue -Source $ReleaseManifest -Name 'tag'
        $manifestTag = if ($null -eq $manifestTagRaw) { '' } else { ([string]$manifestTagRaw).Trim() }
        # Порожній tag означає ручний прогін workflow не по тегу: такий артефакт
        # до Release не прикріплюється, тож у розкатці його бути не повинно.
        if ([string]::IsNullOrWhiteSpace($manifestTag)) {
            [void]$problems.Add(('release-manifest.json не містить tag — артефакт зібрано не з тега (очікувався "{0}")' -f $ExpectedTag))
        } elseif ($manifestTag -ne $ExpectedTag) {
            [void]$problems.Add(('release-manifest.json.tag ("{0}") не збігається з запитаним тегом ("{1}")' -f
                $manifestTag, $ExpectedTag))
        } else {
            [void]$checks.Add('tag збігається з release-manifest.json')
        }
    }

    if ($problems.Count -gt 0) {
        return [pscustomobject]@{
            IsValid  = $false
            Severity = 'Error'
            Checks   = $checks.ToArray()
            Problems = $problems.ToArray()
            Message  = ('провенанс відхилено: ' + [string]::Join('; ', $problems.ToArray()))
        }
    }

    return [pscustomobject]@{
        IsValid  = $true
        Severity = 'Ok'
        Checks   = $checks.ToArray()
        Problems = @()
        Message  = ('провенанс підтверджено незалежним release-manifest.json ({0})' -f
                    [string]::Join(', ', $checks.ToArray()))
    }
}
