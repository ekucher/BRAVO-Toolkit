# BRAVO.Installer.UI.WizardModel — чисті view-model функції екранів 3–10
# майстра та Maintenance Center (INS-084…092, INS-101…104). Без WinForms і без
# I/O (крім перевірки існування ZIP у Test-BRAVOInstallerSourceInput).
# GUI — лише frontend: політика (prerelease-авторизація, hash/provenance,
# активація завдань, exit-коди) живе в engine. Тут — лише відображення даних
# engine у текст + маркер + дозволені дії та складання запиту, який engine
# ПОВТОРНО перевіряє (GUI не є security boundary, план §8).

# Фази виконання в порядку відображення (CONTRACTS §6). Preflight іде до
# списку (це «підготовка»), Rollback/Recovery додаються лише коли з'являються.
$script:BRAVOInstallerWizardPhases = @(
    @{ Key = 'Acquire';   Label = 'Отримання пакета' },
    @{ Key = 'Verify';    Label = 'Перевірка пакета' },
    @{ Key = 'Stage';     Label = 'Підготовка (staging)' },
    @{ Key = 'Backup';    Label = 'Резервна копія' },
    @{ Key = 'Deploy';    Label = 'Розгортання' },
    @{ Key = 'Configure'; Label = 'Конфігурація і завдання' },
    @{ Key = 'Validate';  Label = 'Перевірка результату' },
    @{ Key = 'Activate';  Label = 'Активація завдань' },
    @{ Key = 'Commit';    Label = 'Завершення' }
)

# Фази, у яких runtime уже міг змінитися. Це лише ЗАПАСНА евристика для
# відображення кнопки «Безпечно зупинити»: основне джерело — журнал
# (mutationStarted), див. Test-BRAVOInstallerMutationStarted.
$script:BRAVOInstallerMutationPhases = @('Deploy', 'Configure', 'Validate', 'Activate', 'Commit', 'Rollback', 'Recovery')

$script:BRAVOInstallerOperationNoun = @{ Install = 'Встановлення'; Update = 'Оновлення'; Repair = 'Відновлення' }
$script:BRAVOInstallerOperationDone = @{ Install = 'Встановлено'; Update = 'Оновлено'; Repair = 'Відновлено' }
$script:BRAVOInstallerOperationExecuteLabel = @{ Install = 'Встановити'; Update = 'Оновити'; Repair = 'Відновити' }

function Get-BRAVOInstallerWizardStepList {
    # Кроки майстра залежно від операції (план §5). Update/Repair зберігають
    # конфігурацію, тому пропускають екрани 4–7 (їх показує план).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Install', 'Update', 'Repair')][string]$Operation)
    $all = @{
        Source      = 'Версія та джерело'
        Directories = 'Каталоги та компоненти'
        Backup      = 'Резервні копії'
        Credentials = 'Облікові дані та сповіщення'
        Schedule    = 'Розклад'
        Plan        = 'План змін'
        Progress    = 'Виконання'
        Result      = 'Результат'
    }
    $keys = switch ($Operation) {
        'Install' { @('Source', 'Directories', 'Backup', 'Credentials', 'Schedule', 'Plan', 'Progress', 'Result') }
        default   { @('Source', 'Plan', 'Progress', 'Result') }
    }
    @($keys | ForEach-Object { [pscustomobject]@{ Key = $_; Label = $all[$_] } })
}

function ConvertTo-BRAVOInstallerWizardStepViewModel {
    <#
    .SYNOPSIS
        Позиція в майстрі: «Крок N з M: <назва>», попередній/наступний екран.
        Progress/Result не мають Назад/Далі (виконання не можна «відмотати»).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Update', 'Repair')][string]$Operation,
        [Parameter(Mandatory = $true)][string]$Screen
    )
    $steps = @(Get-BRAVOInstallerWizardStepList -Operation $Operation)
    $index = -1
    for ($i = 0; $i -lt $steps.Count; $i++) { if ($steps[$i].Key -eq $Screen) { $index = $i } }
    if ($index -lt 0) {
        return [pscustomobject]@{ Index = 0; Total = $steps.Count; Text = ''; PreviousKey = $null; NextKey = $null; NextLabel = ''; ShowNavigation = $false }
    }
    $previous = $null
    $next = $null
    if ($index -gt 0) { $previous = $steps[$index - 1].Key }
    if ($index -lt ($steps.Count - 1)) { $next = $steps[$index + 1].Key }
    $locked = ($Screen -eq 'Progress' -or $Screen -eq 'Result')
    $nextLabel = 'Далі'
    if ($Screen -eq 'Plan') { $nextLabel = $script:BRAVOInstallerOperationExecuteLabel[$Operation] }
    elseif ($next -eq 'Plan') { $nextLabel = 'Далі: план змін' }
    [pscustomobject]@{
        Index          = ($index + 1)
        Total          = $steps.Count
        Text           = ('Крок ' + ($index + 1) + ' з ' + $steps.Count + ': ' + $steps[$index].Label)
        PreviousKey    = $(if ($locked) { $null } else { $previous })
        NextKey        = $(if ($locked) { $null } else { $next })
        NextLabel      = $nextLabel
        ShowNavigation = (-not $locked)
    }
}

# ---------------------------------------------------------------- Екран 3

function Test-BRAVOInstallerSourceInput {
    <#
    .SYNOPSIS
        Синтаксична перевірка вводу джерела, щоб у команду engine не потрапив
        небезпечний або явно хибний рядок. Політика релізу (чи дозволений
        тег, hash, provenance) — на боці engine; тут її немає.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Update', 'Repair')][string]$Operation,
        [Parameter(Mandatory = $true)][ValidateSet('Online', 'Local')][string]$SourceKind,
        [string]$Tag = '',
        [string]$ZipPath = '',
        [bool]$PrereleaseEffective = $false
    )
    $problems = New-Object System.Collections.Generic.List[string]
    if ($SourceKind -eq 'Online') {
        $tagText = $Tag.Trim()
        if ([string]::IsNullOrEmpty($tagText)) {
            if ($Operation -eq 'Repair') { [void]$problems.Add('Вкажіть тег поточної версії для відновлення (наприклад, v5.3.0).') }
        } elseif ($tagText -notmatch '^v\d+\.\d+\.\d+(-[0-9A-Za-z][0-9A-Za-z.\-]*)?$') {
            [void]$problems.Add('Тег має вигляд vX.Y.Z (наприклад, v5.3.0).')
        } elseif ($tagText.Contains('-') -and -not $PrereleaseEffective) {
            [void]$problems.Add('Це тег попередньої версії. Він доступний лише в «Розширено» з явним підтвердженням ризику.')
        }
    } else {
        $zipText = $ZipPath.Trim()
        if ([string]::IsNullOrEmpty($zipText)) {
            [void]$problems.Add('Оберіть локальний ZIP-пакет релізу.')
        } elseif ($zipText.Contains('"') -or $zipText -match '[\r\n]') {
            [void]$problems.Add('Шлях до ZIP містить недопустимі символи.')
        } elseif (-not $zipText.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) {
            [void]$problems.Add('Очікується файл із розширенням .zip.')
        } elseif (-not [IO.File]::Exists($zipText)) {
            [void]$problems.Add('Файл ZIP не знайдено.')
        }
    }
    @($problems.ToArray())
}

