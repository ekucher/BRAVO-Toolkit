#requires -Version 3.0

# BRAVOConfigV2Pilot.Runtime.ps1 — канонічна реалізація orchestration-логіки
# для контрольованого реального pilot Configuration v2 (#154, крок 2
# "Remaining work": автоматизація прийнятого оператором вручну runbook
# docs\BRAVO_CONFIG_V2_PILOT_MIGRATION_RUNBOOK_20260916.md).
#
# ПРИНЦИП: цей файл НЕ дублює жодного алгоритму Configuration v2. Усі
# перевірки/дельта/parity/self-test виконуються ВИКЛЮЧНО через canonical
# інструменти, встановлені на самому pilot-сервері (-InstallRoot):
#
#     $InstallRoot\BRAVO_CONFIG_TEST.ps1 -FullGraph         (знімок)
#     $InstallRoot\deploy\Get-BRAVOConfigSiteDelta.ps1       (дельта)
#     $InstallRoot\deploy\Compare-BRAVOConfigEffectiveSnapshot.ps1 (parity)
#     $InstallRoot\BRAVO_SETUP.ps1 -ValidateOnly             (validate-only)
#     $InstallRoot\BRAVO_SELF_TEST.ps1                       (self-test)
#     $InstallRoot\BRAVO_HEALTH.ps1                          (health)
#     $InstallRoot\BRAVO_DRY_RUN.ps1                         (archive smoke)
#
# Це НАВМИСНЕ архітектурне рішення (не з browsing/дефолту): сервер, на
# якому виконується реальний pilot, ЗОБОВ'ЯЗАНИЙ уже мати комплект версії з
# підтримкою Configuration v2 (те саме передумова, що й
# BRAVO_CONFIG_V2_PILOT_MIGRATION_RUNBOOK_20260916.md, розділ
# "Передумови", п.1) — оновлення самого BRAVO-Toolkit є ОКРЕМОЮ, вже
# наявною операцією (deploy\Update-BRAVOServer.ps1), а не частиною цього
# pilot-артефакту. Бандлити копію Configuration v2 модулів в артефакт
# означало б або (а) дублювати canonical merge/delta/schema-алгоритм
# другий раз, або (б) виконувати його проти ЧУЖОГО $InstallRoot з
# підмінених модулів — обидва варіанти забороняє
# .claude/rules/05-architecture.md ("Політика єдиної реалізації"). Preflight
# (Invoke-BRAVOPilotPreflight) явно й fail-closed перевіряє наявність усіх
# перелічених вище canonical інструментів на сервері ПЕРЕД будь-якою
# mutating-операцією.
#
# Dot-sourced з:
#   Start-BRAVOConfigV2Pilot.ps1 (orchestrator, всередині pilot-артефакту)
#   selftest\BRAVO_SELF_TEST.ConfigV2PilotArtifact.ps1 (end-to-end тест)
#   Failure-injection тести (той самий файл)
#
# PowerShell 5.1 сумісність обов'язкова.

Set-StrictMode -Version 2.0

function Get-BRAVOPilotSafeLastExitCode {
    # $LASTEXITCODE — автозмінна PowerShell, але під Set-StrictMode
    # -Version 2.0 читання МОЖЕ кинути "cannot be retrieved because it has
    # not been set", якщо жоден native/script виклик, що явно встановлює
    # exit code, ще не відбувся в поточному ланцюжку скоупів (canonical
    # deploy\Get-BRAVOConfigSiteDelta.ps1 не викликає `exit 0` на щасливому
    # шляху — лише `exit 1` у catch). Пряме звернення до $LASTEXITCODE тут
    # небезпечне; Get-Variable з -ErrorAction SilentlyContinue повертає
    # $null замість винятку.
    return Get-Variable -Name LASTEXITCODE -ValueOnly -Scope Global -ErrorAction SilentlyContinue
}

# --- Секретна безпека evidence --------------------------------------------

# Категорії ключів, які потребують суворішої перевірки значення перед
# записом у evidence. Перелік НЕ є redaction-фреймворком (secion 13/8
# явно забороняє його будувати в цій задачі) — це вузька, детермінована
# defense-in-depth перевірка ПЕРЕД записом файлу доказів.
$script:BRAVOPilotSensitiveKeyPattern =
    '(?i)(password|passwd|token|secret|webhook|credential|authorization|api[_-]?key|apikey)'

# Значення, які МОЖУТЬ легітимно з'явитись під sensitive-named ключем: імена
# записів Windows Credential Manager (canonical shape в усьому репозиторії —
# наприклад 'BRAVO_SFTP_PASSWORD', 'BRAVO_SFTP_PASSWORD_PILOT_SITE'). Це
# REFERENCE, не секрет: Configuration v2 гарантує (PilotSafety/
# CredentialReferenceNeverResolved), що дерево конфігурації ніколи не
# містить резолвнутого значення — лише таке ім'я.
$script:BRAVOPilotCredentialReferenceShapePattern = '^[A-Z][A-Z0-9_]{2,127}$'

# URI з вбудованими credentials (scheme://user:secret@host) НІКОЛИ не є
# легітимним у evidence незалежно від імені ключа — це вже сам секрет.
$script:BRAVOPilotEmbeddedUriCredentialPattern = '[A-Za-z][A-Za-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@'

function Test-BRAVOPilotSecretSafeString {
    # Перевіряє ОДНЕ рядкове значення. Повертає $true, якщо значення
    # безпечне для запису в evidence.
    param(
        [AllowNull()][string]$Value,
        [AllowNull()][string]$KeyName
    )

    if ([string]::IsNullOrEmpty($Value)) { return $true }

    if ($Value -match $script:BRAVOPilotEmbeddedUriCredentialPattern) {
        return $false
    }

    if (-not [string]::IsNullOrEmpty($KeyName) -and $KeyName -match $script:BRAVOPilotSensitiveKeyPattern) {
        # Sensitive-named ключ: значення допустиме ЛИШЕ якщо має форму
        # Credential Manager reference-імені. Будь-що інше (реальний пароль,
        # base64/hex blob, довільний текст) відхиляється.
        return [bool]($Value -match $script:BRAVOPilotCredentialReferenceShapePattern)
    }

    return $true
}

function Assert-BRAVOPilotEvidenceSecretSafe {
    # Рекурсивно обходить об'єкт (hashtable/PSCustomObject/масив/скаляр) і
    # кидає виняток (fail closed) на першому небезпечному значенні.
    # Викликається ПЕРЕД будь-яким записом evidence-файлу.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Object,
        [string]$Path = '$'
    )

    if ($null -eq $Object) { return }

    if ($Object -is [string]) {
        if (-not (Test-BRAVOPilotSecretSafeString -Value $Object -KeyName $null)) {
            throw "SECRET_SAFE_VIOLATION: значення за шляхом '$Path' виглядає як embedded credential у URI — запис evidence заблоковано (fail closed)."
        }
        return
    }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in @($Object.Keys)) {
            $childPath = "$Path.$key"
            $childValue = $Object[$key]
            if ($childValue -is [string] -and -not (Test-BRAVOPilotSecretSafeString -Value $childValue -KeyName ([string]$key))) {
                throw "SECRET_SAFE_VIOLATION: значення ключа '$childPath' відповідає sensitive-категорії, але НЕ має форми Credential Manager reference-імені — можливий реальний секрет. Запис evidence заблоковано (fail closed)."
            }
            Assert-BRAVOPilotEvidenceSecretSafe -Object $childValue -Path $childPath
        }
        return
    }

    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Object.PSObject.Properties) {
            $childPath = "$Path.$($property.Name)"
            $childValue = $property.Value
            if ($childValue -is [string] -and -not (Test-BRAVOPilotSecretSafeString -Value $childValue -KeyName ([string]$property.Name))) {
                throw "SECRET_SAFE_VIOLATION: значення властивості '$childPath' відповідає sensitive-категорії, але НЕ має форми Credential Manager reference-імені — можливий реальний секрет. Запис evidence заблоковано (fail closed)."
            }
            Assert-BRAVOPilotEvidenceSecretSafe -Object $childValue -Path $childPath
        }
        return
    }

    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        $index = 0
        foreach ($item in $Object) {
            Assert-BRAVOPilotEvidenceSecretSafe -Object $item -Path "$Path[$index]"
            $index++
        }
        return
    }

    # Скалярні не-рядкові типи (bool/int/null) — безпечні за визначенням.
}

