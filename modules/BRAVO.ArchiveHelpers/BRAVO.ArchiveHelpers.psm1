# Shared BRAVO archive helpers with an explicit Compatibility dependency.

$compatibilityManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'BRAVO.Compatibility\BRAVO.Compatibility.psd1'
Import-Module -Name $compatibilityManifest -ErrorAction Stop

function Write-BRAVOArchiveHelperLog {
    param(
        [AllowNull()][scriptblock]$Logger,
        [string]$Message,
        [string]$Level = 'INFO'
    )

    if ($null -ne $Logger) {
        & $Logger $Message $Level
    }
}

function Remove-OldLogsByAge {
    param(
        [string]$Path,
        [string]$Filter,
        [int]$RetentionDays,
        [AllowNull()][scriptblock]$Logger
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $failed = $false
    foreach ($file in @(Get-BRAVOFiles -Path $Path -Filter $Filter |
        Where-Object { $_.LastWriteTime -lt $cutoff })) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            Write-BRAVOArchiveHelperLog `
                -Logger $Logger `
                -Message "Видалено старий лог: $($file.Name)" `
                -Level "SUCCESS"
        } catch {
            $failed = $true
            Write-BRAVOArchiveHelperLog `
                -Logger $Logger `
                -Message "Не вдалося видалити лог $($file.Name): $($_.Exception.Message)" `
                -Level "ERROR"
        }
    }
    return (-not $failed)
}