function ConvertTo-BRAVOInstallerSourceViewModel {
    <#
    .SYNOPSIS
        Екран 3 «Версія та джерело». Prerelease прихований за «Розширено» й
        вимагає окремого явного підтвердження. Кнопки «ігнорувати hash/старий
        тег» немає за конструкцією: такого поля в моделі нема.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Update', 'Repair')][string]$Operation,
        [ValidateSet('Online', 'Local')][string]$SourceKind = 'Online',
        [string]$Tag = '',
        [string]$ZipPath = '',
        [bool]$AdvancedExpanded = $false,
        [bool]$AllowPrerelease = $false,
        [bool]$PrereleaseAcknowledged = $false
    )
    # Prerelease дійсний лише коли відкрито «Розширено», позначено дозвіл І
    # окремо підтверджено ризик; інакше ефективно — stable-only.
    $effective = ($AdvancedExpanded -and $AllowPrerelease -and $PrereleaseAcknowledged)
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($item in @(Test-BRAVOInstallerSourceInput -Operation $Operation -SourceKind $SourceKind -Tag $Tag -ZipPath $ZipPath -PrereleaseEffective $effective)) {
        [void]$problems.Add([string]$item)
    }
    if ($AdvancedExpanded -and $AllowPrerelease -and -not $PrereleaseAcknowledged) {
        [void]$problems.Add('Підтвердіть, що ви розумієте ризик попередньої версії, або зніміть дозвіл.')
    }
    $title = switch ($Operation) {
        'Install' { 'Яку версію встановити?' }
        'Update'  { 'До якої версії оновити?' }
        default   { 'Яку версію використати для відновлення?' }
    }
    $onlineHint = 'Залиште тег порожнім: engine обере рекомендований stable-реліз і зафіксує точний тег, файл і хеш у плані.'
    if ($Operation -eq 'Repair') { $onlineHint = 'Вкажіть тег поточної версії: відновлення не змінює версію.' }
    [pscustomobject]@{
        Operation                 = $Operation
        Title                     = $title
        SourceKind                = $SourceKind
        SourceKinds               = @(
            [pscustomobject]@{ Key = 'Online'; Label = 'Завантажити з GitHub Releases' },
            [pscustomobject]@{ Key = 'Local';  Label = 'Локальний ZIP-пакет (офлайн)' })
        TagVisible                = ($SourceKind -eq 'Online')
        ZipVisible                = ($SourceKind -eq 'Local')
        OnlineHint                = $onlineHint
        OfflineHint               = 'Локальний ZIP проходить ту саму перевірку походження й цілісності, що й онлайн-реліз.'
        AdvancedExpanded          = $AdvancedExpanded
        PrereleaseControlsVisible = $AdvancedExpanded
        PrereleaseWarning         = 'Попередня версія призначена для тестування. Не використовуйте її на робочому сервері без потреби.'
        PrereleaseEffective       = $effective
        Tag                       = $Tag.Trim()
        ZipPath                   = $ZipPath.Trim()
        Problems                  = @($problems.ToArray())
        CanContinue               = ($problems.Count -eq 0)
    }
}

# ---------------------------------------------------------------- Екран 4

function ConvertTo-BRAVOInstallerDirectoriesViewModel {
    <#
    .SYNOPSIS
        Екран 4 «Каталоги та знайдені компоненти». Наявний root не змінюється
        і не переноситься (лише показ); для нового сервера пропонується
        default від engine. Компоненти — лише для читання.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Update', 'Repair')][string]$Operation,
        [AllowNull()][object]$State = $null,
        [string]$DefaultRuntimeRoot = '',
        [string]$ChosenRuntimeRoot = ''
    )
    $existing = [string](Get-BRAVOInstallerProperty -InputObject $State -Name 'runtimeRoot' -Default '')
    $editable = ($Operation -eq 'Install' -and [string]::IsNullOrEmpty($existing))
    $value = $existing
    if ($editable) {
        $value = $ChosenRuntimeRoot.Trim()
        if ([string]::IsNullOrEmpty($value)) { $value = $DefaultRuntimeRoot }
    }
    $problems = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($value)) {
        [void]$problems.Add('Каталог встановлення не визначено.')
    } elseif ($value.Contains('"') -or $value -match '[\r\n]') {
        [void]$problems.Add('Шлях містить недопустимі символи.')
    } elseif ($value -notmatch '^[A-Za-z]:\\') {
        [void]$problems.Add('Вкажіть повний локальний шлях на диску (наприклад, C:\Program Files\BRAVO-Toolkit).')
    }
    $components = @()
    $items = @(Get-BRAVOInstallerProperty -InputObject (Get-BRAVOInstallerProperty -InputObject $State -Name 'credentials') -Name 'items' -Default @() | Where-Object { $null -ne $_ })
    $seen = @{}
    foreach ($item in $items) {
        $name = [string](Get-BRAVOInstallerProperty -InputObject $item -Name 'component' -Default '')
        if ([string]::IsNullOrWhiteSpace($name) -or $seen.ContainsKey($name)) { continue }
        $seen[$name] = $true
        $components += [pscustomobject]@{ Name = $name; Text = ('— ' + $name + ': виявлено; увімкнення визначає конфігурація сервера') }
    }
    $emptyNote = ''
    if ($components.Count -eq 0) { $emptyNote = 'Компоненти (MODEL, BLOG, BRAVOEXCH, BAZA) визначаться за конфігурацією після встановлення; зараз нічого не виявлено.' }
    [pscustomobject]@{
        RuntimeRoot      = $value
        RuntimeEditable  = $editable
        RuntimeNote      = $(if ($editable) { 'Запропоновано стандартний каталог для нового сервера. Інший каталог можна вказати вручну.' } else { 'Наявний каталог не змінюється й не переноситься автоматично.' })
        SeparationNote   = 'Каталог програми (runtime) відокремлений від даних, резервних копій і стану машини: Installer не змінює їх.'
        Components       = @($components)
        ComponentsNote   = $emptyNote
        Problems         = @($problems.ToArray())
        CanContinue      = ($problems.Count -eq 0)
    }
}

# ---------------------------------------------------------------- Екран 5

function Get-BRAVOInstallerBackupModeList {
    # Людські назви -> канонічні режими Install-BRAVOServer/Configurator
    # (Cloud/CloudAndSamba/SambaOnly/LocalOnly). Таблиця лише відображення.
    [CmdletBinding()]
    param()
    @(
        [pscustomobject]@{ Key = 'Cloud';         Label = 'SFTP';                  Sftp = $true;  Smb = $false },
        [pscustomobject]@{ Key = 'SambaOnly';     Label = 'Мережева папка';        Sftp = $false; Smb = $true },
        [pscustomobject]@{ Key = 'CloudAndSamba'; Label = 'SFTP і мережева папка'; Sftp = $true;  Smb = $true },
        [pscustomobject]@{ Key = 'LocalOnly';     Label = 'Лише локально';         Sftp = $false; Smb = $false }
    )
}