function Assert-BRAVOPilotTextSecretSafe {
    # Текстовий (не-JSON) evidence — логи дочірніх процесів. Перевіряється
    # рядок за рядком на embedded-credential URI-патерн; sensitive-named
    # key/value перевірку для вільного тексту застосувати неможливо
    # (немає структури), тож для логів діє вужчий, але детермінований
    # інваріант.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][string[]]$Lines)

    $lineNumber = 0
    foreach ($line in @($Lines)) {
        $lineNumber++
        if ($null -eq $line) { continue }
        if ($line -match $script:BRAVOPilotEmbeddedUriCredentialPattern) {
            throw "SECRET_SAFE_VIOLATION: рядок $lineNumber виводу дочірнього процесу містить embedded credential у URI — запис evidence заблоковано (fail closed). Перевірте команду, що породила цей вивід."
        }
    }
}

function Write-BRAVOPilotEvidenceJson {
    # Канонічний writer для JSON-evidence: секретна перевірка ПЕРЕД
    # записом, UTF-8 без BOM (узгоджено з рештою репозиторію — див.
    # ci\New-BRAVOReleaseArtifact.ps1, deploy\Get-BRAVOConfigSiteDelta.ps1).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Object,
        [int]$Depth = 10
    )

    Assert-BRAVOPilotEvidenceSecretSafe -Object $Object
    $json = $Object | ConvertTo-Json -Depth $Depth
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-BRAVOPilotEvidenceText {
    # Захоплений вивід дочірнього canonical-скрипта (BRAVO_SETUP.ps1,
    # BRAVO_SELF_TEST.ps1, BRAVO_HEALTH.ps1, BRAVO_DRY_RUN.ps1) легітимно
    # може виявитись порожнім масивом — коли дочірній скрипт завершується
    # аварійно настільки рано, що ще нічого не встиг записати ні в
    # success-, ні в error-стрім (0 рядків — це правдивий діагностичний
    # стан, а не помилка виклику). Без [AllowEmptyCollection()] типізований
    # масив-параметр за замовчуванням відхиляє порожній (не $null) масив
    # (ParameterArgumentValidationErrorEmptyArrayNotAllowed), що ховає
    # первинну помилку дочірнього скрипта за вторинним необробленим
    # винятком тут.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][string[]]$Lines
    )

    Assert-BRAVOPilotTextSecretSafe -Lines $Lines
    $text = [string]::Join([Environment]::NewLine, @($Lines))
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# --- Хешування / SHA-256 ----------------------------------------------------

function Get-BRAVOPilotFileHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# --- State machine -----------------------------------------------------------

# Легальні переходи стану пілота. Ключ = поточний стан, значення = дозволені
# наступні стани. NotStarted не з'являється як ключ — це стан "метадані ще не
# записані", а не явний state-запис.
$script:BRAVOPilotStateTransitions = @{
    'PreflightPassed'  = @('BaselineCaptured', 'Failed')
    'BaselineCaptured' = @('DeltaGenerated', 'Failed')
    'DeltaGenerated'   = @('Reviewed', 'DeltaGenerated', 'Failed')
    'Reviewed'         = @('BackupCreated', 'Reviewed', 'Failed')
    'BackupCreated'    = @('Activated', 'Failed', 'RolledBack')
    'Activated'        = @('Validated', 'Failed', 'RolledBack')
    'Validated'        = @('Accepted', 'Failed', 'RolledBack')
    'Accepted'         = @('RolledBack')
    'Failed'           = @('RolledBack', 'BackupCreated', 'Activated', 'Validated')
    'RolledBack'       = @()
}

function Get-BRAVOPilotMetadataPath {
    param([Parameter(Mandatory = $true)][string]$EvidenceDir)
    return (Join-Path $EvidenceDir 'metadata.json')
}

function Get-BRAVOPilotState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$EvidenceDir)

    $metadataPath = Get-BRAVOPilotMetadataPath -EvidenceDir $EvidenceDir
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Set-BRAVOPilotState {
    # Записує новий стан з перевіркою легальності переходу. Fail closed на
    # нелегальному переході (оператор не може випадково пропустити крок).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EvidenceDir,
        [Parameter(Mandatory = $true)][ValidateSet(
            'PreflightPassed', 'BaselineCaptured', 'DeltaGenerated', 'Reviewed',
            'BackupCreated', 'Activated', 'Validated', 'Accepted', 'RolledBack', 'Failed'
        )][string]$State,
        [hashtable]$ExtraFields
    )

    $current = Get-BRAVOPilotState -EvidenceDir $EvidenceDir
    $currentState = if ($null -eq $current) { $null } else { [string]$current.State }

    if ([string]::IsNullOrEmpty($currentState)) {
        if ($State -ne 'PreflightPassed') {
            throw "PILOT_STATE_VIOLATION: перший стан pilot-каталогу доказів мусить бути 'PreflightPassed', отримано запит на '$State'."
        }
    } elseif ($currentState -eq $State) {
        # Ідемпотентний повторний запис того самого стану (наприклад,
        # повторний -Prepare) — дозволено, не вважається переходом.
    } elseif (-not $script:BRAVOPilotStateTransitions.ContainsKey($currentState) -or
              $script:BRAVOPilotStateTransitions[$currentState] -notcontains $State) {
        throw "PILOT_STATE_VIOLATION: перехід '$currentState' -> '$State' не дозволений. Дозволені переходи з '$currentState': $([string]::Join(', ', @($script:BRAVOPilotStateTransitions[$currentState])))."
    }

    $record = [ordered]@{
        State           = $State
        PreviousState   = $currentState
        UpdatedAtUtc    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        ServerId        = if ($null -ne $current -and $current.PSObject.Properties['ServerId']) { [string]$current.ServerId } else { [string]$env:COMPUTERNAME }
        Operator        = [string]$env:USERNAME
    }
    if ($null -ne $ExtraFields) {
        foreach ($key in $ExtraFields.Keys) { $record[$key] = $ExtraFields[$key] }
    }
    if ($null -ne $current) {
        # Історія станів зберігається — потрібна для acceptance.json і
        # troubleshooting; це евіденс, не приховане поле.
        $history = @()
        if ($current.PSObject.Properties['History']) { $history = @($current.History) }
        $history += [pscustomobject]@{ State = $currentState; AtUtc = [string]$current.UpdatedAtUtc }
        $record['History'] = $history
    } else {
        $record['History'] = @()
    }

    Write-BRAVOPilotEvidenceJson -Path (Get-BRAVOPilotMetadataPath -EvidenceDir $EvidenceDir) -Object $record
    return [pscustomobject]$record
}

