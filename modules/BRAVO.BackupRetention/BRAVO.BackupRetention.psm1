# BRAVO.BackupRetention - симуляція календарного retention Д/Т/М/Р (#381).
#
# ЛИШЕ ПЛАНУВАННЯ. Жодна функція цього модуля нічого не видаляє, не пише і
# не підключена до Remove-BRAVOExpiredBackupGenerations: це чиста модель
# "що БУЛО БИ видалено" для рішення власника. Автоматичне видалення за цією
# схемою вимагає окремого рішення власника (кількості Д/Т/М/Р і значення за
# замовчуванням ще не визначені) та окремої реалізації. enableArchiveDeletion
# лишається $false за замовчуванням.
#
# Залежність: BRAVO.BackupRetention -> BRAVO.ArchiveHelpers (читання
# manifest-ів generation). Зворотної залежності немає.
#
# Семантика (пропозиція для рішення власника, не діюча політика):
#  - у "кошики" потрапляють ЛИШЕ generation із записаним статусом COMPLETE.
#    Інші відомі статуси (INCOMPLETE, FAILED) -> Keep з причиною NotComplete:
#    симуляція їх ніколи не пропонує до видалення (їх обробляє окрема гілка
#    failedArchiveRetentionDays у production);
#  - кошик - календарна доба, ISO-тиждень (пн-нд, рік за четвергом),
#    календарний місяць, календарний рік за локальною датою generation;
#  - представник кошика - найновіша COMPLETE-generation кошика (рівний час -
#    більший GenerationId, порядкове порівняння);
#  - кількість N = N найновіших кошиків, що МАЮТЬ хоча б одну COMPLETE;
#  - AllCopiesDays - вікно, у якому лишаються ВСІ COMPLETE-копії (різниця
#    календарних діб до Now менша за AllCopiesDays; 0 = вікна немає);
#  - MinimumRetainedCount - N найновіших COMPLETE-generation не видаляються
#    (причина MinimumRetained); найновіша COMPLETE завжди захищена
#    (LastRecoverable), найновіша generation взагалі - теж (Newest);
#  - невідомий/відсутній статус, нерозбірливі id/дата, дата в майбутньому і
#    дубльований id -> Keep з позначкою;
#  - будь-яка нерозбірлива кількість -> NotConfigured, жодного WouldDelete.
#  - ВІДНОВЛЮВАНІСТЬ береться лише із записаного статусу manifest-а; архіви
#    і hash-файли симуляція НЕ перевіряє.

Set-StrictMode -Version 2.0

$archiveHelpersManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'BRAVO.ArchiveHelpers\BRAVO.ArchiveHelpers.psd1'
Import-Module -Name $archiveHelpersManifest -ErrorAction Stop

$script:BRAVORetentionPolicyKeyMap = [ordered]@{
    DailyCount    = 'retentionDailyCount'
    WeeklyCount   = 'retentionWeeklyCount'
    MonthlyCount  = 'retentionMonthlyCount'
    YearlyCount   = 'retentionYearlyCount'
    AllCopiesDays = 'retentionAllCopiesDays'
}
$script:BRAVORetentionMinimumRetainedKey = 'minimumRetainedVerifiedBackups'
$script:BRAVORetentionMaximumValue = 3650

function ConvertTo-BRAVORetentionNonNegativeInteger {
    # $null -> $null ("не налаштовано"). Усе інше мусить бути цілим
    # невід'ємним числом без лапок у межах 0..3650; bool, рядок і дробове
    # значення відхиляються з назвою ключа конфігурації.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowNull()]$Value
    )

    if ($null -eq $Value) { return $null }
    $typeCode = [string][System.Type]::GetTypeCode($Value.GetType())
    if (@('SByte', 'Byte', 'Int16', 'UInt16', 'Int32', 'UInt32', 'Int64', 'UInt64') -notcontains $typeCode) {
        throw "Retention: ключ '$Key' має бути цілим невід'ємним числом без лапок (0..$($script:BRAVORetentionMaximumValue)) або `$null (не налаштовано); отримано $($Value.GetType().Name) '$Value'."
    }
    if ([decimal]$Value -lt 0 -or [decimal]$Value -gt $script:BRAVORetentionMaximumValue) {
        throw "Retention: ключ '$Key' поза діапазоном 0..$($script:BRAVORetentionMaximumValue): '$Value'."
    }
    return [int]$Value
}