function ConvertTo-BRAVOInstallerBackupViewModel {
    <#
    .SYNOPSIS
        Екран 5 «Де зберігати резервні копії». Показує людську назву,
        канонічний режим і ПІДСУМОК ефективних увімкнень; для «Лише локально»
        — явне попередження про відсутність віддаленої копії.
    #>
    [CmdletBinding()]
    param([string]$Mode = 'Cloud')
    $modes = @(Get-BRAVOInstallerBackupModeList)
    $selected = @($modes | Where-Object { $_.Key -eq $Mode })[0]
    $valid = ($null -ne $selected)
    if (-not $valid) { $selected = $modes[0] }
    $warning = ''
    if ($selected.Key -eq 'LocalOnly') {
        $warning = 'Увага: віддаленої копії не буде. Резервні копії зберігатимуться лише на цьому сервері й будуть втрачені разом із ним.'
    }
    $summary = @(
        ('SFTP: ' + $(if ($selected.Sftp) { 'увімкнено' } else { 'вимкнено' })),
        ('Мережева папка: ' + $(if ($selected.Smb) { 'увімкнено' } else { 'вимкнено' })),
        ('Локальна копія: завжди')
    )
    [pscustomobject]@{
        Modes            = $modes
        Mode             = $selected.Key
        Label            = $selected.Label
        CanonicalName    = $selected.Key
        ModeKnown        = $valid
        Warning          = $warning
        HasRemoteCopy    = ($selected.Sftp -or $selected.Smb)
        EffectiveSummary = @($summary)
        AdvancedHint     = 'Адреси, порти, облікові дані та інші поля — у «Розширені налаштування» (канонічний Configurator).'
        CanContinue      = $valid
    }
}

# ---------------------------------------------------------------- Екран 6

function ConvertTo-BRAVOInstallerPresenceDisplay {
    [CmdletBinding()]
    param([AllowNull()][string]$Presence)
    switch ($Presence) {
        'Found'       { [pscustomobject]@{ Marker = '✓'; Text = 'Налаштовано' } }
        'Missing'     { [pscustomobject]@{ Marker = '!'; Text = 'Не налаштовано' } }
        'NotRequired' { [pscustomobject]@{ Marker = '—'; Text = 'Не потрібно' } }
        default       { [pscustomobject]@{ Marker = '!'; Text = 'Стан невідомий' } }
    }
}

function ConvertTo-BRAVOInstallerCredentialsViewModel {
    <#
    .SYNOPSIS
        Екран 6: лише СТАТУС облікових даних і запуск канонічного
        налаштування. GUI не має полів для секретів і не бачить їх.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$State = $null,
        [bool]$SetupAvailable = $false
    )
    $creds = Get-BRAVOInstallerProperty -InputObject $State -Name 'credentials'
    $items = @(Get-BRAVOInstallerProperty -InputObject $creds -Name 'items' -Default @() | Where-Object { $null -ne $_ })
    $rows = @()
    foreach ($item in $items) {
        $display = ConvertTo-BRAVOInstallerPresenceDisplay -Presence ([string](Get-BRAVOInstallerProperty -InputObject $item -Name 'credentialPresence' -Default ''))
        $account = [string](Get-BRAVOInstallerProperty -InputObject $item -Name 'account' -Default '')
        $accountText = switch ($account) { 'TaskAccount' { 'обліковий запис завдань' } 'CurrentUser' { 'поточний користувач' } default { $account } }
        $rows += [pscustomobject]@{
            Component = [string](Get-BRAVOInstallerProperty -InputObject $item -Name 'component' -Default '')
            Marker    = $display.Marker
            Status    = $display.Text
            Text      = ($display.Marker + ' ' + [string](Get-BRAVOInstallerProperty -InputObject $item -Name 'component' -Default '') + ' (' + $accountText + '): ' + $display.Text)
        }
    }
    $note = 'Облікові дані вводяться лише в окремому консольному вікні канонічного налаштування: Installer їх не бачить, не зберігає й не передає.'
    $statusText = 'Статус облікових даних не перевірявся. Це не помилка: перевірка виконується після встановлення.'
    if ($rows.Count -gt 0) { $statusText = 'Статус облікових даних (без показу значень):' }
    $reason = ''
    if (-not $SetupAvailable) { $reason = 'Доступно після встановлення: канонічне налаштування є в каталозі встановленого BRAVO Toolkit.' }
    [pscustomobject]@{
        Rows        = @($rows)
        StatusText  = $statusText
        Note        = $note
        PostInstall = 'Після успішного встановлення Installer запропонує відкрити налаштування облікових даних; завдання розкладу до цього лишаються неактивними.'
        EnterAction = (New-BRAVOInstallerAction -Key 'EnterCredentials' -Label 'Ввести облікові дані' -Enabled $SetupAvailable -Reason $reason)
        CanContinue = $true
    }
}

# ---------------------------------------------------------------- Екран 7

function Get-BRAVOInstallerActivationPolicyLine {
    # Політика D6 (DECISIONS.md) — лише ТЕКСТ для оператора; виконує її engine.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Install', 'Update', 'Repair')][string]$Operation)
    if ($Operation -eq 'Install') {
        return @(
            '✓ Успіх: завдання вмикаються за канонічною конфігурацією розкладу.',
            '! Успіх із зауваженнями: завдання лишаються неактивними до вашого підтвердження.',
            '× Помилка або відкат: завдання не активуються.',
            '‼ Критичний стан: завдання не активуються ніколи.')
    }
    @(
        '✓ Успіх: завдання вмикаються за канонічною конфігурацією розкладу.',
        '! Успіх із зауваженнями: зберігається попередній стан увімкнення завдань.',
        '× Помилка або відкат: відновлюється попередній стан завдань.',
        '‼ Критичний стан: завдання не активуються ніколи.')
}