function Assert-BRAVOPilotState {
    # Гейт-перевірка: mutating-операція вимагає точного поточного стану.
    param(
        [Parameter(Mandatory = $true)][string]$EvidenceDir,
        [Parameter(Mandatory = $true)][string[]]$RequiredState,
        [Parameter(Mandatory = $true)][string]$Operation
    )
    $current = Get-BRAVOPilotState -EvidenceDir $EvidenceDir
    $currentState = if ($null -eq $current) { '(немає)' } else { [string]$current.State }
    if ($null -eq $current -or $RequiredState -notcontains $currentState) {
        throw "PILOT_STATE_VIOLATION: '$Operation' вимагає стану [$([string]::Join(', ', $RequiredState))], поточний стан: '$currentState'. Виконайте попередні кроки по порядку."
    }
    return $current
}

# --- Evidence directory ------------------------------------------------------

function New-BRAVOPilotEvidenceDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [string]$ServerId = $env:COMPUTERNAME
    )

    if (-not (Test-Path -LiteralPath $EvidenceRoot)) {
        [void](New-Item -ItemType Directory -Path $EvidenceRoot -Force)
    }
    $stampUtc = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $safeServerId = ($ServerId -replace '[^A-Za-z0-9_.-]', '_')
    $dir = Join-Path $EvidenceRoot "$safeServerId-$stampUtc"
    if (Test-Path -LiteralPath $dir) {
        throw "PILOT_EVIDENCE_COLLISION: каталог доказів '$dir' уже існує — повторіть за секунду (унікальність за timestamp)."
    }
    [void](New-Item -ItemType Directory -Path $dir -Force)
    return $dir
}

# --- Preflight (read-only) ---------------------------------------------------

function Test-BRAVOPilotWritableDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            [void](New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop)
        }
        $probe = Join-Path $Path (".bravo-pilot-write-probe-{0}.tmp" -f ([Guid]::NewGuid().ToString('N')))
        [System.IO.File]::WriteAllText($probe, 'probe', (New-Object System.Text.UTF8Encoding($false)))
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Invoke-BRAVOPilotPreflight {
    # READ-ONLY. Нічого не змінює на сервері й нічого не персистить —
    # викликач вирішує, чи зберігати результат як evidence (§10: "Не
    # створювати machine state під час чистого -Preflight").
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$ArtifactRoot,
        [string]$EvidenceRoot
    )

    $checks = New-Object System.Collections.Generic.List[object]
    function private:Add-Check([string]$Name, [bool]$Pass, [string]$Detail, [bool]$Blocking = $true) {
        $checks.Add([pscustomobject]@{ Name = $Name; Pass = $Pass; Blocking = $Blocking; Detail = $Detail })
    }

    # Windows / PowerShell
    $isWindows = $env:OS -eq 'Windows_NT'
    Add-Check 'Windows' $isWindows ("OS={0}" -f $env:OS)
    $psOk = $PSVersionTable.PSVersion.Major -ge 5
    Add-Check 'PowerShellVersionMinimum5' $psOk ("PSVersion={0}" -f $PSVersionTable.PSVersion.ToString())

    # Адміністратор
    $isAdmin = $false
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $isAdmin = $false }
    Add-Check 'RunningAsAdministrator' $isAdmin ("IsAdmin={0}" -f $isAdmin)

    # BRAVO installation path + canonical tools present
    $installRootExists = Test-Path -LiteralPath $InstallRoot -PathType Container
    Add-Check 'InstallRootExists' $installRootExists ("InstallRoot={0}" -f $InstallRoot)

    $requiredTool = @(
        'BRAVO_SETUP.ps1', 'BRAVO_SELF_TEST.ps1', 'BRAVO_HEALTH.ps1',
        'BRAVO_CONFIG_TEST.ps1', 'BRAVO_DRY_RUN.ps1', 'BRAVO_CONFIG_LOADER.ps1'
    )
    foreach ($tool in $requiredTool) {
        $toolPath = Join-Path $InstallRoot $tool
        $exists = $installRootExists -and (Test-Path -LiteralPath $toolPath -PathType Leaf)
        Add-Check "InstallRootHas_$tool" $exists ("Path={0}" -f $toolPath)
    }
    foreach ($tool in @('deploy\Get-BRAVOConfigSiteDelta.ps1', 'deploy\Compare-BRAVOConfigEffectiveSnapshot.ps1')) {
        $toolPath = Join-Path $InstallRoot $tool
        $exists = $installRootExists -and (Test-Path -LiteralPath $toolPath -PathType Leaf)
        Add-Check "InstallRootHas_$tool" $exists ("Path={0}" -f $toolPath)
    }

    # Configuration v2 прекваліфікація — той самий файл, що встановлює
    # передумову #1 у прийнятому вручну runbook.
    $snapshotModulePath = Join-Path $InstallRoot 'modules\BRAVO.Configuration\BRAVO.Configuration.Snapshot.psd1'
    $configV2Present = $installRootExists -and (Test-Path -LiteralPath $snapshotModulePath -PathType Leaf)
    Add-Check 'InstallRootHasConfigurationV2Support' $configV2Present ("Snapshot module: {0}" -f $snapshotModulePath)

    # BRAVO.config / BRAVO.local.config
    $bravoConfigPath = Join-Path $InstallRoot 'BRAVO.config'
    $bravoConfigExists = $installRootExists -and (Test-Path -LiteralPath $bravoConfigPath -PathType Leaf)
    Add-Check 'BRAVOConfigExists' $bravoConfigExists ("Path={0}" -f $bravoConfigPath)

    $bravoLocalConfigPath = Join-Path $InstallRoot 'BRAVO.local.config'
    $bravoLocalConfigExists = $installRootExists -and (Test-Path -LiteralPath $bravoLocalConfigPath -PathType Leaf)
    Add-Check 'BRAVOLocalConfigState' $true ("Присутній={0} (інформаційно — не блокує)" -f $bravoLocalConfigExists) $false

    # VERSION / provenance
    $versionPath = Join-Path $InstallRoot 'VERSION.json'
    $versionInfo = $null
    $versionOk = $false
    if ($installRootExists -and (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
        try {
            $versionInfo = Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $versionOk = $true
        } catch { $versionOk = $false }
    }
    Add-Check 'VersionProvenanceReadable' $versionOk $(
        if ($versionOk) { "packageVersion={0} buildId={1} configSchemaVersion={2}" -f $versionInfo.packageVersion, $versionInfo.buildId, $versionInfo.configSchemaVersion }
        else { "Не вдалося прочитати $versionPath" }
    )

    # Вільне місце (InstallRoot volume + evidence destination volume)
    function private:Get-FreeSpaceGb([string]$Path) {
        try {
            $root = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Path).ProviderPath)
            $drive = Get-PSDrive -Name $root.TrimEnd('\', ':').Substring(0, 1) -ErrorAction Stop
            return [math]::Round($drive.Free / 1GB, 2)
        } catch { return -1 }
    }
    $installFreeGb = if ($installRootExists) { Get-FreeSpaceGb -Path $InstallRoot } else { -1 }
    Add-Check 'InstallRootFreeSpaceMinimum1Gb' ($installFreeGb -ge 1) ("FreeGb={0}" -f $installFreeGb)

    if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
        $evidenceWritable = Test-BRAVOPilotWritableDirectory -Path $EvidenceRoot
        Add-Check 'EvidenceDestinationWritable' $evidenceWritable ("EvidenceRoot={0}" -f $EvidenceRoot)
        $evFreeGb = Get-FreeSpaceGb -Path $EvidenceRoot
        Add-Check 'EvidenceDestinationFreeSpaceMinimum1Gb' ($evFreeGb -ge 1) ("FreeGb={0}" -f $evFreeGb)
        # Backup поки що записується всередині evidence-каталогу — та сама
        # перевірка писемості покриває й "backup destination writable".
        Add-Check 'BackupDestinationWritable' $evidenceWritable ("Backup зберігається всередині EvidenceRoot")
    } else {
        Add-Check 'EvidenceDestinationWritable' $true "EvidenceRoot не задано для цього прогону Preflight (лише перевірка сервера)" $false
    }

    # Artifact integrity/provenance — делегується канонічному верифікатору,
    # якщо він поруч (щоб не дублювати перевірку hash/manifest тут ще раз).
    $verifierPath = Join-Path $ArtifactRoot 'Test-BRAVOConfigV2PilotArtifact.ps1'
    if (Test-Path -LiteralPath $verifierPath -PathType Leaf) {
        $verifyOutput = & $verifierPath -ArtifactRoot $ArtifactRoot -Quiet 2>&1
        $verifyOk = (Get-BRAVOPilotSafeLastExitCode) -eq 0
        Add-Check 'ArtifactIntegrityAndProvenance' $verifyOk ([string]::Join(' | ', @($verifyOutput | Select-Object -Last 5)))
    } else {
        Add-Check 'ArtifactIntegrityAndProvenance' $false ("Verifier не знайдено: {0}" -f $verifierPath)
    }

    # Scheduled archive state — best-effort, НЕ блокуюча (визначено "where
    # determinable" у ТЗ).
    $archiveTaskState = 'Невизначено'
    try {
        $tasks = @(Get-ScheduledTask -TaskName 'BRAVO*' -ErrorAction SilentlyContinue)
        if ($tasks.Count -gt 0) {
            $running = @($tasks | Where-Object { $_.State -eq 'Running' })
            $archiveTaskState = if ($running.Count -gt 0) { "Running: $([string]::Join(', ', @($running | ForEach-Object { $_.TaskName })))" } else { 'Idle' }
        }
    } catch { $archiveTaskState = 'Невизначено (Get-ScheduledTask недоступний)' }
    Add-Check 'ScheduledArchiveStateWhereDeterminable' ($archiveTaskState -notlike 'Running:*') ("State=$archiveTaskState") $false

    # Credential Manager references — лише ІСНУВАННЯ, значення ніколи не
    # читається й не логується (cmdkey /list ніколи не показує пароль).
    $credentialTargets = @('BRAVO_SFTP_PASSWORD', 'BRAVO_SMB_PASSWORD')
    $credentialFindings = New-Object System.Collections.Generic.List[string]
    foreach ($target in $credentialTargets) {
        try {
            $listOutput = (& cmdkey.exe /list:$target) 2>&1 | Out-String
            $found = $listOutput -notmatch '(?i)No matching credentials|не знайдено відповідних облікових даних'
            $credentialFindings.Add("$target=$(if ($found) { 'Found' } else { 'Missing' })")
        } catch {
            $credentialFindings.Add("$target=Undetermined")
        }
    }
    Add-Check 'CredentialManagerReferencesCheckedWithoutResolving' $true ([string]::Join('; ', $credentialFindings)) $false

    $blockingFailed = @($checks | Where-Object { $_.Blocking -and -not $_.Pass })
    $result = [pscustomobject]@{
        RanAtUtc     = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        InstallRoot  = $InstallRoot
        ArtifactRoot = $ArtifactRoot
        Pass         = ($blockingFailed.Count -eq 0)
        Checks       = $checks.ToArray()
        FailedBlockingChecks = @($blockingFailed | ForEach-Object { $_.Name })
    }
    return $result
}