function Test-SevenZipArchiveIntegrity {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'Тонка обгортка над Invoke-BRAVOSevenZipIntegrityTest — пароль іде далі через redirected stdin.')]
    param(
        [string]$SevenZipPath,
        [string]$ArchivePath,
        [string]$Password,
        [int]$TimeoutSeconds = 43200,
        [AllowNull()][scriptblock]$Logger
    )

    Write-BRAVOArchiveHelperLog `
        -Logger $Logger `
        -Message "Перевiрка цiлiсностi 7-Zip: $(Split-Path $ArchivePath -Leaf)"
    $testResult = Invoke-BRAVOSevenZipIntegrityTest `
        -SevenZipPath $SevenZipPath `
        -ArchivePath $ArchivePath `
        -Password $Password `
        -TimeoutSeconds $TimeoutSeconds

    $exitCodeText = if ($null -eq $testResult.ExitCode) {
        "немає"
    } else {
        [string]$testResult.ExitCode
    }
    if ($testResult.Success) {
        Write-BRAVOArchiveHelperLog `
            -Logger $Logger `
            -Message "Цiлiснiсть архiву пiдтверджено 7-Zip (код: 0): $ArchivePath" `
            -Level "SUCCESS"
        return $true
    }

    Write-BRAVOArchiveHelperLog `
        -Logger $Logger `
        -Message "Перевiрка цiлiсностi 7-Zip не пройдена (код: $exitCodeText — $($testResult.Description)): $ArchivePath" `
        -Level "ERROR"
    $diagnosticLines = @(
        @($testResult.StandardError, $testResult.StandardOutput) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { [string]$_ -split '\r?\n' } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Last 20
    )
    if ($diagnosticLines.Count -gt 0) {
        Write-BRAVOArchiveHelperLog `
            -Logger $Logger `
            -Message "Дiагностика 7-Zip test: $($diagnosticLines -join [Environment]::NewLine)" `
            -Level "DEBUG"
    }
    return $false
}

function Get-BRAVOValidArchiveSizeHistory {
    # AUD-008 (аудит P1.6): для sanity-check обсягу backup потрібна історія
    # РОЗМІРІВ попередніх валідних (hash-підтверджених) архівів того самого
    # компонента. Той самий алгоритм валідації, що Remove-OldBackupSets
    # (BRAVO.Archive.Runtime.ps1) використовує для retention — сюди
    # свідомо не винесений як спільна функція, щоб не чіпати вже
    # перевірений retention-код; тут лише збирається .Length, видалення
    # не відбувається.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$ArchiveFilter,
        [Parameter(Mandatory = $true)][string]$HashFileExtension,
        [string]$ExcludeArchivePath,
        [int]$MaxCount = 5
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return @()
    }
    $validSizes = New-Object System.Collections.Generic.List[pscustomobject]
    $candidates = @(Get-BRAVOFiles -Path $Directory -Filter $ArchiveFilter |
        Sort-Object -Property LastWriteTime -Descending)
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($ExcludeArchivePath) -and
            [string]::Equals($candidate.FullName, $ExcludeArchivePath, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $hashPath = "$($candidate.FullName)$HashFileExtension"
        try {
            if (-not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
                continue
            }
            $hashText = ([System.IO.File]::ReadAllText($hashPath)).Trim([char]0xFEFF).Trim()
            if ($hashText -notmatch '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$') {
                continue
            }
            if ($Matches.FileName -cne $candidate.Name) {
                continue
            }
            $expectedHash = $Matches.Hash.ToUpperInvariant()
            $actualHash = (Get-BRAVOFileHash -Path $candidate.FullName -Algorithm SHA512).Hash.ToUpperInvariant()
            if ($actualHash -cne $expectedHash) {
                continue
            }
        } catch {
            continue
        }
        $validSizes.Add([pscustomobject]@{
            Path = $candidate.FullName
            Bytes = [int64]$candidate.Length
            LastWriteTime = $candidate.LastWriteTime
        })
        if ($validSizes.Count -ge $MaxCount) {
            break
        }
    }
    return @($validSizes)
}

function Test-BRAVOBackupSizeAnomaly {
    # AUD-008 (аудит P1.6): "успішний" backup технічно валідний (7za test +
    # SHA512 збігається), але може бути ПІДОЗРІЛО малим через неправильне
    # джерело, поламані permissions, неповний VSS exposure чи помилку
    # wildcard — сам файл при цьому виглядає коректним. Порівнює новий
    # архів із медіаною останніх валідних архівів того самого компонента;
    # НЕ блокує (лише сигналізує) — критичність лишається за викликачем.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int64]$NewArchiveBytes,
        [Parameter(Mandatory = $true)][string]$HistoryDirectory,
        [Parameter(Mandatory = $true)][string]$ArchiveFilter,
        [Parameter(Mandatory = $true)][string]$HashFileExtension,
        [string]$ExcludeArchivePath,
        [int]$HistoryCount = 5,
        [int64]$MinimumBytes = 1024,
        [int]$MaxSizeDropPercent = 50
    )

    $history = @(Get-BRAVOValidArchiveSizeHistory `
        -Directory $HistoryDirectory `
        -ArchiveFilter $ArchiveFilter `
        -HashFileExtension $HashFileExtension `
        -ExcludeArchivePath $ExcludeArchivePath `
        -MaxCount $HistoryCount)

    if ($NewArchiveBytes -lt $MinimumBytes) {
        return [pscustomobject]@{
            IsAnomaly = $true
            Reason = "розмір архіву ($NewArchiveBytes байт) менший за мінімально допустимий ($MinimumBytes байт)"
            HistorySampleCount = $history.Count
            MedianHistoricalBytes = $null
            NewArchiveBytes = $NewArchiveBytes
            DropPercent = $null
        }
    }

    if ($history.Count -eq 0) {
        return [pscustomobject]@{
            IsAnomaly = $false
            Reason = "недостатньо історії валідних архівів для порівняння (перший backup цього компонента чи ще не накопичено історію)"
            HistorySampleCount = 0
            MedianHistoricalBytes = $null
            NewArchiveBytes = $NewArchiveBytes
            DropPercent = $null
        }
    }

    $sortedSizes = @($history | Select-Object -ExpandProperty Bytes | Sort-Object)
    $middleIndex = [math]::Floor($sortedSizes.Count / 2)
    $medianBytes = if ($sortedSizes.Count % 2 -eq 0 -and $sortedSizes.Count -ge 2) {
        [int64][math]::Round(($sortedSizes[$middleIndex - 1] + $sortedSizes[$middleIndex]) / 2.0)
    } else {
        [int64]$sortedSizes[$middleIndex]
    }

    if ($medianBytes -le 0) {
        return [pscustomobject]@{
            IsAnomaly = $false
            Reason = "медіана історичних розмірів нульова — порівняння неможливе"
            HistorySampleCount = $history.Count
            MedianHistoricalBytes = $medianBytes
            NewArchiveBytes = $NewArchiveBytes
            DropPercent = $null
        }
    }

    $dropPercent = [math]::Round((1.0 - ([double]$NewArchiveBytes / [double]$medianBytes)) * 100.0, 1)
    if ($dropPercent -gt $MaxSizeDropPercent) {
        return [pscustomobject]@{
            IsAnomaly = $true
            Reason = "розмір архіву впав на $dropPercent% відносно медіани останніх $($history.Count) валідних backup (поріг: $MaxSizeDropPercent%)"
            HistorySampleCount = $history.Count
            MedianHistoricalBytes = $medianBytes
            NewArchiveBytes = $NewArchiveBytes
            DropPercent = $dropPercent
        }
    }

    return [pscustomobject]@{
        IsAnomaly = $false
        Reason = "у межах норми (відхилення від медіани: $dropPercent%)"
        HistorySampleCount = $history.Count
        MedianHistoricalBytes = $medianBytes
        NewArchiveBytes = $NewArchiveBytes
        DropPercent = $dropPercent
    }
}