function Read-BRAVORetentionPolicyField {
    # Значення поля з hashtable або об'єкта; відсутнє поле == $null.
    [CmdletBinding()]
    param([AllowNull()]$Source, [Parameter(Mandatory = $true)][string]$Name)

    if ($null -eq $Source) { return $null }
    if ($Source -is [System.Collections.IDictionary]) {
        if ($Source.Contains($Name)) { return $Source[$Name] }
        return $null
    }
    $property = $Source.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function ConvertTo-BRAVOBackupRetentionPolicy {
    # Канонічний нормалізатор політики (приватний). Приймає hashtable або
    # об'єкт з DailyCount/WeeklyCount/MonthlyCount/YearlyCount/AllCopiesDays
    # (+ необов'язковим MinimumRetainedCount) і повертає нормалізований
    # об'єкт. Невалідне значення - виняток з назвою ключа конфігурації.
    [CmdletBinding()]
    param([AllowNull()]$Policy)

    $result = [ordered]@{}
    $missingKeys = New-Object System.Collections.Generic.List[string]
    foreach ($propertyName in @($script:BRAVORetentionPolicyKeyMap.Keys)) {
        $configKey = [string]$script:BRAVORetentionPolicyKeyMap[$propertyName]
        $raw = Read-BRAVORetentionPolicyField -Source $Policy -Name $propertyName
        $normalized = ConvertTo-BRAVORetentionNonNegativeInteger -Key $configKey -Value $raw
        $result[$propertyName] = $normalized
        if ($null -eq $normalized) { [void]$missingKeys.Add($configKey) }
    }
    $result['MinimumRetainedCount'] = ConvertTo-BRAVORetentionNonNegativeInteger `
        -Key $script:BRAVORetentionMinimumRetainedKey `
        -Value (Read-BRAVORetentionPolicyField -Source $Policy -Name 'MinimumRetainedCount')
    $result['IsConfigured'] = ($missingKeys.Count -eq 0)
    $result['MissingKeys'] = $missingKeys.ToArray()
    return [pscustomobject]$result
}

function Get-BRAVOBackupRetentionPolicy {
    # Читає ключі retention* та minimumRetainedVerifiedBackups. З явним
    # -Configuration відсутній ключ (legacy-конфіг, StrictMode) == $null ==
    # "не налаштовано". Без -Configuration конфігурацію мусив завантажити
    # канонічний завантажувач (маркер $global:BravoConfigurationMetadata);
    # інакше - fail closed, а не мовчазні $null.
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Configuration)

    $useGlobals = -not ($PSBoundParameters.ContainsKey('Configuration') -and $null -ne $Configuration)
    if ($useGlobals -and $null -eq (Get-Variable -Name 'BravoConfigurationMetadata' -Scope Global -ErrorAction SilentlyContinue)) {
        throw "Retention: конфігурація не завантажена (відсутній маркер завантажувача BravoConfigurationMetadata). Завантажте її через Import-BravoConfiguration (BRAVO_CONFIG_LOADER.ps1) або передайте -Configuration."
    }
    $readKey = {
        param([string]$Key)
        if ($useGlobals) {
            $variable = Get-Variable -Name $Key -Scope Global -ErrorAction SilentlyContinue
            if ($null -ne $variable) { return $variable.Value }
            return $null
        }
        if ($Configuration.Contains($Key)) { return $Configuration[$Key] }
        return $null
    }
    $raw = [ordered]@{}
    foreach ($propertyName in @($script:BRAVORetentionPolicyKeyMap.Keys)) {
        $raw[$propertyName] = & $readKey ([string]$script:BRAVORetentionPolicyKeyMap[$propertyName])
    }
    $raw['MinimumRetainedCount'] = & $readKey $script:BRAVORetentionMinimumRetainedKey
    return (ConvertTo-BRAVOBackupRetentionPolicy -Policy $raw)
}

function Get-BRAVORetentionIsoWeekKey {
    # ISO 8601: тиждень пн-нд, належить року свого четверга. Власна
    # реалізація: System.Globalization.ISOWeek недоступний у .NET Framework
    # (Windows PowerShell 5.1).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][datetime]$Date)

    $day = $Date.Date
    $mondayBased = ([int]$day.DayOfWeek + 6) % 7
    $thursday = $day.AddDays(3 - $mondayBased)
    $week = [int][math]::Floor(($thursday.DayOfYear - 1) / 7) + 1
    return ('{0}-W{1:00}' -f $thursday.Year, $week)
}