function ConvertTo-BRAVOInstallerScheduleViewModel {
    <#
    .SYNOPSIS
        Екран 7 «Розклад»: завдання з InstallationState (лише показ), текст
        політики активації й гарантія, що Archive/Maintenance не стартують
        самі після «Завершити».
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Update', 'Repair')][string]$Operation,
        [AllowNull()][object]$State = $null
    )
    $scheduler = Get-BRAVOInstallerProperty -InputObject $State -Name 'scheduler'
    $tasks = @(Get-BRAVOInstallerProperty -InputObject $scheduler -Name 'tasks' -Default @() | Where-Object { $null -ne $_ })
    $rows = @()
    foreach ($task in $tasks) {
        $name = [string](Get-BRAVOInstallerProperty -InputObject $task -Name 'name' -Default '')
        $exists = [bool](Get-BRAVOInstallerProperty -InputObject $task -Name 'exists' -Default $false)
        $enabled = [bool](Get-BRAVOInstallerProperty -InputObject $task -Name 'enabled' -Default $false)
        if (-not $exists) { $marker = '—'; $text = 'відсутнє' }
        elseif ($enabled) { $marker = '✓'; $text = 'увімкнене' }
        else { $marker = '!'; $text = 'вимкнене' }
        $rows += [pscustomobject]@{ Name = $name; Marker = $marker; Status = $text; Text = ($marker + ' ' + $name + ' — ' + $text) }
    }
    $emptyNote = ''
    if ($rows.Count -eq 0) { $emptyNote = 'Завдання розкладу ще не створені або стан не визначено. Їх створить engine; до підтвердження результату вони неактивні.' }
    [pscustomobject]@{
        Rows            = @($rows)
        EmptyNote       = $emptyNote
        PolicyLines     = @(Get-BRAVOInstallerActivationPolicyLine -Operation $Operation)
        NoAutoRunNote   = 'Після «Завершити» Archive і Maintenance не запускаються автоматично: перший запуск відбудеться за розкладом.'
        RestoreVerifyNote = 'Restore Verify відокремлений від Maintenance і production restore.'
        CanContinue     = $true
    }
}

# ---------------------------------------------------------------- Екран 8

function Get-BRAVOInstallerPlanShortId {
    # Перші 8 hex-символів planId (малі літери): те, що оператор бачить і що
    # engine порівнює з confirmedPlanShortId. Некоректний planId -> $null.
    [CmdletBinding()]
    param([AllowNull()][object]$Plan)
    $planId = [string](Get-BRAVOInstallerProperty -InputObject $Plan -Name 'planId' -Default '')
    if ($planId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $null }
    $planId.Substring(0, 8).ToLowerInvariant()
}

function ConvertTo-BRAVOInstallerPlanViewModel {
    <#
    .SYNOPSIS
        Екран 8 «План змін». $PlanLine — результат Format-BRAVODeploymentPlanText
        (канонічний текст engine, у т.ч. збережене/перевірки/зауваження).
        Підтвердження = галочка «Я переглянув план» + короткий код плану.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Plan = $null,
        [AllowNull()][string[]]$PlanLine = @(),
        [bool]$Confirmed = $false,
        [AllowNull()][Nullable[datetime]]$NowUtc = $null,
        [string]$ErrorText = '',
        [ValidateSet('Install', 'Update', 'Repair')][string]$Operation = 'Install'
    )
    $operationKey = $Operation
    $planAction = [string](Get-BRAVOInstallerProperty -InputObject $Plan -Name 'action' -Default '')
    if ($planAction -in @('Install', 'Update', 'Repair')) { $operationKey = $planAction }
    $executeLabel = $script:BRAVOInstallerOperationExecuteLabel[$operationKey]
    $shortId = Get-BRAVOInstallerPlanShortId -Plan $Plan
    $lines = @($PlanLine | Where-Object { $null -ne $_ })
    $rows = @(ConvertTo-BRAVOInstallerFindingRow -Finding @(Get-BRAVOInstallerProperty -InputObject $Plan -Name 'findings' -Default @()))
    $blockers = @($rows | Where-Object { $_.Marker -eq '×' }).Count
    $warnings = @($rows | Where-Object { $_.Marker -eq '!' }).Count

    $expired = $false
    $expiresText = [string](Get-BRAVOInstallerProperty -InputObject $Plan -Name 'expiresUtc' -Default '')
    if ($expiresText) {
        $expires = [datetime]::MinValue
        $style = [Globalization.DateTimeStyles]::RoundtripKind
        if ([datetime]::TryParse($expiresText, [Globalization.CultureInfo]::InvariantCulture, $style, [ref]$expires)) {
            $now = [datetime]::UtcNow
            if ($null -ne $NowUtc) { $now = $NowUtc.Value }
            if ($now.ToUniversalTime() -gt $expires.ToUniversalTime()) { $expired = $true }
        }
    }

    $hasPlan = ($null -ne $Plan -and $null -ne $shortId)
    $statusText = ''
    $marker = '×'
    $blockedReason = ''
    if (-not $hasPlan) {
        $statusText = 'План не сформовано.'
        if ($ErrorText) { $statusText = $statusText + ' ' + $ErrorText }
        $blockedReason = 'План відсутній'
    } elseif ($lines.Count -eq 0) {
        $statusText = 'План отримано, але його текст недоступний: підтвердження неможливе.'
        $blockedReason = 'Текст плану недоступний'
    } elseif ($blockers -gt 0) {
        $statusText = "План містить блокуючі проблеми: $blockers. Виконання неможливе."
        $blockedReason = 'У плані є блокуючі проблеми'
    } elseif ($expired) {
        $statusText = 'Термін дії плану минув. Сформуйте новий план (повторіть крок).'
        $blockedReason = 'План прострочено'
    } elseif ($warnings -gt 0) {
        $marker = '!'
        $statusText = "План готовий із зауваженнями: $warnings. Уважно перегляньте їх перед підтвердженням."
    } else {
        $marker = '✓'
        $statusText = 'План готовий до підтвердження.'
    }
    $canConfirm = ($hasPlan -and $lines.Count -gt 0 -and $blockers -eq 0 -and -not $expired)
    $confirmText = 'Я переглянув план'
    if ($shortId) { $confirmText = "Я переглянув план (код плану: $shortId)" }
    $executeEnabled = ($canConfirm -and $Confirmed)
    $executeReason = ''
    if (-not $canConfirm) { $executeReason = $blockedReason }
    elseif (-not $Confirmed) { $executeReason = 'Спершу підтвердіть, що ви переглянули план' }
    [pscustomobject]@{
        HasPlan        = $hasPlan
        PlanId         = [string](Get-BRAVOInstallerProperty -InputObject $Plan -Name 'planId' -Default '')
        ShortId        = $shortId
        Lines          = @($lines)
        FindingRows    = @($rows)
        BlockerCount   = $blockers
        WarningCount   = $warnings
        Expired        = $expired
        StatusMarker   = $marker
        StatusText     = $statusText
        CanConfirm     = $canConfirm
        ConfirmText    = $confirmText
        ExecuteAction  = (New-BRAVOInstallerAction -Key 'Execute' -Label $executeLabel -Enabled $executeEnabled -Reason $executeReason)
        UacNote        = 'Для виконання знадобиться одне підтвердження UAC (запуск від імені адміністратора). Installer запускає engine в окремому процесі; це вікно лише показує перебіг.'
        PlanChangedNote = 'Якщо пакет, конфігурація чи завдання зміняться до запуску, engine відхилить план і попросить нову перевірку й підтвердження.'
    }
}