function Get-BRAVOBackupManifestRoot {
    # dev.14: generation manifest-и (BRAVO_BACKUP_<GenerationId>.json)
    # зберігаються окремо від LOGS/TEMP — їхній lifecycle прив'язаний до
    # backup generation (видаляються разом з нею), а не до незалежного
    # LogDays/CompressedLogDays. Єдине місце, що знає фізичний шлях —
    # інші функції завжди отримують його звідси, а не будують Join-Path самі.
    param([Parameter(Mandatory = $true)][string]$BackupRoot)

    return (Join-Path $BackupRoot 'MANIFESTS')
}

function Get-BRAVOBackupGenerationManifestFiles {
    # Централізований reader generation manifest-ів. MANIFESTS\ — джерело
    # істини; корінь BackupRoot — fallback для файлів, які ще не мігровані
    # (Initialize-BRAVOBackupManifestStorage не виконувалась, наприклад одразу
    # після апгрейду до dev.14) або лишились там після конфлікту міграції.
    # Корінь читається БЕЗ -Recurse, тому підпапка MANIFESTS у нього фізично
    # не потрапляє — дублювання виникає лише коли той самий generationId
    # реально існує в обох місцях, і тоді пріоритет завжди за MANIFESTS.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [string]$GenerationId
    )

    $manifestRoot = Get-BRAVOBackupManifestRoot -BackupRoot $BackupRoot

    if (-not [string]::IsNullOrWhiteSpace($GenerationId)) {
        $fileName = "BRAVO_BACKUP_{0}.json" -f $GenerationId
        $newPath = Join-Path $manifestRoot $fileName
        if (Test-Path -LiteralPath $newPath -PathType Leaf) {
            return @(Get-Item -LiteralPath $newPath)
        }
        $legacyPath = Join-Path $BackupRoot $fileName
        if (Test-Path -LiteralPath $legacyPath -PathType Leaf) {
            return @(Get-Item -LiteralPath $legacyPath)
        }
        return @()
    }

    $newManifests = if (Test-Path -LiteralPath $manifestRoot -PathType Container) {
        @(Get-BRAVOFiles -Path $manifestRoot -Filter 'BRAVO_BACKUP_*.json')
    } else {
        @()
    }
    $legacyManifests = @(Get-BRAVOFiles -Path $BackupRoot -Filter 'BRAVO_BACKUP_*.json')

    # Дедуплікація за іменем файлу (== generationId): MANIFESTS додається
    # першим, тому саме він "виграє" колізію, а не порядок файлової системи.
    $seenNames = New-Object 'System.Collections.Generic.HashSet[string]'
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($file in $newManifests) {
        if ($seenNames.Add($file.Name)) {
            $result.Add($file)
        }
    }
    foreach ($file in $legacyManifests) {
        if ($seenNames.Add($file.Name)) {
            $result.Add($file)
        }
    }
    return $result.ToArray()
}

