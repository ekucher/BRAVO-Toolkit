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

function Resolve-BRAVOConfiguratorFieldAuthorization {
    <#
    .SYNOPSIS
        Похідна (derived) ефективна ReadOnly-поведінка дескрипторів
        каталогу Configurator-а з canonical Class Wave 2 (#216).
    .DESCRIPTION
        Каталог Configurator-а (BRAVO.Configurator.Schema.psd1) лишається
        джерелом UI-презентаційних метаданих (Label/Group/Section/Order/
        Description/AllowedValues) — але ЕФЕКТИВНУ ReadOnly-поведінку
        для DENY_*-класифікованих шляхів ця функція обчислює з
        канонічного реєстру схеми (Get-BRAVOConfigurationSchemaAuthorizationClass
        з BRAVO.Configuration.Schema), а не з власного статичного
        ReadOnly-поля каталогу. Це усуває drift СТРУКТУРНО, не патчем
        однієї позиції (WAVE2-CONTRACT.md, розділ 11.4): статичний
        ReadOnly=$false у каталозі для DENY-шляху (наприклад,
        backupMonitoring.SFTP.BAZA.Mode, .psd1-рядок з AllowedValues
        @('IncrementalAppendOnly','Legacy')) більше не може розійтись із
        тим, що loader реально прийме — canonical Class ЗАВЖДИ виграє,
        якщо каталог і реєстр колись розійдуться.

        НЕ дублює 271-позиційну класифікацію в другому файлі — читає
        той самий canonical реєстр, який використовує
        BRAVO_CONFIG_LOADER.ps1 (Test-BRAVOConfigurationOverrideAuthorization).
        Вхідний масив дескрипторів НЕ мутується — повертаються нові
        hashtable-копії (та сама "форма" елемента, що вже повертає
        Get-BRAVOConfiguratorSchemaCatalog).
    .PARAMETER Descriptors
        Масив каталогових дескрипторів (типово — результат
        Get-BRAVOConfiguratorSchemaCatalog).
    .PARAMETER AuthorizationClass
        Hashtable Path -> @{ Class; Validator } (типово — результат
        Get-BRAVOConfigurationSchemaAuthorizationClass з
        BRAVO.Configuration.Schema).
    .OUTPUTS
        [object[]] — копії дескрипторів: ReadOnly примусово $true для
        будь-якого DENY_*-класу, незалежно від статичного значення в
        каталозі; для ALLOW_SITE/ALLOW_WITH_VALIDATOR лишається
        статичне ReadOnly каталогу (презентаційна відповідальність
        каталогу — не змінена Wave 2). Каталоговий Path, якого немає в
        AuthorizationClass (не мало б статися для повного 271-переліку,
        але захисно), лишає статичне ReadOnly каталогу без змін.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Descriptors,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$AuthorizationClass
    )

    $resolved = New-Object System.Collections.Generic.List[object]
    foreach ($descriptor in $Descriptors) {
        $path = [string]$descriptor.Path
        $effectiveReadOnly = [bool]$descriptor.ReadOnly
        # AuthorizationClass (PR #224 review, F2): surfaced поряд із
        # ReadOnly, аби Configurator/UI-код, якому потрібне ПОВНЕ Wave 2
        # рішення (не лише похідний Boolean), мав його з ТОГО САМОГО
        # виклику — без другого окремого запиту до реєстру для того ж
        # Path. $null, коли Path невідомий реєстру (не мало б статися для
        # повного 271-переліку, але захисно — той самий випадок, що вже
        # лишає статичне ReadOnly каталогу без змін).
        $resolvedClass = $null
        if ($AuthorizationClass.Contains($path)) {
            $resolvedClass = [string]$AuthorizationClass[$path].Class
            if ($resolvedClass.StartsWith('DENY_', [System.StringComparison]::Ordinal)) {
                $effectiveReadOnly = $true
            }
        }
        $clone = @{}
        foreach ($key in @($descriptor.Keys)) { $clone[$key] = $descriptor[$key] }
        $clone['ReadOnly'] = $effectiveReadOnly
        $clone['AuthorizationClass'] = $resolvedClass
        [void]$resolved.Add($clone)
    }
    # Кома-оператор обов'язковий: без нього PowerShell розгортає
    # односимвольний/порожній масив у пайплайні при поверненні з функції
    # (caller отримав би голий hashtable замість object[] для 1 елемента,
    # або $null для 0) — той самий клас дефекту, від якого захищають
    # OutboundMessagesAssignmentsKeepOuterArrayWrapper-подібні self-test.
    return ,$resolved.ToArray()
}

Export-ModuleMember -Function @(
    'Get-BRAVOConfiguratorSchemaCatalog',
    'Get-BRAVOConfiguratorDocumentedOverridePaths',
    'Test-BRAVOConfiguratorSchemaCompleteness',
    'Resolve-BRAVOConfiguratorFieldAuthorization'
)