# --- BEFORE/AFTER snapshot + health ------------------------------------------

function Invoke-BRAVOPilotConfigSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $configTestPath = Join-Path $InstallRoot 'BRAVO_CONFIG_TEST.ps1'
    if (-not (Test-Path -LiteralPath $configTestPath -PathType Leaf)) {
        throw "PILOT_SNAPSHOT_FAILED: не знайдено $configTestPath."
    }

    $json = & $configTestPath -FullGraph
    $snapshotExitCode = Get-BRAVOPilotSafeLastExitCode
    if ($snapshotExitCode -ne 0 -or [string]::IsNullOrWhiteSpace(($json | Out-String))) {
        throw "PILOT_SNAPSHOT_FAILED: BRAVO_CONFIG_TEST.ps1 -FullGraph завершився з кодом $snapshotExitCode або порожнім виводом — конфігурація, яка не завантажується, не може бути знята як baseline."
    }
    $text = ($json | Out-String).Trim()
    if (-not $text.StartsWith('{')) {
        throw "PILOT_SNAPSHOT_FAILED: вивід BRAVO_CONFIG_TEST.ps1 -FullGraph не є JSON-об'єктом (не починається з '{')."
    }

    # Валідація структури ДО запису — рання відмова краще, ніж записаний,
    # але непридатний для Compare-BRAVOConfigEffectiveSnapshot.ps1 файл.
    $parsed = $text | ConvertFrom-Json
    if ($null -eq $parsed.PSObject.Properties['EffectiveGraph']) {
        throw "PILOT_SNAPSHOT_FAILED: знімок не містить EffectiveGraph — очікується вивід саме -FullGraph."
    }

    # Секретна перевірка ОБОВ'ЯЗКОВА тут: EffectiveGraph містить
    # credentialSettings/backupMonitoring.SFTP.*.Password — Configuration
    # v2 гарантує, що це REFERENCE-ім'я, а не резолвнутий секрет
    # (PilotSafety/CredentialReferenceNeverResolved), але цей знімок —
    # межа довіри evidence-пакета, і перевірка тут — defense-in-depth,
    # не довіра лише архітектурній гарантії десь-інде.
    Assert-BRAVOPilotEvidenceSecretSafe -Object $parsed

    [System.IO.File]::WriteAllText($OutputPath, $text, (New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Path = $OutputPath; PackageVersion = [string]$parsed.Validation.PackageVersion; ConfigSchemaVersion = [string]$parsed.Validation.ConfigSchemaVersion }
}

function Invoke-BRAVOPilotHealthSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )
    $healthPath = Join-Path $InstallRoot 'BRAVO_HEALTH.ps1'
    if (-not (Test-Path -LiteralPath $healthPath -PathType Leaf)) {
        throw "PILOT_HEALTH_FAILED: не знайдено $healthPath."
    }
    $output = @(& $healthPath -NoPause 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = Get-BRAVOPilotSafeLastExitCode
    Write-BRAVOPilotEvidenceText -Path $OutputPath -Lines $output
    return [pscustomobject]@{ Path = $OutputPath; ExitCode = $exitCode; Lines = $output }
}