function Initialize-BRAVOBackupManifestStorage {
    # dev.14: одноразова (ідемпотентна) міграція legacy manifest-ів —
    # BRAVO_BACKUP_*.json безпосередньо в корені BackupRoot — у виділений
    # MANIFESTS\. Пошук legacy — БЕЗ -Recurse (лише корінь BackupRoot,
    # підпапка MANIFESTS у нього не потрапляє).
    #
    # Колізії при непорожньому destination:
    #   - файлів немає в MANIFESTS               => Move-Item;
    #   - є, і байтово ідентичний (SHA256)        => legacy-дублікат
    #     видаляється, MANIFESTS лишається єдиним джерелом;
    #   - є, і відрізняється                      => ЖОДЕН файл не
    #     видаляється й не перезаписується, лише WARNING у лог із
    #     generationId конфлікту; reader (Get-BRAVOBackupGenerationManifestFiles)
    #     все одно віддасть перевагу версії з MANIFESTS.
    #
    # Нічого з цього не є фатальним для виклику — весь стан повертається
    # викликачу через результат; невдала міграція нічого не знищує і
    # повторюється на наступному запуску.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [AllowNull()][scriptblock]$Logger
    )

    $result = [ordered]@{
        ManifestRoot = $null
        ManifestRootCreated = $false
        Migrated = @()
        Deduplicated = @()
        Conflicts = @()
        Errors = @()
    }

    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) {
        $result.Errors += "BackupRoot не знайдено: $BackupRoot"
        return [pscustomobject]$result
    }

    $manifestRoot = Get-BRAVOBackupManifestRoot -BackupRoot $BackupRoot
    $result.ManifestRoot = $manifestRoot
    try {
        if (-not (Test-Path -LiteralPath $manifestRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $manifestRoot -Force -ErrorAction Stop | Out-Null
            $result.ManifestRootCreated = $true
            Write-BRAVOArchiveHelperLog -Logger $Logger `
                -Message "Створено каталог метаданих backup: $manifestRoot" -Level "SUCCESS"
        }
    } catch {
        $result.Errors += "Не вдалося створити ${manifestRoot}: $($_.Exception.Message)"
        Write-BRAVOArchiveHelperLog -Logger $Logger -Message $result.Errors[-1] -Level "ERROR"
        return [pscustomobject]$result
    }

    foreach ($legacyFile in @(Get-BRAVOFiles -Path $BackupRoot -Filter 'BRAVO_BACKUP_*.json')) {
        $generationLabel = $legacyFile.Name -replace '^BRAVO_BACKUP_(.+)\.json$', '$1'
        $destinationPath = Join-Path $manifestRoot $legacyFile.Name
        try {
            if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
                Move-Item -LiteralPath $legacyFile.FullName -Destination $destinationPath -ErrorAction Stop
                $result.Migrated += $legacyFile.Name
                Write-BRAVOArchiveHelperLog -Logger $Logger `
                    -Message "Перенесено manifest generation ${generationLabel} у MANIFESTS" -Level "SUCCESS"
                continue
            }

            $legacyHash = (Get-BRAVOFileHash -Path $legacyFile.FullName -Algorithm SHA256).Hash
            $destinationHash = (Get-BRAVOFileHash -Path $destinationPath -Algorithm SHA256).Hash
            if ([string]::Equals($legacyHash, $destinationHash, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $legacyFile.FullName -Force -ErrorAction Stop
                $result.Deduplicated += $legacyFile.Name
                Write-BRAVOArchiveHelperLog -Logger $Logger `
                    -Message "Manifest generation ${generationLabel} уже є в MANIFESTS (ідентичний); legacy-копію в корені прибрано" `
                    -Level "INFO"
            } else {
                $result.Conflicts += $legacyFile.Name
                Write-BRAVOArchiveHelperLog -Logger $Logger `
                    -Message "Конфлікт manifest generation ${generationLabel}: версії в корені BackupRoot і в MANIFESTS відрізняються — обидва файли збережено без змін, читання пріоритетно бере версію з MANIFESTS" `
                    -Level "WARNING"
            }
        } catch {
            $result.Errors += "Не вдалося обробити manifest generation ${generationLabel}: $($_.Exception.Message)"
            Write-BRAVOArchiveHelperLog -Logger $Logger -Message $result.Errors[-1] -Level "ERROR"
        }
    }

    return [pscustomobject]$result
}