function New-BRAVOInstallerExecutionRequest {
    <#
    .SYNOPSIS
        Запит на виконання для worker (ENGINE_DESIGN §10.1). Чистий об'єкт:
        без секретів за конструкцією (жоден параметр їх не приймає), без
        шляхів стану. Запис на диск і перевірка Test-BRAVOUpdateNoSecretProperty —
        Write-BRAVOInstallerExecutionRequest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$ConfirmedPlanShortId,
        [bool]$PrereleaseAuthorized = $false,
        [string]$ActivationPolicy = '',
        [bool]$RunSelfTest = $false,
        [AllowNull()][string]$BackupDestination = $null,
        [AllowNull()][string]$SourcePath = $null,
        [string]$RequestId = '',
        [string]$RequestedUtc = ''
    )
    $shortId = Get-BRAVOInstallerPlanShortId -Plan $Plan
    if ($null -eq $shortId) { throw 'План не містить коректного planId: запит не створено.' }
    if ($ConfirmedPlanShortId.Trim().ToLowerInvariant() -ne $shortId) {
        throw 'Код підтвердження не збігається з кодом плану: запит не створено.'
    }
    if ([string]::IsNullOrWhiteSpace($RequestId)) { $RequestId = [guid]::NewGuid().ToString() }
    if ([string]::IsNullOrWhiteSpace($RequestedUtc)) { $RequestedUtc = [datetime]::UtcNow.ToString('o') }
    if ([string]::IsNullOrWhiteSpace($ActivationPolicy)) {
        $scheduler = Get-BRAVOInstallerProperty -InputObject (Get-BRAVOInstallerProperty -InputObject $Plan -Name 'changes') -Name 'scheduler'
        $ActivationPolicy = [string](Get-BRAVOInstallerProperty -InputObject $scheduler -Name 'activationPolicy' -Default 'ActivateOnSuccessOnly')
    }
    $backup = $null
    if (-not [string]::IsNullOrWhiteSpace($BackupDestination)) { $backup = $BackupDestination }
    $source = $null
    if (-not [string]::IsNullOrWhiteSpace($SourcePath)) { $source = $SourcePath }
    [pscustomobject][ordered]@{
        schemaVersion         = 1
        requestId             = $RequestId.ToLowerInvariant()
        planId                = ([string]$Plan.planId).ToLowerInvariant()
        plan                  = $Plan
        confirmedPlanShortId  = $shortId
        requestedUtc          = $RequestedUtc
        options               = [pscustomobject][ordered]@{
            prereleaseAuthorized = $PrereleaseAuthorized
            activationPolicy     = $ActivationPolicy
            runSelfTest          = $RunSelfTest
            backupDestination    = $backup
            sourcePath           = $source
        }
    }
}

# ---------------------------------------------------------------- Екран 9

function Test-BRAVOInstallerMutationStarted {
    <#
    .SYNOPSIS
        Чи вже почалась зміна runtime. Основне джерело — журнал engine
        (mutationStarted); запасне — фаза прогресу, що настає після початку
        змін. Помилково «true» лише робить зупинку обережнішою (відкат), а не
        небезпечнішою; помилково «false» неприпустимо, тому будь-яка ознака = true.
    #>
    [CmdletBinding()]
    param([AllowNull()][object[]]$ProgressEvent = @(), [AllowNull()][object]$Journal = $null)
    if ($null -ne $Journal -and [bool](Get-BRAVOInstallerProperty -InputObject $Journal -Name 'mutationStarted' -Default $false)) { return $true }
    foreach ($item in @($ProgressEvent)) {
        if ($null -eq $item) { continue }
        $phase = [string](Get-BRAVOInstallerProperty -InputObject $item -Name 'phase' -Default '')
        $status = [string](Get-BRAVOInstallerProperty -InputObject $item -Name 'status' -Default '')
        if ($script:BRAVOInstallerMutationPhases -contains $phase -and $status -ne 'Skipped') { return $true }
    }
    $false
}

function Get-BRAVOInstallerCancelAction {
    <#
    .SYNOPSIS
        Кнопка зупинки: до mutationStarted — «Скасувати», після — «Безпечно
        зупинити». Дія лише створює control\cancel; процес engine ніколи не
        вбивається. Після початку Activate engine ігнорує cancel — кнопка
        вимкнена з поясненням.
    #>
    [CmdletBinding()]
    param(
        [bool]$MutationStarted = $false,
        [bool]$Finished = $false,
        [bool]$CancelRequested = $false,
        [string]$LastPhase = ''
    )
    $key = 'Cancel'
    $label = 'Скасувати'
    $note = 'Скасування до початку змін: runtime не буде змінено.'
    if ($MutationStarted) {
        $key = 'SafeStop'
        $label = 'Безпечно зупинити'
        $note = 'Зміни вже почались. «Безпечно зупинити» просить engine дійти до безпечної точки й відкотити зміни; процес не завершується примусово.'
    }
    $enabled = $true
    $reason = ''
    if ($Finished) { $enabled = $false; $reason = 'Операцію завершено' }
    elseif ($CancelRequested) { $enabled = $false; $reason = 'Запит на зупинку надіслано: engine завершить поточну фазу.' }
    elseif ($LastPhase -eq 'Activate' -or $LastPhase -eq 'Commit') { $enabled = $false; $reason = 'Зупинка недоступна на етапі активації та завершення: engine її ігнорує.' }
    [pscustomobject]@{
        Action = (New-BRAVOInstallerAction -Key $key -Label $label -Enabled $enabled -Reason $reason)
        Note   = $note
    }
}

function ConvertTo-BRAVOInstallerTimestamp {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    $null
}

function Format-BRAVOInstallerElapsed {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][TimeSpan]$Span)
    if ($Span -lt [TimeSpan]::Zero) { $Span = [TimeSpan]::Zero }
    [string]::Format('{0:00}:{1:00}:{2:00}', [int][Math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds)
}