function Get-BRAVOPilotHealthDegradationLines {
    # Best-effort структурне порівняння: BRAVO_HEALTH.ps1 не має
    # окремого machine-readable diff-контракту (задокументовано в runbook,
    # "Відомі межі процедури"), тому порівнюються МАРКОВАНІ проблемні рядки
    # ([CRITICAL]/[FAIL]/[ERROR]), а не побайтова рівність усього виводу —
    # часові мітки й лічильники в health legітимно різняться між прогонами.
    param(
        [Parameter(Mandatory = $true)][AllowNull()][string[]]$BeforeLines,
        [Parameter(Mandatory = $true)][AllowNull()][string[]]$AfterLines
    )
    $pattern = '(?i)\[(CRITICAL|FAIL|ERROR)\]'
    $before = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in @($BeforeLines)) { if ($line -match $pattern) { [void]$before.Add($line.Trim()) } }
    $newDegradations = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($AfterLines)) {
        if ($line -match $pattern -and -not $before.Contains($line.Trim())) {
            $newDegradations.Add($line.Trim())
        }
    }
    return $newDegradations.ToArray()
}

# --- Delta generation ---------------------------------------------------------

function Invoke-BRAVOPilotDeltaGeneration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$CandidatePath
    )
    $deltaToolPath = Join-Path $InstallRoot 'deploy\Get-BRAVOConfigSiteDelta.ps1'
    if (-not (Test-Path -LiteralPath $deltaToolPath -PathType Leaf)) {
        throw "PILOT_DELTA_FAILED: не знайдено $deltaToolPath."
    }
    if (Test-Path -LiteralPath $CandidatePath) {
        throw "PILOT_DELTA_FAILED: candidate-файл '$CandidatePath' уже існує — інструмент дельти нічого не перезаписує (ідемпотентний повторний прогін мусить вказати новий шлях або спершу прибрати попередній candidate свідомо)."
    }
    # Захоплюємо stdout ЯВНО: без цього консольний вивід інструмента
    # (текст дельти, [INFO]-рядки) потрапляє у вихідний потік ЦІЄЇ функції
    # й домішується до `return [pscustomobject]` нижче, перетворюючи
    # результат на масив замість очікуваного об'єкта.
    & $deltaToolPath -RuntimeRoot $InstallRoot -OutputPath $CandidatePath | Out-Null
    # Get-BRAVOConfigSiteDelta.ps1 НЕ викликає `exit 0` на щасливому шляху
    # (лише `exit 1` у catch) — $LASTEXITCODE на успіху непередбачуваний
    # (може лишитись від попередньої команди). Первинний доказ успіху —
    # сам факт створення candidate-файлу; $LASTEXITCODE перевіряється лише
    # як додатковий сигнал явної відмови, коли файл НЕ створено.
    if (-not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) {
        throw "PILOT_DELTA_FAILED: Get-BRAVOConfigSiteDelta.ps1 не створив candidate-файл (код завершення $(Get-BRAVOPilotSafeLastExitCode))."
    }

    # Секретна перевірка candidate — рядок за рядком, ключ+значення. На
    # відміну від JSON-знімків, candidate генерує canonical інструмент
    # ПРЯМО з raw BRAVO.config сайту: якщо сам сайт-файл колись помилково
    # містив резолвнутий секрет замість reference-імені (не гарантія
    # Configuration v2 — гарантія стосується ЕФЕКТИВНОГО графа, не
    # довільного вхідного BRAVO.config), candidate відтворив би це
    # буквально. Fail closed ДО показу diff оператору.
    $candidateLines = @(Get-Content -LiteralPath $CandidatePath -Encoding UTF8)
    foreach ($line in $candidateLines) {
        if ($line -match "(?i)^\s*'([^']*(?:$($script:BRAVOPilotSensitiveKeyPattern -replace '^\(\?i\)',''))[^']*)'\s*=\s*'([^']*)'") {
            $lineKey = $Matches[1]
            $lineValue = $Matches[2]
            if (-not (Test-BRAVOPilotSecretSafeString -Value $lineValue -KeyName $lineKey)) {
                throw "SECRET_SAFE_VIOLATION: candidate-рядок для '$lineKey' виглядає як реальний секрет, а не Credential Manager reference-ім'я. Перенесення заблоковано (fail closed) — перевірте BRAVO.config сайту вручну."
            }
        }
    }
    Assert-BRAVOPilotTextSecretSafe -Lines $candidateLines

    return [pscustomobject]@{
        Path = $CandidatePath
        Sha256 = (Get-BRAVOPilotFileHash -Path $CandidatePath)
    }
}

function Test-BRAVOPilotCandidateSyntax {
    # Захист-в-глибину ПЕРЕД активацією: candidate мусить бути лише
    # data-only PowerShell літералом (@{ ... } з константними значеннями),
    # без викликів команд — та сама вимога, що й canonical local-config
    # reader (BRAVO_CONFIG_LOADER.ps1, Read-BRAVOLocalConfigurationOverrides).
    # Авторитетний gate лишається -ValidateOnly ПІСЛЯ активації; це —
    # рання, дешева перевірка, а не друга копія canonical-парсера.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CandidatePath)

    if (-not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) {
        throw "PILOT_CANDIDATE_INVALID: candidate-файл '$CandidatePath' не знайдено."
    }
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($CandidatePath, [ref]$tokens, [ref]$errors)
    if ($null -ne $errors -and $errors.Count -gt 0) {
        $messages = @($errors | ForEach-Object { $_.Message })
        throw "PILOT_CANDIDATE_INVALID: candidate не парситься як PowerShell: $([string]::Join('; ', $messages))"
    }
    # $true/$false/$null НЕ є "змінними" семантично (константні літерали),
    # але PowerShell AST представляє їх саме як VariableExpressionAst з
    # VariablePath.UserPath = 'true'/'false'/'null' — без цього винятку
    # БУДЬ-ЯКИЙ data-only candidate із boolean/null-значенням (звичайний,
    # представницький site-override, напр. componentSettings.Archive.X =
    # $false) хибно відхилявся б як "містить змінні" (виявлено реальним
    # VM pilot-прогоном 2026-09-17: boolean-override з delta.preview.txt
    # блокував -Activate на повністю легітимному кандидаті).
    $allowedAutomaticVariableNames = @('true', 'false', 'null')
    $forbidden = $ast.FindAll({
        param($node)
        ($node -is [System.Management.Automation.Language.CommandAst]) -or
        ($node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) -or
        (
            ($node -is [System.Management.Automation.Language.VariableExpressionAst]) -and
            ($allowedAutomaticVariableNames -notcontains $node.VariablePath.UserPath)
        )
    }, $true)
    if (@($forbidden).Count -gt 0) {
        throw "PILOT_CANDIDATE_INVALID: candidate містить виклики команд/методів або змінні — дозволені лише data-only літерали (@{ 'path' = <literal> }; \$true/\$false/\$null дозволені як константи)."
    }
    $hashtableCount = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $false)).Count
    if ($hashtableCount -lt 1) {
        throw "PILOT_CANDIDATE_INVALID: candidate не містить top-level hashtable-літерала (@{ ... })."
    }
    return $true
}

# --- Human review / approval hash-binding ------------------------------------

function Get-BRAVOPilotHumanReviewPath {
    param([Parameter(Mandatory = $true)][string]$EvidenceDir)
    return (Join-Path $EvidenceDir 'human-review.json')
}