function Get-BRAVOBackupManifestFilenameGenerationId {
    # dev.14 (round 3): строгий parser/validator generationId, закодованого
    # у ФІЗИЧНОМУ імені файлу manifest-а (BRAVO_BACKUP_<GenerationId>.json).
    # Формат GenerationId — yyyyMMdd_HHmmss або той самий з collision-safe
    # суфіксом (_N) — той самий контракт, що BRAVO_RESTORE_TEST.ps1 вже
    # валідує для параметра -GenerationId. Повертає $null, якщо ім'я файлу
    # НЕ відповідає точно цьому формату — викликач тоді не повинен
    # довіряти файлу як trustworthy retention record.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$FileName)

    if ($FileName -match '^BRAVO_BACKUP_(?<GenerationId>\d{8}_\d{6}(?:_\d+)?)\.json$') {
        return $Matches.GenerationId
    }
    return $null
}

function Get-BRAVOBackupGenerationManifestPhysicalFiles {
    # Усі фізичні копії manifest-файлу ОДНІЄЇ generation — на відміну від
    # Get-BRAVOBackupGenerationManifestFiles (читання, MANIFESTS-first,
    # дедуплікація ховає legacy-дублікат/конфлікт), ця функція повертає їх
    # УСІ. Потрібна retention: коли generation підтверджено видаляється,
    # видалені мають бути ВСІ фізичні представлення її metadata — інакше
    # legacy-копія переживає видалення MANIFESTS-копії і на наступному
    # запуску "воскрешає" видалену generation через legacy fallback читання.
    #
    # GenerationId походить із вмісту manifest-файлу (JSON, недовірений
    # вхід відносно файлової системи) — шлях свідомо НЕ конструюється
    # (Join-Path недовіреного рядка з коренем був би path traversal).
    # Замість цього кандидати відбираються фільтром .Name серед РЕАЛЬНО
    # перелічених файлів (Get-BRAVOFiles, лише MANIFESTS + корінь
    # BackupRoot, без -Recurse) — попадання неможливе поза цими двома
    # каталогами незалежно від вмісту GenerationId.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$GenerationId
    )

    $expectedFileName = "BRAVO_BACKUP_{0}.json" -f $GenerationId
    $manifestRoot = Get-BRAVOBackupManifestRoot -BackupRoot $BackupRoot
    $allPhysicalFiles = @(
        $(if (Test-Path -LiteralPath $manifestRoot -PathType Container) {
            Get-BRAVOFiles -Path $manifestRoot -Filter 'BRAVO_BACKUP_*.json'
        })
        $(Get-BRAVOFiles -Path $BackupRoot -Filter 'BRAVO_BACKUP_*.json')
    )
    return @($allPhysicalFiles | Where-Object {
        [string]::Equals($_.Name, $expectedFileName, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Get-BRAVORestoreGenerationManifest {
    # Selector generation для restore-інструментів (BRAVO_RESTORE_TEST і
    # BRAVO_DATA_RESTORE): найновіший COMPLETE generation manifest або точний
    # -RequestedGenerationId. Живе тут, а не в кожному скрипті окремо, щоб
    # обидва restore-потоки гарантовано вибирали generation за одними й тими
    # самими правилами (MANIFESTS-first читання, лише status=COMPLETE,
    # сортування за createdAt/startedAt/LastWriteTime).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [string]$RequestedGenerationId
    )

    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) {
        throw "BackupRoot не знайдено: $BackupRoot"
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedGenerationId) -and
        $RequestedGenerationId -notmatch '^\d{8}_\d{6}(?:_\d+)?$') {
        throw "GenerationId має формат yyyyMMdd_HHmmss або collision-safe variant"
    }

    # dev.14: MANIFESTS-first reader з fallback на legacy корінь BackupRoot —
    # той самий централізований reader, що Archive-retention і Health.
    $manifestFiles = @(Get-BRAVOBackupGenerationManifestFiles `
        -BackupRoot $BackupRoot `
        -GenerationId $RequestedGenerationId)

    $candidates = @()
    foreach ($manifestFile in $manifestFiles) {
        try {
            $manifest = [IO.File]::ReadAllText($manifestFile.FullName) | ConvertFrom-Json -ErrorAction Stop
            if ([string]$manifest.status -ne 'COMPLETE') { continue }
            # Identity invariant: ім'я файлу (BRAVO_BACKUP_<generationId>.json)
            # і generationId усередині JSON мають бути ТОЧНО тим самим
            # значенням. Без цієї перевірки пошкоджений/перейменований
            # manifest міг би пройти лише format-валідацію RequestedGenerationId
            # (яка звіряється із самим ІМ'ЯМ файлу — Get-BRAVOBackupGenerationManifestFiles
            # будує ім'я з нього), а фактично відновити зовсім іншу
            # generation, вказану всередині файлу.
            $filenameGenerationId = [IO.Path]::GetFileNameWithoutExtension($manifestFile.Name) -replace '^BRAVO_BACKUP_', ''
            $jsonGenerationId = [string]$manifest.generationId
            if ([string]::IsNullOrWhiteSpace($jsonGenerationId) -or
                $jsonGenerationId -notmatch '^\d{8}_\d{6}(?:_\d+)?$' -or
                -not [string]::Equals($filenameGenerationId, $jsonGenerationId, [StringComparison]::Ordinal)) {
                if (-not [string]::IsNullOrWhiteSpace($RequestedGenerationId)) {
                    throw "manifest '$($manifestFile.Name)' не пройшов перевірку ідентичності: ім'я файлу вказує generation '$filenameGenerationId', а вміст JSON — '$jsonGenerationId'"
                }
                # Автоматичний вибір (без explicit -RequestedGenerationId):
                # fail-closed — пропускаємо підозрілий manifest, а не
                # ризикуємо вибрати generation, вказану лише в JSON.
                continue
            }
            $createdAt = $manifestFile.LastWriteTime
            foreach ($dateProperty in @('createdAt', 'startedAt')) {
                $property = $manifest.PSObject.Properties[$dateProperty]
                if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    $createdAt = [datetime]$property.Value
                    break
                }
            }
            $candidates += [pscustomobject]@{
                Manifest = $manifest
                ManifestPath = $manifestFile.FullName
                CreatedAt = $createdAt
            }
        } catch {
            if (-not [string]::IsNullOrWhiteSpace($RequestedGenerationId)) {
                throw "Generation manifest не прочитано: $($_.Exception.Message)"
            }
        }
    }
    $selected = $candidates | Sort-Object CreatedAt -Descending | Select-Object -First 1
    if ($null -eq $selected) {
        if ([string]::IsNullOrWhiteSpace($RequestedGenerationId)) {
            throw 'не знайдено жодного COMPLETE generation manifest'
        }
        throw "COMPLETE generation '$RequestedGenerationId' не знайдено"
    }
    return $selected
}