function Get-BRAVOBackupRetentionPlan {
    # Чиста детермінована функція: файлової системи не торкається, видалення
    # не викликає. Generations - об'єкти з GenerationId, Date ([datetime]) і
    # IsRecordedComplete ([bool]; відсутнє/не-bool значення == невідомий
    # статус -> Keep + UnknownStatus).
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Generations,
        [Parameter(Mandatory = $true)]$Policy,
        [AllowNull()][object]$MinimumRetainedCount = $null,
        [datetime]$Now = (Get-Date)
    )

    $normalizedPolicy = ConvertTo-BRAVOBackupRetentionPolicy -Policy $Policy
    $minimumRetained = 0
    if ($null -ne $MinimumRetainedCount) {
        # Сире значення йде через той самий суворий валідатор, що й поля політики
        # (без неявного приведення рядків, bool і дробових).
        $minimumRetained = [int](ConvertTo-BRAVORetentionNonNegativeInteger -Key 'MinimumRetainedCount' -Value $MinimumRetainedCount)
    } elseif ($null -ne $normalizedPolicy.MinimumRetainedCount) {
        $minimumRetained = [int]$normalizedPolicy.MinimumRetainedCount
    }
    $culture = [Globalization.CultureInfo]::InvariantCulture

    # 1. Класифікація: валідні записи і записи з позначками.
    $idCounts = @{}
    foreach ($candidate in @($Generations)) {
        $candidateId = ''
        if ($null -ne $candidate -and $null -ne $candidate.PSObject.Properties['GenerationId'] -and
            $null -ne $candidate.PSObject.Properties['GenerationId'].Value) {
            $candidateId = [string]$candidate.PSObject.Properties['GenerationId'].Value
        }
        if ($candidateId -ne '') {
            if ($idCounts.ContainsKey($candidateId)) { $idCounts[$candidateId] = [int]$idCounts[$candidateId] + 1 } else { $idCounts[$candidateId] = 1 }
        }
    }
    $valid = New-Object System.Collections.Generic.List[object]
    $flagged = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Generations)) {
        $id = ''
        $when = $null
        $complete = $null
        if ($null -ne $item) {
            $idProperty = $item.PSObject.Properties['GenerationId']
            if ($null -ne $idProperty -and $null -ne $idProperty.Value) { $id = [string]$idProperty.Value }
            $dateProperty = $item.PSObject.Properties['Date']
            if ($null -ne $dateProperty -and $dateProperty.Value -is [datetime]) { $when = [datetime]$dateProperty.Value }
            $completeProperty = $item.PSObject.Properties['IsRecordedComplete']
            if ($null -ne $completeProperty -and $completeProperty.Value -is [bool]) { $complete = [bool]$completeProperty.Value }
        }
        $flags = New-Object System.Collections.Generic.List[string]
        # Канонічний формат GenerationId (yyyyMMdd_HHmmss[_N]) перевіряє той самий
        # helper ArchiveHelpers, що й решта retention: будь-який інший непорожній
        # рядок ('garbage') - теж MalformedIdentity, а не кандидат на видалення.
        $canonicalId = $null
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            $canonicalId = Get-BRAVOBackupManifestFilenameGenerationId -FileName ('BRAVO_BACKUP_{0}.json' -f $id)
        }
        if ($null -eq $canonicalId -or -not [string]::Equals($canonicalId, $id, [StringComparison]::Ordinal)) {
            [void]$flags.Add('MalformedIdentity')
        }
        if ($id -ne '' -and [int]$idCounts[$id] -gt 1) { [void]$flags.Add('DuplicateIdentity') }
        if ($null -eq $when -or $when.Date -le [datetime]::MinValue.Date) { [void]$flags.Add('MalformedDate') }
        elseif ($when -gt $Now) { [void]$flags.Add('FutureDated') }
        if ($null -eq $complete) { [void]$flags.Add('UnknownStatus') }
        $record = [pscustomobject]@{ GenerationId = $id; Date = $when; IsRecordedComplete = $complete; Flags = $flags.ToArray() }
        if ($flags.Count -gt 0) { [void]$flagged.Add($record) } else { [void]$valid.Add($record) }
    }

    # 2. Детермінований порядок: найновіші першими; рівний час - більший
    # GenerationId (порядкове порівняння).
    $valid.Sort([Comparison[object]]{
        param($left, $right)
        $byDate = $right.Date.CompareTo($left.Date)
        if ($byDate -ne 0) { return $byDate }
        return [string]::CompareOrdinal([string]$right.GenerationId, [string]$left.GenerationId)
    })
    $ordered = @($valid.ToArray())
    $completeOrdered = @($ordered | Where-Object { $_.IsRecordedComplete })
    $reasons = @{}
    foreach ($record in $ordered) { $reasons[$record.GenerationId] = New-Object System.Collections.Generic.List[string] }

    # Не-COMPLETE (відомий статус) лишається завжди і в кошики не входить.
    foreach ($record in $ordered) {
        if (-not $record.IsRecordedComplete) { [void]$reasons[$record.GenerationId].Add('NotComplete') }
    }
    if ($ordered.Count -gt 0) { [void]$reasons[$ordered[0].GenerationId].Add('Newest') }

    if ($normalizedPolicy.IsConfigured) {
        if ($completeOrdered.Count -gt 0) { [void]$reasons[$completeOrdered[0].GenerationId].Add('LastRecoverable') }
        for ($index = 0; $index -lt [math]::Min($minimumRetained, $completeOrdered.Count); $index++) {
            [void]$reasons[$completeOrdered[$index].GenerationId].Add('MinimumRetained')
        }
        foreach ($record in $completeOrdered) {
            $ageDays = ($Now.Date - $record.Date.Date).Days
            if ($ageDays -lt [int]$normalizedPolicy.AllCopiesDays) { [void]$reasons[$record.GenerationId].Add('AllCopies') }
        }
        $buckets = @(
            @{ Name = 'Daily';   Count = [int]$normalizedPolicy.DailyCount;   Key = { param($d) $d.ToString('yyyy-MM-dd', $culture) } },
            @{ Name = 'Weekly';  Count = [int]$normalizedPolicy.WeeklyCount;  Key = { param($d) Get-BRAVORetentionIsoWeekKey -Date $d } },
            @{ Name = 'Monthly'; Count = [int]$normalizedPolicy.MonthlyCount; Key = { param($d) $d.ToString('yyyy-MM', $culture) } },
            @{ Name = 'Yearly';  Count = [int]$normalizedPolicy.YearlyCount;  Key = { param($d) $d.ToString('yyyy', $culture) } })
        foreach ($bucket in $buckets) {
            $seenKeys = New-Object System.Collections.Generic.HashSet[string]
            foreach ($record in $completeOrdered) {
                $bucketKey = [string](& $bucket.Key $record.Date)
                if (-not $seenKeys.Add($bucketKey)) { continue }
                if ($seenKeys.Count -gt $bucket.Count) { break }
                [void]$reasons[$record.GenerationId].Add(('{0} {1}' -f $bucket.Name, $bucketKey))
            }
        }
    } else {
        foreach ($record in $ordered) { [void]$reasons[$record.GenerationId].Add('NotConfigured') }
    }

    # 3. Записи плану: валідні (найновіші першими), потім позначені (у вхідному порядку).
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($record in $ordered) {
        $recordReasons = @($reasons[$record.GenerationId].ToArray())
        $decision = if ($recordReasons.Count -gt 0) { 'Keep' } else { 'WouldDelete' }
        if ($decision -eq 'WouldDelete') { $recordReasons = @('OutsideRetention') }
        [void]$entries.Add([pscustomobject]@{
            GenerationId = $record.GenerationId
            Date = $record.Date
            Decision = $decision
            Reasons = $recordReasons
            Reason = ($recordReasons -join '; ')
            Flags = @()
        })
    }
    foreach ($record in $flagged.ToArray()) {
        [void]$entries.Add([pscustomobject]@{
            GenerationId = $record.GenerationId
            Date = $record.Date
            Decision = 'Keep'
            Reasons = @('Flagged')
            Reason = 'Flagged'
            Flags = @($record.Flags)
        })
    }
    $entryArray = $entries.ToArray()
    return [pscustomobject]@{
        Mode = 'Simulation'
        DeletionPerformed = $false
        State = $(if ($normalizedPolicy.IsConfigured) { 'Planned' } else { 'NotConfigured' })
        Now = $Now
        Policy = $normalizedPolicy
        MinimumRetainedCount = $minimumRetained
        MissingKeys = @($normalizedPolicy.MissingKeys)
        Entries = $entryArray
        KeepCount = @($entryArray | Where-Object { $_.Decision -eq 'Keep' }).Count
        WouldDeleteCount = @($entryArray | Where-Object { $_.Decision -eq 'WouldDelete' }).Count
        FlaggedCount = @($entryArray | Where-Object { @($_.Flags).Count -gt 0 }).Count
    }
}