function ConvertTo-BRAVOInstallerExecutionViewModel {
    <#
    .SYNOPSIS
        Екран 9 «Виконання»: фази Acquire→…→Commit, поточне повідомлення,
        elapsed, ознака життя (heartbeat), indeterminate при невідомому
        відсотку, технічні подробиці, кнопка зупинки. Стан фази завжди
        текст + маркер.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$ProgressEvent = @(),
        [AllowNull()][Nullable[datetime]]$StartedUtc = $null,
        [AllowNull()][Nullable[datetime]]$NowUtc = $null,
        [bool]$MutationStarted = $false,
        [bool]$CancelRequested = $false,
        [bool]$Finished = $false,
        [int]$StaleAfterSeconds = 120
    )
    $now = [datetime]::UtcNow
    if ($null -ne $NowUtc) { $now = $NowUtc.Value.ToUniversalTime() }
    $events = @($ProgressEvent | Where-Object { $null -ne $_ })

    $phaseKeys = New-Object System.Collections.Generic.List[object]
    foreach ($p in $script:BRAVOInstallerWizardPhases) { [void]$phaseKeys.Add($p) }
    $extra = @($events | ForEach-Object { [string](Get-BRAVOInstallerProperty -InputObject $_ -Name 'phase' -Default '') } |
        Where-Object { $_ -eq 'Rollback' -or $_ -eq 'Recovery' } | Select-Object -Unique)
    foreach ($key in $extra) {
        $label = 'Відкат змін'
        if ($key -eq 'Recovery') { $label = 'Відновлення після переривання' }
        [void]$phaseKeys.Add(@{ Key = $key; Label = $label })
    }

    $last = $null
    $lastTimestamp = $null
    $lastPhase = ''
    $rows = @()
    foreach ($phase in $phaseKeys) {
        $status = 'Pending'
        foreach ($item in $events) {
            if ([string](Get-BRAVOInstallerProperty -InputObject $item -Name 'phase' -Default '') -ne $phase.Key) { continue }
            switch ([string](Get-BRAVOInstallerProperty -InputObject $item -Name 'status' -Default '')) {
                'Started'   { if ($status -ne 'Completed' -and $status -ne 'Failed') { $status = 'InProgress' } }
                'Progress'  { if ($status -ne 'Completed' -and $status -ne 'Failed') { $status = 'InProgress' } }
                'Heartbeat' { if ($status -ne 'Completed' -and $status -ne 'Failed') { $status = 'InProgress' } }
                'Completed' { $status = 'Completed' }
                'Failed'    { $status = 'Failed' }
                'Skipped'   { $status = 'Skipped' }
            }
        }
        $display = switch ($status) {
            'Completed'  { @('✓', 'виконано') }
            'Failed'     { @('×', 'помилка') }
            'Skipped'    { @('—', 'пропущено') }
            'InProgress' { @('…', 'виконується') }
            default      { @(' ', 'очікує') }
        }
        $rows += [pscustomobject]@{
            Key = $phase.Key; Label = $phase.Label; Status = $status
            Marker = $display[0]; StatusText = $display[1]
            Text = ($display[0] + ' ' + $phase.Label + ' — ' + $display[1])
        }
    }
    foreach ($item in $events) {
        $last = $item
        $when = ConvertTo-BRAVOInstallerTimestamp -Value (Get-BRAVOInstallerProperty -InputObject $item -Name 'timestampUtc')
        if ($null -ne $when) { $lastTimestamp = $when }
        $phaseValue = [string](Get-BRAVOInstallerProperty -InputObject $item -Name 'phase' -Default '')
        if ($phaseValue) { $lastPhase = $phaseValue }
    }

    $progress = ConvertTo-BRAVOInstallerProgressViewModel -ProgressEvent $events
    $message = $progress.Message
    if ([string]::IsNullOrWhiteSpace($message) -and $null -ne $last) {
        $message = [string](Get-BRAVOInstallerProperty -InputObject $last -Name 'messageKey' -Default '')
    }
    $elapsedText = 'Минуло: —'
    if ($null -ne $StartedUtc) { $elapsedText = 'Минуло: ' + (Format-BRAVOInstallerElapsed -Span ($now - $StartedUtc.Value.ToUniversalTime())) }

    $heartbeatText = 'Очікуємо першу відповідь engine…'
    $stale = $false
    if ($null -ne $lastTimestamp) {
        $age = [int][Math]::Max(0, ($now - $lastTimestamp).TotalSeconds)
        $heartbeatText = "Остання активність engine: $age с тому."
        if (-not $Finished -and $age -gt $StaleAfterSeconds) {
            $stale = $true
            $heartbeatText = "! Engine не подає ознак активності понад $StaleAfterSeconds с (остання — $age с тому). Не закривайте вікно й не запускайте повторно; за потреби відкрийте журнал."
        }
    }
    $technical = @($events | ForEach-Object {
        $pct = Get-BRAVOInstallerProperty -InputObject $_ -Name 'percent'
        $pctText = if ($null -eq $pct) { '-' } else { [string]$pct }
        '[' + [string](Get-BRAVOInstallerProperty -InputObject $_ -Name 'sequence' -Default '') + '] ' +
            [string](Get-BRAVOInstallerProperty -InputObject $_ -Name 'timestampUtc' -Default '') + ' ' +
            [string](Get-BRAVOInstallerProperty -InputObject $_ -Name 'phase' -Default '') + '/' +
            [string](Get-BRAVOInstallerProperty -InputObject $_ -Name 'status' -Default '') + ' ' + $pctText + '% ' +
            [string](Get-BRAVOInstallerProperty -InputObject $_ -Name 'message' -Default '')
    })
    $cancel = Get-BRAVOInstallerCancelAction -MutationStarted $MutationStarted -Finished $Finished -CancelRequested $CancelRequested -LastPhase $lastPhase
    [pscustomobject]@{
        Phases          = @($rows)
        CurrentText     = ($progress.Marker + ' ' + $message).Trim()
        CurrentPhase    = $lastPhase
        Percent         = $progress.Percent
        Indeterminate   = $progress.Indeterminate
        ElapsedText     = $elapsedText
        HeartbeatText   = $heartbeatText
        HeartbeatStale  = $stale
        TechnicalText   = (@($technical) -join [Environment]::NewLine)
        MutationStarted = $MutationStarted
        Cancel          = $cancel.Action
        CancelNote      = $cancel.Note
        CloseWarning    = 'Закриття вікна не зупиняє engine: операція триватиме. Щоб повернутися, запустіть Installer знову: головний екран покаже стан (операція виконується або перервана).'
    }
}

# --------------------------------------------------------------- Екран 10

function Get-BRAVOInstallerTaskActivationText {
    # Рядок про розклад (D6): оператор має бачити, чи завдання активні й що
    # реально готове. Показуємо стан, який повідомив engine, без домислів.
    [CmdletBinding()]
    param([AllowNull()][object]$TaskActivation = $null, [string]$Status = '')
    $state = [string](Get-BRAVOInstallerProperty -InputObject $TaskActivation -Name 'state' -Default 'Unknown')
    $text = switch ($state) {
        'Active'    { 'Завдання розкладу: увімкнені.' }
        'Inactive'  { 'Завдання розкладу: НЕ активовані. Активуйте їх після перевірки результату.' }
        'Unchanged' { 'Завдання розкладу: стан не змінювався (збережено попередній).' }
        default     { 'Завдання розкладу: стан невідомий — перевірте вручну.' }
    }
    if ($Status -eq 'Critical') { $text += ' Не вмикайте завдання до ручної перевірки.' }
    $text
}

function ConvertTo-BRAVOInstallerResultStatusDisplay {
    [CmdletBinding()]
    param([AllowNull()][string]$Status, [string]$Operation = 'Install', [AllowNull()][string]$TaskState = $null)
    $done = $script:BRAVOInstallerOperationDone[$Operation]
    $noun = $script:BRAVOInstallerOperationNoun[$Operation]
    if ([string]::IsNullOrEmpty($done)) { $done = 'Виконано'; $noun = 'Операція' }
    switch ($Status) {
        'Success' {
            $title = "$done і перевірено"
            if ($TaskState -eq 'Active') { $title += ' — завдання увімкнені' }
            [pscustomobject]@{ Marker = '✓'; Accent = 'Success'; Title = $title; Kind = 'Success' }
        }
        'SuccessWithWarnings' {
            $tail = switch ($TaskState) { 'Inactive' { 'завдання не активовані' } 'Unchanged' { 'завдання обмежені: збережено попередній стан' } default { 'завдання обмежені' } }
            [pscustomobject]@{ Marker = '!'; Accent = 'Warning'; Title = "$done, але потрібна дія — $tail"; Kind = 'Warning' }
        }
        'Failed' {
            [pscustomobject]@{ Marker = '×'; Accent = 'Error'; Title = 'Операцію не виконано'; Kind = 'Failed' }
        }
        'RolledBack' {
            [pscustomobject]@{ Marker = '←'; Accent = 'RolledBack'; Title = "$noun не завершено. Попередній стан відновлено й перевірено"; Kind = 'RolledBack' }
        }
        'Critical' {
            [pscustomobject]@{ Marker = '‼'; Accent = 'Critical'; Title = 'КРИТИЧНИЙ СТАН — потрібна ручна перевірка'; Kind = 'Critical' }
        }
        default {
            [pscustomobject]@{ Marker = '‼'; Accent = 'Critical'; Title = 'Результат невідомий — потрібна ручна перевірка'; Kind = 'Unknown' }
        }
    }
}