function Get-BRAVOVerifiedGenerationArchive {
    # Строгий per-component gate для restore-інструментів: прапорці manifest
    # (Enabled/CreateSuccess/IntegritySuccess/HashSuccess), фізична наявність
    # архіву й sidecar, коректний формат sidecar із case-sensitive збігом
    # імені файлу та ФАКТИЧНИЙ перерахунок SHA512. Будь-яка розбіжність —
    # throw: компонент не можна ані вважати відновлюваним (RESTORE_TEST),
    # ані відновлювати (DATA_RESTORE).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$Component,
        # Canonical naming policy of the backup PRODUCER (той самий
        # NameTemplate, яким генерувалось ім'я архіву — BRAVO.config
        # archiveDefinitions[Type].NameTemplate -f archivePrefix,
        # generationId). Використовується лише для СТРУКТУРИ суфіксу
        # (роздільник + generationId + розширення), НЕ для конкретного
        # значення ArchivePrefix — див. коментар нижче.
        [Parameter(Mandatory = $true)][string]$NameTemplate,
        # Canonical (не мутований поточними налаштуваннями) каталог, де
        # ЛЕГІТИМНО зберігаються артефакти САМЕ цього Component — для
        # Local це archiveDefinitions[Type].Destination, для SFTP-staging
        # це per-component підкаталог staging generation root
        # (Invoke-BRAVODataRestoreSftpArchiveFetch кладе кожен компонент
        # у власний підкаталог). Основа identity-binding: ArchivePrefix —
        # оператор-конфігурований рядок, що ЗМІНЮЄТЬСЯ з часом (ротація);
        # README.md документує, що архіви, створені під СТАРИМ префіксом,
        # лишаються legitimate й мають лишатись відновлюваними. Каталог,
        # натомість, детермінований типом компонента і не залежить від
        # поточного значення ArchivePrefix.
        [Parameter(Mandatory = $true)][string]$ComponentDirectory
    )

    $componentsProperty = $Manifest.PSObject.Properties['components']
    if ($null -eq $componentsProperty -or $null -eq $componentsProperty.Value) {
        throw 'generation manifest не містить components'
    }
    $componentProperty = @($componentsProperty.Value.PSObject.Properties | Where-Object {
        [string]::Equals($_.Name, $Component, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)
    if ($componentProperty.Count -eq 0) {
        throw "generation не містить component $Component"
    }
    $componentState = $componentProperty[0].Value
    if (-not [bool]$componentState.Enabled -or
        -not [bool]$componentState.CreateSuccess -or
        -not [bool]$componentState.IntegritySuccess -or
        -not [bool]$componentState.HashSuccess) {
        throw "component $Component не має COMPLETE archive/integrity/SHA512 state"
    }

    $archivePath = [string]$componentState.ArchivePath
    $hashPath = [string]$componentState.HashPath
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
        throw "component $Component посилається на відсутній archive/hash artifact"
    }
    $archive = Get-Item -LiteralPath $archivePath

    # Component identity binding: артефакт МУСИТЬ фізично лежати в
    # canonical каталозі саме цього Component — інакше пошкоджений/
    # підмінений manifest міг би підставити реальний, криптографічно
    # валідний архів ІНШОГО компонента (він лежить у СВОЄМУ каталозі, не
    # в цьому), і кожна перевірка нижче (SHA512, sidecar) пройшла б, бо
    # файл сам по собі не пошкоджений. На відміну від попередньої
    # реалізації (порівняння повного імені файлу з поточним ArchivePrefix),
    # ця перевірка НЕ залежить від того, яким був ArchivePrefix у момент
    # створення архіву — ротація префіксу не інвалідує старі backup.
    $archiveDirectoryFull = try { [System.IO.Path]::GetFullPath($archive.DirectoryName).TrimEnd('\', '/') } catch { $archive.DirectoryName }
    $expectedDirectoryFull = try { [System.IO.Path]::GetFullPath($ComponentDirectory).TrimEnd('\', '/') } catch { $ComponentDirectory }
    if (-not [string]::Equals($archiveDirectoryFull, $expectedDirectoryFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "component ${Component}: артефакт '$($archive.FullName)' лежить поза canonical каталогом цього компонента ('$ComponentDirectory') — можлива підміна компонента у manifest"
    }

    # Generation identity binding: ім'я артефакта має закінчуватись саме
    # тим суфіксом (роздільник(и) + generationId + розширення), який
    # NameTemplate виробляє для CIЄЇ generationId — це прив'язує до
    # generation, знову ж НЕЗАЛЕЖНО від значення ArchivePrefix (підставляємо
    # порожній рядок у позицію {0}, суфікс — те, що лишається праворуч).
    $manifestGenerationId = [string]$Manifest.generationId
    $expectedNameSuffix = $NameTemplate -f '', $manifestGenerationId
    if ([string]::IsNullOrEmpty($expectedNameSuffix) -or
        $archive.Name.Length -le $expectedNameSuffix.Length -or
        -not $archive.Name.EndsWith($expectedNameSuffix, [StringComparison]::Ordinal)) {
        throw "component ${Component}: ім'я артефакта '$($archive.Name)' не відповідає generation '$manifestGenerationId' за canonical NameTemplate — можлива підміна generation у manifest"
    }
    $hashText = ([IO.File]::ReadAllText($hashPath)).Trim([char]0xFEFF).Trim()
    if ($hashText -notmatch '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$' -or
        $Matches.FileName -cne $archive.Name) {
        throw "component $Component має некоректний SHA512 sidecar"
    }
    $actualHash = (Get-BRAVOFileHash -Path $archive.FullName -Algorithm SHA512).Hash.ToUpperInvariant()
    if ($actualHash -cne $Matches.Hash.ToUpperInvariant()) {
        throw "component $Component не пройшов фактичну SHA512 verification"
    }
    return $archive
}