function Get-BRAVOBackupRetentionSimulation {
    # Читальний вхід (manifest adapter): збирає generations із manifest-ів
    # (MANIFESTS-first, як у решти retention) і будує план. Файли лише
    # читаються. Статус: COMPLETE -> IsRecordedComplete=$true; INCOMPLETE і
    # FAILED -> $false; відсутній/null/невідомий -> $null (UnknownStatus).
    # Manifest, чий generationId не збігається з іменем файлу, або з
    # нерозбірливим JSON чи без дати в GenerationId, лишається з позначкою.
    # Архіви й hash-файли НЕ перевіряються.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)]$Policy,
        [AllowNull()][object]$MinimumRetainedCount = $null,
        [datetime]$Now = (Get-Date)
    )

    if ($null -ne $MinimumRetainedCount) {
        [void](ConvertTo-BRAVORetentionNonNegativeInteger -Key 'MinimumRetainedCount' -Value $MinimumRetainedCount)
    }
    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) {
        throw "Retention-симуляція: BackupRoot недоступний: $BackupRoot"
    }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $generations = New-Object System.Collections.Generic.List[object]
    foreach ($manifestFile in @(Get-BRAVOBackupGenerationManifestFiles -BackupRoot $BackupRoot)) {
        $fileGenerationId = Get-BRAVOBackupManifestFilenameGenerationId -FileName $manifestFile.Name
        $identity = if ($null -ne $fileGenerationId) { $fileGenerationId } else { 'file:' + $manifestFile.Name }
        $when = $null
        $complete = $null
        try {
            $manifest = [IO.File]::ReadAllText($manifestFile.FullName) | ConvertFrom-Json -ErrorAction Stop
            $jsonGenerationId = if ($null -ne $manifest.PSObject.Properties['generationId']) { [string]$manifest.generationId } else { '' }
            if ($null -ne $fileGenerationId -and [string]::Equals($jsonGenerationId, $fileGenerationId, [StringComparison]::Ordinal)) {
                $parsed = [datetime]::MinValue
                if ([datetime]::TryParseExact($fileGenerationId.Substring(0, 15), 'yyyyMMdd_HHmmss', $culture,
                        [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                    $when = $parsed
                }
                $statusProperty = $manifest.PSObject.Properties['status']
                if ($null -ne $statusProperty -and $statusProperty.Value -is [string]) {
                    switch -CaseSensitive ([string]$statusProperty.Value) {
                        'COMPLETE' { $complete = $true }
                        'INCOMPLETE' { $complete = $false }
                        'FAILED' { $complete = $false }
                        default { $complete = $null }
                    }
                }
            }
        } catch {
            $when = $null
            $complete = $null
        }
        [void]$generations.Add([pscustomobject]@{ GenerationId = $identity; Date = $when; IsRecordedComplete = $complete })
    }
    $planArguments = @{ Generations = $generations.ToArray(); Policy = $Policy; Now = $Now }
    if ($null -ne $MinimumRetainedCount) { $planArguments['MinimumRetainedCount'] = $MinimumRetainedCount }
    return (Get-BRAVOBackupRetentionPlan @planArguments)
}

function Format-BRAVOBackupRetentionPlanLines {
    # Операторський текст симуляції (Ukrainian). Лише форматування.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('Симуляція retention (лише планування, нічого не видалено)')
    [void]$lines.Add('УВАГА: архіви й hash-файли НЕ перевірялись; COMPLETE береться лише із записаного статусу manifest-а.')
    if ($Plan.State -eq 'NotConfigured') {
        [void]$lines.Add('Кількості Д/Т/М/Р не налаштовано: план неможливий, WouldDelete = 0.')
        [void]$lines.Add('Не задано: ' + (@($Plan.MissingKeys) -join ', '))
    }
    [void]$lines.Add(('Усього: {0}; Keep: {1}; WouldDelete: {2}; позначено: {3}' -f
        @($Plan.Entries).Count, $Plan.KeepCount, $Plan.WouldDeleteCount, $Plan.FlaggedCount))
    foreach ($entry in @($Plan.Entries)) {
        $flagText = if (@($entry.Flags).Count -gt 0) { ' [' + (@($entry.Flags) -join ',') + ']' } else { '' }
        [void]$lines.Add(('{0}  {1}  {2}{3}' -f ([string]$entry.Decision).PadRight(11), $entry.GenerationId, $entry.Reason, $flagText))
    }
    return $lines.ToArray()
}