function ConvertTo-BRAVOInstallerResultViewModel {
    <#
    .SYNOPSIS
        Екран 10: п'ять статусів DeploymentResult з різними маркером, акцентом
        і текстом (Success / SuccessWithWarnings / Failed / RolledBack /
        Critical); невідомий або відсутній результат = fail closed як Critical.
        SuccessWithWarnings і RolledBack НІКОЛИ не показуються як зелений успіх.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Result = $null,
        [ValidateSet('Install', 'Update', 'Repair')][string]$Operation = 'Install',
        [string]$NoResultReason = ''
    )
    $status = [string](Get-BRAVOInstallerProperty -InputObject $Result -Name 'status' -Default '')
    $known = @('Success', 'SuccessWithWarnings', 'Failed', 'RolledBack', 'Critical')
    if ($known -notcontains $status) { $status = 'Unknown' }
    $action = [string](Get-BRAVOInstallerProperty -InputObject $Result -Name 'action' -Default '')
    if ($action -in @('Install', 'Update', 'Repair')) { $Operation = $action }
    $taskActivation = Get-BRAVOInstallerProperty -InputObject $Result -Name 'taskActivation'
    $taskState = [string](Get-BRAVOInstallerProperty -InputObject $taskActivation -Name 'state' -Default 'Unknown')
    $mutationStarted = [bool](Get-BRAVOInstallerProperty -InputObject $Result -Name 'mutationStarted' -Default $false)
    $reason = [string](Get-BRAVOInstallerProperty -InputObject $Result -Name 'reasonCode' -Default '')
    $rollback = Get-BRAVOInstallerProperty -InputObject $Result -Name 'rollback'
    $display = ConvertTo-BRAVOInstallerResultStatusDisplay -Status $status -Operation $Operation -TaskState $taskState

    $body = New-Object System.Collections.Generic.List[string]
    switch ($status) {
        'Success' {
            [void]$body.Add('Усі перевірки пройдено.')
        }
        'SuccessWithWarnings' {
            [void]$body.Add('Операцію виконано, але не все готове до роботи без вашої дії. Перегляньте зауваження нижче.')
            [void]$body.Add('Це не повний успіх: «файли скопійовано» не означає, що резервне копіювання працює.')
        }
        'Failed' {
            if ($mutationStarted) {
                [void]$body.Add('Операцію не завершено. Зміни вже починались, тому стан потребує перевірки.')
            } else {
                [void]$body.Add('Runtime не змінювався.')
            }
            $reasonText = switch ($reason) {
                'Blocked'            { 'Причина: виконання заблоковано перевіркою (див. зауваження нижче).' }
                'Cancelled'          { 'Причина: операцію скасовано оператором.' }
                'PlanStale'          { 'Причина: план застарів або передумови змінились. Сформуйте новий план і підтвердіть його знову.' }
                'VerificationFailed' { 'Причина: перевірка пакета не пройдена. Пакет не використано.' }
                'Error'              { 'Причина: помилка під час виконання (див. технічні подробиці).' }
                default              { 'Причина: див. зауваження й технічні подробиці.' }
            }
            [void]$body.Add($reasonText)
        }
        'RolledBack' {
            [void]$body.Add('Це не успішне завершення: зміни скасовано.')
            [void]$body.Add('Попередню версію BRAVO відновлено; система повернута до перевіреного стану.')
            $rbMessage = [string](Get-BRAVOInstallerProperty -InputObject $rollback -Name 'message' -Default '')
            if ($rbMessage) { [void]$body.Add($rbMessage) }
        }
        'Critical' {
            [void]$body.Add('Автоматичне відновлення не завершено. Стан runtime не підтверджено.')
            [void]$body.Add('Не запускайте подальше оновлення до ручної перевірки. Повторні Встановити/Оновити/Відновити заблоковано.')
            $rbMessage = [string](Get-BRAVOInstallerProperty -InputObject $rollback -Name 'message' -Default '')
            if ($rbMessage) { [void]$body.Add($rbMessage) }
        }
        default {
            [void]$body.Add('Engine не повернув коректного результату операції. Стан сервера не підтверджено.')
            [void]$body.Add('Не запускайте повторне оновлення до ручної перевірки: відкрийте журнал і перевірте стан на головному екрані.')
            if ($NoResultReason) { [void]$body.Add($NoResultReason) }
        }
    }

    $validationRows = @()
    foreach ($check in @(Get-BRAVOInstallerProperty -InputObject $Result -Name 'validation' -Default @() | Where-Object { $null -ne $_ })) {
        $checkStatus = [string](Get-BRAVOInstallerProperty -InputObject $check -Name 'status' -Default '')
        $vm = switch ($checkStatus) {
            'Pass'    { @('✓', 'пройдено') }
            'Warn'    { @('!', 'зауваження') }
            'Fail'    { @('×', 'не пройдено') }
            'Skipped' { @('—', 'пропущено') }
            default   { @('×', 'невідомий статус') }
        }
        $name = [string](Get-BRAVOInstallerProperty -InputObject $check -Name 'name' -Default '')
        $message = [string](Get-BRAVOInstallerProperty -InputObject $check -Name 'message' -Default '')
        $text = $vm[0] + ' ' + $name + ' — ' + $vm[1]
        if ($message) { $text += ': ' + $message }
        $validationRows += [pscustomobject]@{ Name = $name; Marker = $vm[0]; Status = $vm[1]; Text = $text }
    }
    $findingRows = @(ConvertTo-BRAVOInstallerFindingRow -Finding @(Get-BRAVOInstallerProperty -InputObject $Result -Name 'findings' -Default @()))

    $logPath = [string](Get-BRAVOInstallerProperty -InputObject $Result -Name 'logPath' -Default '')
    $isSuccess = ($status -eq 'Success' -or $status -eq 'SuccessWithWarnings')
    $actions = New-Object System.Collections.Generic.List[object]
    [void]$actions.Add((New-BRAVOInstallerAction -Key 'OpenLog' -Label 'Відкрити журнал' -Enabled $true -Reason ''))
    [void]$actions.Add((New-BRAVOInstallerAction -Key 'SaveReport' -Label 'Зберегти звіт' -Enabled $true -Reason ''))
    $configureReason = ''
    if (-not $isSuccess) { $configureReason = 'Недоступно, поки стан не підтверджено' }
    [void]$actions.Add((New-BRAVOInstallerAction -Key 'Configure' -Label 'Налаштувати' -Enabled $isSuccess -Reason $configureReason))
    if ($isSuccess -and ($Operation -eq 'Install' -or $Operation -eq 'Repair')) {
        [void]$actions.Add((New-BRAVOInstallerAction -Key 'EnterCredentials' -Label 'Ввести облікові дані' -Enabled $true -Reason ''))
    }
    if ($status -eq 'Failed' -and -not $mutationStarted) {
        [void]$actions.Add((New-BRAVOInstallerAction -Key 'RestartWizard' -Label 'Повторити' -Enabled $true -Reason ''))
    }
    [void]$actions.Add((New-BRAVOInstallerAction -Key 'Finish' -Label 'Завершити' -Enabled $true -Reason ''))

    $technical = New-Object System.Collections.Generic.List[string]
    $fields = @(
        @('Ідентифікатор операції', 'operationId'), @('Ідентифікатор плану', 'planId'), @('Дія', 'action'),
        @('Статус', 'status'), @('Код причини', 'reasonCode'), @('Код завершення', 'exitCode'), @('Назва коду', 'exitCodeName'),
        @('Версія до', 'sourceVersion'), @('Цільова версія', 'targetVersion'), @('Встановлена версія', 'installedVersion'),
        @('Остання фаза', 'lastPhase'), @('Початок (UTC)', 'startedUtc'), @('Кінець (UTC)', 'finishedUtc'),
        @('Журнал', 'logPath'), @('Звіт', 'reportPath'), @('Журнал транзакції', 'journalPath'))
    foreach ($field in $fields) {
        $value = Get-BRAVOInstallerProperty -InputObject $Result -Name $field[1]
        if ($null -ne $value -and [string]$value -ne '') { [void]$technical.Add($field[0] + ': ' + [string]$value) }
    }
    [void]$technical.Add('Зміни runtime починались: ' + $(if ($mutationStarted) { 'так' } else { 'ні' }))
    if ($null -ne $rollback) {
        [void]$technical.Add('Відкат: спроба=' + [string](Get-BRAVOInstallerProperty -InputObject $rollback -Name 'attempted' -Default '') +
            ', статус=' + [string](Get-BRAVOInstallerProperty -InputObject $rollback -Name 'status' -Default ''))
    }
    [void]$technical.Add('Стан завдань: ' + $taskState)

    [pscustomobject]@{
        Status             = $status
        Kind               = $display.Kind
        Marker             = $display.Marker
        Accent             = $display.Accent
        Title              = $display.Title
        Body               = @($body.ToArray())
        TaskActivationText = (Get-BRAVOInstallerTaskActivationText -TaskActivation $taskActivation -Status $status)
        NoAutoRunNote      = 'Archive і Maintenance не запускаються автоматично після завершення.'
        ValidationRows     = @($validationRows)
        FindingRows        = @($findingRows)
        Actions            = @($actions.ToArray())
        TechnicalText      = (@($technical.ToArray()) -join [Environment]::NewLine)
        LogPath            = $logPath
        RepeatBlocked      = ($status -eq 'Critical' -or $status -eq 'Unknown')
        IsSuccess          = $isSuccess
        MutationStarted    = $mutationStarted
    }
}