function Approve-BRAVOPilotCandidate {
    # Explicit approval, прив'язаний до hash. Якщо candidate змінився з
    # моменту, коли оператору показали hash (-Prepare вивід) — approval
    # відхиляється fail-closed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EvidenceDir,
        [Parameter(Mandatory = $true)][string]$CandidatePath,
        [Parameter(Mandatory = $true)][string]$ApprovedCandidateHash,
        [string]$Operator = $env:USERNAME
    )

    if (-not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) {
        throw "PILOT_APPROVAL_FAILED: candidate-файл '$CandidatePath' не знайдено."
    }
    $currentHash = Get-BRAVOPilotFileHash -Path $CandidatePath
    if ($currentHash -ne $ApprovedCandidateHash.ToUpperInvariant()) {
        throw "PILOT_APPROVAL_FAILED: поточний SHA-256 candidate ('$currentHash') НЕ збігається з переданим -ApprovedCandidateHash ('$ApprovedCandidateHash'). Candidate змінився після показу diff оператору — перезапустіть -Prepare і перегляньте дельту заново. NO ACTIVATION."
    }

    $record = [ordered]@{
        ReviewedAtUtc  = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Operator       = $Operator
        CandidatePath  = $CandidatePath
        CandidateHash  = $currentHash
        Approved       = $true
    }
    Write-BRAVOPilotEvidenceJson -Path (Get-BRAVOPilotHumanReviewPath -EvidenceDir $EvidenceDir) -Object $record
    return [pscustomobject]$record
}

# --- Backup -------------------------------------------------------------------

