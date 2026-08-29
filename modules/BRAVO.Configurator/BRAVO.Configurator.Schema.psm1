# BRAVO.Configurator.Schema — canonical descriptor catalog access + completeness перевірка.
#
# Джерело даних — BRAVO.Configurator.Schema.psd1 (data-only, поруч у цьому
# ж каталозі). Модуль сам не містить жодного дескриптора — лише завантажує
# каталог і перевіряє його узгодженість із задокументованим override-контрактом
# (BRAVO.local.config.example), щоб schema ніколи не розійшлася з ним мовчки.

$script:SchemaDataPath = Join-Path $PSScriptRoot 'BRAVO.Configurator.Schema.psd1'

$script:ValidTypes = @(
    'Boolean', 'String', 'Integer', 'Number', 'Enum', 'Time', 'Path',
    'UNCPath', 'StringArray', 'NumberArray'
)

function Get-BRAVOConfiguratorSchemaCatalog {
    <#
    .SYNOPSIS
        Повертає повний canonical каталог дескрипторів налаштувань Configurator-а.
    .DESCRIPTION
        Читає data-only BRAVO.Configurator.Schema.psd1 через
        Import-PowerShellDataFile (без виконання коду) і повертає масив
        дескрипторів. Не кешує між викликами — виклики дешеві, а кешування
        приховало б редагування каталогу під час розробки/тестів.
    #>
    [CmdletBinding()]
    param(
        [string]$SchemaPath = $script:SchemaDataPath
    )

    if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
        throw "BRAVO.Configurator.Schema: каталог дескрипторів не знайдено ('$SchemaPath')."
    }

    # Descriptors живе в PrivateData, а не на верхньому рівні — Schema.psd1
    # МУСИТЬ бути дійсним module-маніфестом (Test-ModuleManifest
    # прогонить BRAVO_SELF_TEST.ps1 по всіх *.psd1 під modules\, і
    # довільний member поза фіксованим списком провалює його fatal-но).
    $catalogData = Import-PowerShellDataFile -LiteralPath $SchemaPath
    if ($null -eq $catalogData -or -not $catalogData.Contains('PrivateData') -or
        -not $catalogData.PrivateData.Contains('Descriptors')) {
        throw "BRAVO.Configurator.Schema: '$SchemaPath' не містить ключа 'PrivateData.Descriptors'."
    }

    return @($catalogData.PrivateData.Descriptors)
}

function Get-BRAVOConfiguratorDocumentedOverridePaths {
    <#
    .SYNOPSIS
        Витягує повний список задокументованих override dot-шляхів із
        BRAVO.local.config.example — canonical source of truth для
        схемного покриття (не окрема ручна таблиця).
    .DESCRIPTION
        Парсить закоментовані рядки виду # 'path.to.key' = value у прикладі
        локального конфігу. Це той самий контракт, що читає оператор,
        готуючи BRAVO.local.config, тому schema-повнота перевіряється
        проти нього напряму, а не проти дублікату переліку.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ExamplePath
    )

    if (-not (Test-Path -LiteralPath $ExamplePath -PathType Leaf)) {
        throw "BRAVO.Configurator.Schema: приклад локального конфігу не знайдено ('$ExamplePath')."
    }

    $exampleLines = Get-Content -LiteralPath $ExamplePath -Encoding UTF8
    $documentedPaths = New-Object System.Collections.Generic.List[string]
    $pathPattern = "^\s*#\s*'([a-zA-Z][a-zA-Z0-9_.]*)'\s*="
    foreach ($line in $exampleLines) {
        $match = [regex]::Match($line, $pathPattern)
        if ($match.Success) {
            $documentedPaths.Add($match.Groups[1].Value)
        }
    }

    return @($documentedPaths | Select-Object -Unique)
}

function Test-BRAVOConfiguratorSchemaCompleteness {
    <#
    .SYNOPSIS
        Механічно доводить 1:1 відповідність schema-каталогу і
        задокументованого override-контракту (§3.4 задачі Configurator-а).
    .DESCRIPTION
        Повертає структурований результат — не приймає "переглянули
        вручну" як доказ. FAIL-умови: configurable шлях без дескриптора
        (Missing), дескриптор на неіснуючий шлях (Orphan), дублікат Path
        у схемі (Duplicate), некоректний Type/Group.
    #>
    [CmdletBinding()]
    param(
        [string]$SchemaPath = $script:SchemaDataPath,
        [Parameter(Mandatory = $true)][string]$ExamplePath
    )

    $descriptors = @(Get-BRAVOConfiguratorSchemaCatalog -SchemaPath $SchemaPath)
    $documentedPaths = @(Get-BRAVOConfiguratorDocumentedOverridePaths -ExamplePath $ExamplePath)

    $descriptorPaths = @($descriptors | ForEach-Object { [string]$_.Path })

    $duplicatePaths = @($descriptorPaths | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    $missingPaths = @($documentedPaths | Where-Object { $descriptorPaths -notcontains $_ })
    $orphanPaths = @($descriptorPaths | Where-Object { $documentedPaths -notcontains $_ })

    $invalidTypeDescriptors = @($descriptors | Where-Object { $script:ValidTypes -notcontains [string]$_.Type } | ForEach-Object { [string]$_.Path })
    $invalidGroupDescriptors = @($descriptors | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Group) -or [string]::IsNullOrWhiteSpace([string]$_.Section) } | ForEach-Object { [string]$_.Path })

    $isComplete = ($duplicatePaths.Count -eq 0) -and ($missingPaths.Count -eq 0) -and
        ($orphanPaths.Count -eq 0) -and ($invalidTypeDescriptors.Count -eq 0) -and
        ($invalidGroupDescriptors.Count -eq 0)

    return [pscustomobject]@{
        IsComplete             = $isComplete
        ConfigurableTotal       = $documentedPaths.Count
        SchemaDescriptors       = $descriptorPaths.Count
        DuplicatePaths          = $duplicatePaths
        MissingPaths            = $missingPaths
        OrphanPaths             = $orphanPaths
        InvalidTypeDescriptors  = $invalidTypeDescriptors
        InvalidGroupDescriptors = $invalidGroupDescriptors
    }
}

Export-ModuleMember -Function @(
    'Get-BRAVOConfiguratorSchemaCatalog',
    'Get-BRAVOConfiguratorDocumentedOverridePaths',
    'Test-BRAVOConfiguratorSchemaCompleteness'
)