# ------------------------------------------------------- Maintenance Center

function ConvertTo-BRAVOInstallerLogListViewModel {
    <#
    .SYNOPSIS
        Журнали: read-only список (найновіші першими, не більше $MaxItems).
        $File — об'єкти з Name/FullName/Length/LastWriteTime (FileInfo).
    #>
    [CmdletBinding()]
    param([AllowNull()][object[]]$File = @(), [int]$MaxItems = 50)
    $items = @($File | Where-Object { $null -ne $_ } | Sort-Object -Property @{ Expression = { $_.LastWriteTime }; Descending = $true } | Select-Object -First $MaxItems)
    $rows = @()
    foreach ($item in $items) {
        $length = [double]$item.Length
        $size = if ($length -ge 1048576) { ('{0:N1} МБ' -f ($length / 1048576)) } elseif ($length -ge 1024) { ('{0:N0} КБ' -f ($length / 1024)) } else { ('{0:N0} Б' -f $length) }
        $when = ([datetime]$item.LastWriteTime).ToString('yyyy-MM-dd HH:mm')
        $rows += [pscustomobject]@{ Name = [string]$item.Name; FullName = [string]$item.FullName; SizeText = $size; WhenText = $when; Text = ($when + '  ' + $size + '  ' + [string]$item.Name) }
    }
    $note = ''
    if ($rows.Count -eq 0) { $note = 'Журналів не знайдено.' }
    [pscustomobject]@{ Rows = @($rows); Count = $rows.Count; EmptyNote = $note }
}

function ConvertTo-BRAVOInstallerMaintenanceViewModel {
    <#
    .SYNOPSIS
        Дії Maintenance Center: Налаштування (Configurator), Відновити
        компоненти (через план і підтвердження, як оновлення), облікові дані.
        Недоступні дії мають видиму причину.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$State = $null, [switch]$RepeatBlocked)
    $homeVm = ConvertTo-BRAVOInstallerHomeViewModel -State $State -RepeatBlocked:$RepeatBlocked
    $root = [string](Get-BRAVOInstallerProperty -InputObject $State -Name 'runtimeRoot' -Default '')
    $repairReason = ''
    if ([string]::IsNullOrEmpty($root)) { $repairReason = 'Спершу встановіть BRAVO Toolkit' }
    elseif ($homeVm.RecoveryFirst) { $repairReason = 'Спершу завершіть відновлення після переривання' }
    elseif ($RepeatBlocked) { $repairReason = $script:BRAVOInstallerRepeatBlockedReason }
    $credReason = ''
    if ([string]::IsNullOrEmpty($root)) { $credReason = 'Спершу встановіть BRAVO Toolkit' }
    elseif ($homeVm.RecoveryFirst) { $credReason = 'Спершу завершіть відновлення після переривання' }
    [pscustomobject]@{
        ConfigureAction   = @($homeVm.SecondaryActions | Where-Object { $_.Key -eq 'Settings' })[0]
        RepairAction      = (New-BRAVOInstallerAction -Key 'Repair' -Label 'Відновити компоненти' -Enabled ([string]::IsNullOrEmpty($repairReason)) -Reason $repairReason)
        CredentialsAction = (New-BRAVOInstallerAction -Key 'EnterCredentials' -Label 'Ввести облікові дані' -Enabled ([string]::IsNullOrEmpty($credReason)) -Reason $credReason)
        RepairNote        = 'Відновлення проходить той самий шлях, що й оновлення: перевірка, план, підтвердження. Конфігурація сервера зберігається.'
    }
}