function New-BRAVOPilotBackup {
    # Дзеркалить Крок 2а прийнятого вручну runbook побайтово.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$EvidenceDir
    )

    $stampUtc = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    # Суфікс GUID — захист від колізії каталогу, якщо цю функцію викликано
    # двічі в межах тієї самої секунди (секундна точність timestamp);
    # без цього другий виклик дописав би файли в каталог першого backup і
    # зіпсував би вже записаний backup-manifest.json.
    $backupDir = Join-Path $EvidenceDir ("backup-{0}-{1}" -f $stampUtc, ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
    if (Test-Path -LiteralPath $backupDir) {
        throw "PILOT_BACKUP_FAILED: каталог backup '$backupDir' уже існує — повторіть операцію."
    }
    [void](New-Item -ItemType Directory -Path $backupDir -Force)

    $bravoConfigPath = Join-Path $InstallRoot 'BRAVO.config'
    $bravoLocalConfigPath = Join-Path $InstallRoot 'BRAVO.local.config'

    if (-not (Test-Path -LiteralPath $bravoConfigPath -PathType Leaf)) {
        throw "PILOT_BACKUP_FAILED: '$bravoConfigPath' не знайдено — BRAVO.config мусить лишатись присутнім на цьому етапі pilot."
    }
    Copy-Item -LiteralPath $bravoConfigPath -Destination (Join-Path $backupDir 'BRAVO.config') -ErrorAction Stop

    if (Test-Path -LiteralPath $bravoLocalConfigPath -PathType Leaf) {
        Copy-Item -LiteralPath $bravoLocalConfigPath -Destination (Join-Path $backupDir 'BRAVO.local.config') -ErrorAction Stop
    } else {
        Set-Content -LiteralPath (Join-Path $backupDir 'BRAVO.local.config.absent') `
            -Value "BRAVO.local.config був відсутній на момент backup ($stampUtc UTC)." -Encoding UTF8 -ErrorAction Stop
    }

    $manifest = Get-ChildItem -LiteralPath $backupDir -File | ForEach-Object {
        [pscustomobject]@{
            File         = $_.Name
            SHA256       = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            SizeBytes    = $_.Length
            TimestampUtc = $stampUtc
        }
    }
    Write-BRAVOPilotEvidenceJson -Path (Join-Path $backupDir 'backup-manifest.json') -Object @($manifest)

    return [pscustomobject]@{ BackupDir = $backupDir; Manifest = @($manifest) }
}

function Test-BRAVOPilotBackupIntegrity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$BackupDir)

    $manifestPath = Join-Path $BackupDir 'backup-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "PILOT_BACKUP_INTEGRITY_FAILED: '$manifestPath' не знайдено."
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($entry in @($manifest)) {
        $entryPath = Join-Path $BackupDir $entry.File
        if (-not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
            throw "PILOT_BACKUP_INTEGRITY_FAILED: backup-файл '$($entry.File)' відсутній у '$BackupDir'."
        }
        $actualHash = Get-BRAVOPilotFileHash -Path $entryPath
        if ($actualHash -ne $entry.SHA256) {
            throw "PILOT_BACKUP_INTEGRITY_FAILED: SHA-256 '$($entry.File)' ($actualHash) не збігається з backup-manifest.json ($($entry.SHA256)) — резервна копія пошкоджена."
        }
    }
    return $true
}

# --- Activation -----------------------------------------------------------

function Test-BRAVOPilotActivationIsNoOp {
    # Ідемпотентність: якщо на сервері вже діє BRAVO.local.config з тим
    # самим hash, що й candidate — повторна активація не пише файл вдруге.
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$CandidatePath
    )
    $targetPath = Join-Path $InstallRoot 'BRAVO.local.config'
    if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) { return $false }
    return (Get-BRAVOPilotFileHash -Path $targetPath) -eq (Get-BRAVOPilotFileHash -Path $CandidatePath)
}

function Invoke-BRAVOPilotAtomicActivation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$CandidatePath,
        [Parameter(Mandatory = $true)][string]$EvidenceDir,
        [Parameter(Mandatory = $true)][string]$ApprovedCandidateHash
    )

    # TOCTOU-захист: candidate мусить лишатись побайтово тим самим, що й
    # затверджений у human-review.json — між Approve і Activate файл міг
    # змінитись (навмисно чи ні).
    $currentHash = Get-BRAVOPilotFileHash -Path $CandidatePath
    if ($currentHash -ne $ApprovedCandidateHash) {
        throw "PILOT_ACTIVATION_FAILED: SHA-256 candidate на момент активації ('$currentHash') не збігається із затвердженим у human-review.json ('$ApprovedCandidateHash'). NO ACTIVATION — candidate змінився після approval."
    }

    Test-BRAVOPilotCandidateSyntax -CandidatePath $CandidatePath | Out-Null

    $targetPath = Join-Path $InstallRoot 'BRAVO.local.config'
    $tempPath = "$targetPath.pilot-candidate-$([Guid]::NewGuid().ToString('N')).tmp"

    # Уся решта — від перевірки no-op (яка сама читає $targetPath і тому
    # теж може впасти на заблокованому файлі) до атомарної заміни — під
    # ОДНИМ try/catch: викликачу потрібен однаковий діагностований
    # PILOT_ACTIVATION_FAILED незалежно від того, на якому саме кроці
    # процес, що тримає файл відкритим, завадив активації.
    try {
        if (Test-BRAVOPilotActivationIsNoOp -InstallRoot $InstallRoot -CandidatePath $CandidatePath) {
            return [pscustomobject]@{ Activated = $true; NoOp = $true; TargetPath = $targetPath }
        }

        Copy-Item -LiteralPath $CandidatePath -Destination $tempPath -ErrorAction Stop

        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            $replaceBackupPath = "$targetPath.pilot-replace-backup.tmp"
            if (Test-Path -LiteralPath $replaceBackupPath) { Remove-Item -LiteralPath $replaceBackupPath -Force -ErrorAction Stop }
            [System.IO.File]::Replace($tempPath, $targetPath, $replaceBackupPath)
            if (Test-Path -LiteralPath $replaceBackupPath) { Remove-Item -LiteralPath $replaceBackupPath -Force -ErrorAction Stop }
        } else {
            [System.IO.File]::Move($tempPath, $targetPath)
        }
    } catch {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        throw "PILOT_ACTIVATION_FAILED: активація '$targetPath' провалилась: $($_.Exception.Message). Оригінальний файл лишається незмінним (File.Replace/Move — atomic on NTFS)."
    }

    $finalHash = Get-BRAVOPilotFileHash -Path $targetPath
    if ($finalHash -ne $ApprovedCandidateHash) {
        throw "PILOT_ACTIVATION_FAILED: SHA-256 активованого файлу ('$finalHash') не збігається з очікуваним ('$ApprovedCandidateHash') — часткова активація. НЕГАЙНО виконайте -Rollback."
    }

    return [pscustomobject]@{ Activated = $true; NoOp = $false; TargetPath = $targetPath; Sha256 = $finalHash }
}

# --- Validate / parity / self-test / health / archive smoke -----------------

function Invoke-BRAVOPilotValidateOnly {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )
    $setupPath = Join-Path $InstallRoot 'BRAVO_SETUP.ps1'
    if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
        throw "PILOT_VALIDATE_FAILED: не знайдено $setupPath."
    }
    $output = @(& $setupPath -ValidateOnly -NoPause 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = Get-BRAVOPilotSafeLastExitCode
    Write-BRAVOPilotEvidenceText -Path $OutputPath -Lines $output
    return [pscustomobject]@{ ExitCode = $exitCode; Pass = ($exitCode -eq 0); Path = $OutputPath }
}

function Invoke-BRAVOPilotSemanticParity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$BeforePath,
        [Parameter(Mandatory = $true)][string]$AfterPath,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )
    $comparePath = Join-Path $InstallRoot 'deploy\Compare-BRAVOConfigEffectiveSnapshot.ps1'
    if (-not (Test-Path -LiteralPath $comparePath -PathType Leaf)) {
        throw "PILOT_PARITY_FAILED: не знайдено $comparePath."
    }
    $output = @(& $comparePath -BeforePath $BeforePath -AfterPath $AfterPath -RuntimeRoot $InstallRoot 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = Get-BRAVOPilotSafeLastExitCode
    $record = [ordered]@{
        RanAtUtc  = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        BeforePath = $BeforePath
        AfterPath  = $AfterPath
        ExitCode   = $exitCode
        Pass       = ($exitCode -eq 0)
        Output     = $output
    }
    Write-BRAVOPilotEvidenceJson -Path $OutputPath -Object $record
    return [pscustomobject]$record
}

function Invoke-BRAVOPilotSelfTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )
    $selfTestPath = Join-Path $InstallRoot 'BRAVO_SELF_TEST.ps1'
    if (-not (Test-Path -LiteralPath $selfTestPath -PathType Leaf)) {
        throw "PILOT_SELFTEST_FAILED: не знайдено $selfTestPath."
    }
    $output = @(& $selfTestPath -NoPause 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = Get-BRAVOPilotSafeLastExitCode
    Write-BRAVOPilotEvidenceText -Path $OutputPath -Lines $output

    $hasUnavailable = @($output | Where-Object { $_ -match '\[НЕДОСТУПНО\]' }).Count -gt 0
    $hasFail = @($output | Where-Object { $_ -match '\[FAIL\]' }).Count -gt 0
    # Acceptance-контракт OPERATIONS.md/RELEASE_POLICY.md: exit 0 САМ ПО
    # СОБІ недостатній — [НЕДОСТУПНО] має бути відсутній.
    $pass = ($exitCode -eq 0) -and (-not $hasUnavailable) -and (-not $hasFail)
    return [pscustomobject]@{
        ExitCode = $exitCode; Pass = $pass; HasUnavailable = $hasUnavailable; HasFail = $hasFail; Path = $OutputPath
    }
}

function Invoke-BRAVOPilotHealthCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [string[]]$BeforeLines
    )
    $result = Invoke-BRAVOPilotHealthSnapshot -InstallRoot $InstallRoot -OutputPath $OutputPath
    $newDegradations = @()
    if ($null -ne $BeforeLines) {
        # @(...) обов'язковий: порожній масив, повернений через `return`,
        # PowerShell розгортає в $null — без обгортки .Count нижче впав би
        # під Set-StrictMode ("The property 'Count' cannot be found").
        $newDegradations = @(Get-BRAVOPilotHealthDegradationLines -BeforeLines $BeforeLines -AfterLines $result.Lines)
    }
    $pass = ($newDegradations.Count -eq 0)
    return [pscustomobject]@{ ExitCode = $result.ExitCode; Pass = $pass; NewDegradations = $newDegradations; Path = $OutputPath }
}

function Invoke-BRAVOPilotArchiveSmoke {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )
    $dryRunPath = Join-Path $InstallRoot 'BRAVO_DRY_RUN.ps1'
    if (-not (Test-Path -LiteralPath $dryRunPath -PathType Leaf)) {
        throw "PILOT_ARCHIVE_SMOKE_FAILED: не знайдено $dryRunPath."
    }
    $output = @(& $dryRunPath 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = Get-BRAVOPilotSafeLastExitCode
    Write-BRAVOPilotEvidenceText -Path $OutputPath -Lines $output
    return [pscustomobject]@{ ExitCode = $exitCode; Pass = ($exitCode -eq 0); Path = $OutputPath }
}

# --- Acceptance -----------------------------------------------------------

function New-BRAVOPilotAcceptanceRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EvidenceDir,
        [Parameter(Mandatory = $true)][hashtable]$Criteria
    )
    $failedCriteria = @($Criteria.Keys | Where-Object { -not $Criteria[$_] })
    $record = [ordered]@{
        EvaluatedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Criteria       = $Criteria
        FailedCriteria = $failedCriteria
        Result         = if ($failedCriteria.Count -eq 0) { 'PILOT ACCEPTED' } else { 'PILOT NOT ACCEPTED' }
    }
    Write-BRAVOPilotEvidenceJson -Path (Join-Path $EvidenceDir 'acceptance.json') -Object $record
    return [pscustomobject]$record
}

# --- Rollback -----------------------------------------------------------

function Get-BRAVOPilotLatestBackupDir {
    param([Parameter(Mandatory = $true)][string]$EvidenceDir)
    $dirs = @(Get-ChildItem -LiteralPath $EvidenceDir -Directory -Filter 'backup-*' | Sort-Object Name -Descending)
    if ($dirs.Count -eq 0) { return $null }
    return $dirs[0].FullName
}

function Invoke-BRAVOPilotRollback {
    # Дзеркалить розділ "Відкат" прийнятого вручну runbook: НЕ повідомляє
    # успіх, доки всі пост-restore докази не пройдені.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$EvidenceDir
    )

    $backupDir = Get-BRAVOPilotLatestBackupDir -EvidenceDir $EvidenceDir
    if ($null -eq $backupDir) {
        throw "PILOT_ROLLBACK_FAILED: у '$EvidenceDir' немає каталогу backup-* — немає з чого відкочуватись (пілот ще не дійшов до Backup)."
    }
    Test-BRAVOPilotBackupIntegrity -BackupDir $backupDir | Out-Null

    $steps = [ordered]@{}

    try {
        Copy-Item -LiteralPath (Join-Path $backupDir 'BRAVO.config') -Destination (Join-Path $InstallRoot 'BRAVO.config') -Force -ErrorAction Stop
        $steps['RestoredBravoConfig'] = $true

        $localBackupPath = Join-Path $backupDir 'BRAVO.local.config'
        $localAbsentMarker = Join-Path $backupDir 'BRAVO.local.config.absent'
        $targetLocalPath = Join-Path $InstallRoot 'BRAVO.local.config'
        if (Test-Path -LiteralPath $localBackupPath) {
            Copy-Item -LiteralPath $localBackupPath -Destination $targetLocalPath -Force -ErrorAction Stop
        } elseif (Test-Path -LiteralPath $localAbsentMarker) {
            if (Test-Path -LiteralPath $targetLocalPath) {
                Remove-Item -LiteralPath $targetLocalPath -ErrorAction Stop
            }
        }
        $steps['RestoredBravoLocalConfig'] = $true

        $manifest = Get-Content -LiteralPath (Join-Path $backupDir 'backup-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($entry in @($manifest)) {
            $restoredPath = Join-Path $InstallRoot $entry.File
            if (-not (Test-Path -LiteralPath $restoredPath)) { continue }
            $restoredHash = Get-BRAVOPilotFileHash -Path $restoredPath
            if ($restoredHash -ne $entry.SHA256) {
                throw "Відновлений '$($entry.File)' SHA-256 ($restoredHash) не збігається з backup-manifest.json ($($entry.SHA256))."
            }
        }
        $steps['PostRestoreHashVerified'] = $true
    } catch {
        $steps['RestoreError'] = $_.Exception.Message
        $failureRecord = [ordered]@{
            AttemptedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            BackupDir      = $backupDir
            Steps          = $steps
            Result         = 'ROLLBACK FAILED'
        }
        Write-BRAVOPilotEvidenceJson -Path (Join-Path $EvidenceDir 'rollback.json') -Object $failureRecord
        throw "PILOT_ROLLBACK_FAILED: $($_.Exception.Message). Стан сервера може бути ЧАСТКОВО відновленим — перевірте вручну перед повторною спробою."
    }

    $beforeSnapshotPath = Join-Path $EvidenceDir 'before.snapshot.json'
    $rollbackSnapshotPath = Join-Path $EvidenceDir 'rollback.snapshot.json'
    $validateLogPath = Join-Path $EvidenceDir 'rollback.validate-only.log'
    $parityPath = Join-Path $EvidenceDir 'rollback.parity.json'
    $selfTestLogPath = Join-Path $EvidenceDir 'rollback.self-test.log'
    $healthLogPath = Join-Path $EvidenceDir 'rollback.health.log'

    $validateResult = Invoke-BRAVOPilotValidateOnly -InstallRoot $InstallRoot -OutputPath $validateLogPath
    $steps['ValidateOnlyPass'] = $validateResult.Pass

    Invoke-BRAVOPilotConfigSnapshot -InstallRoot $InstallRoot -OutputPath $rollbackSnapshotPath | Out-Null
    $parityResult = if (Test-Path -LiteralPath $beforeSnapshotPath) {
        Invoke-BRAVOPilotSemanticParity -InstallRoot $InstallRoot -BeforePath $beforeSnapshotPath -AfterPath $rollbackSnapshotPath -OutputPath $parityPath
    } else {
        $null
    }
    $steps['SemanticParityWithBeforePass'] = if ($null -ne $parityResult) { $parityResult.Pass } else { $false }

    $selfTestResult = Invoke-BRAVOPilotSelfTest -InstallRoot $InstallRoot -OutputPath $selfTestLogPath
    $steps['SelfTestPass'] = $selfTestResult.Pass

    $healthResult = Invoke-BRAVOPilotHealthCheck -InstallRoot $InstallRoot -OutputPath $healthLogPath
    $steps['HealthPass'] = $healthResult.Pass

    $allPass = -not (@($steps.Values) -contains $false)
    $record = [ordered]@{
        AttemptedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        BackupDir      = $backupDir
        Steps          = $steps
        Result         = if ($allPass) { 'ROLLBACK SUCCESS' } else { 'ROLLBACK INCOMPLETE — перевірте Steps і виправте вручну перед повторною спробою' }
    }
    Write-BRAVOPilotEvidenceJson -Path (Join-Path $EvidenceDir 'rollback.json') -Object $record

    if (-not $allPass) {
        throw "PILOT_ROLLBACK_INCOMPLETE: файли відновлено, але не всі пост-restore докази пройшли ($($steps.Keys -join ', ')). Див. rollback.json."
    }
    return [pscustomobject]$record
}

# --- Взаємне виключення mutating-операцій над одним InstallRoot -----------

function Enter-BRAVOPilotInstallRootLock {
    # -Activate й -Rollback — обидві мутують файли на -InstallRoot
    # (BRAVO.local.config / BRAVO.config) через окремі, кожен по собі
    # атомарні, File.Replace/Copy-Item-виклики. Без взаємного виключення
    # два одночасні виклики (Activate+Activate з різних EvidenceDir,
    # Activate+Rollback, Rollback+Rollback) могли б чергувати ці окремі
    # атомарні записи так, що на диску лишається несумісна КОМБІНАЦІЯ
    # файлів (наприклад, BRAVO.config від одного відкату поруч із щойно
    # активованим іншим BRAVO.local.config) — кожен файл коректний сам по
    # собі, але пара суперечить будь-якому єдиному backup/candidate.
    #
    # Named Mutex, а не lock-файл: crash-safe за конструкцією ОС. Якщо
    # процес-власник впаде без Release, ОС позначає mutex "abandoned", і
    # наступний WaitOne() все одно отримує володіння (через
    # AbandonedMutexException) — постійного "завислого" замка не виникає,
    # на відміну від lock-файлу, що вимагав би окремої PID/staleness-
    # евристики. Global\-простір імен: pilot вимагає RunningAsAdministrator
    # (Preflight), тому право створення глобальних kernel-об'єктів уже є;
    # без Global\ той самий оператор у двох сесіях RDP не побачив би чужий
    # session-local mutex.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [int]$TimeoutSeconds = 5
    )

    $normalizedPath = ([System.IO.Path]::GetFullPath($InstallRoot)).TrimEnd('\', '/').ToLowerInvariant()
    $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalizedPath))
    $hashHex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    $mutexName = "Global\BRAVOConfigV2Pilot-$hashHex"

    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
    } catch [System.Threading.AbandonedMutexException] {
        # Попередній власник процесу впав без ReleaseMutex — лок і так наш.
        $acquired = $true
    }
    if (-not $acquired) {
        $mutex.Dispose()
        throw "PILOT_INSTALLROOT_LOCKED: інша операція -Activate/-Rollback вже виконується над '$InstallRoot' (очікування $TimeoutSeconds с вичерпано). Дочекайтесь завершення або перевірте, чи немає завислого процесу pilot-скрипта."
    }
    return $mutex
}

function Exit-BRAVOPilotInstallRootLock {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Threading.Mutex]$Mutex)
    try { $Mutex.ReleaseMutex() } catch { }
    $Mutex.Dispose()
}
