<#
    Redact.ps1
    Спільна логіка редагування (маскування секретів) для хуків Claude
    Code, що пересилають текст поза хост (notify-slack.ps1).
#>

function Get-BRAVOCanonicalRedactor {
    <#
        Канонічний Protect-BRAVOLogSecret (modules/BRAVO.Logging) уже знає
        облікові дані в URL, -password=/-p, password|secret|token=..., і
        Slack/Discord webhook URL — той самий клас даних, що може
        опинитись у тексті, який хуки пересилають назовні. Функція лише
        ЧИТАЄ команду з модуля (Import-Module -Function), не дублює
        патерни: якщо канонічний редактор колись розшириться, виклики
        Protect-HookText підхоплять це без окремої правки.

        Повертає CommandInfo, якщо редактор підтверджено робочий, інакше
        $null (виклик Protect-HookText тоді впаде на fail-safe нижче).
    #>
    [CmdletBinding()]
    param([string]$ProjectDir)

    try {
        if (-not $ProjectDir) { return $null }
        $manifestPath = Join-Path $ProjectDir 'modules\BRAVO.Logging\BRAVO.Logging.psd1'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $null }

        Import-Module -Name $manifestPath -Function 'Protect-BRAVOLogSecret' -Force -ErrorAction Stop

        # Перевіряємо, що команда дійсно маскує, а не просто "Import-Module
        # не впав" — інакше нижче покладались би на редактор, якого
        # фактично немає чи який мовчки перестав працювати.
        $probe = Protect-BRAVOLogSecret -Text 'token=probe-value-should-be-masked'
        if ($probe -notmatch 'probe-value-should-be-masked') {
            return (Get-Command Protect-BRAVOLogSecret -ErrorAction Stop)
        }
    }
    catch {
    }
    return $null
}

function Protect-HookTextFailSafe {
    <#
        Локальний fallback НА ВИПАДОК, якщо канонічний редактор
        недоступний (модуль не знайдено, хук викликано поза checkout-ом
        репозиторію тощо). Свідомо мінімальний набір патернів — той самий
        клас секретів, що й Protect-BRAVOLogSecret, без претензії на
        повну паритетність.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $sanitized = $Text
    # Облікові дані всередині URL: sftp://user:password@host -> sftp://user:***@host
    $sanitized = $sanitized -replace '(?i)([a-z][a-z0-9+.-]*://[^:/\s@]+):[^@\s]+@', '$1:***@'
    $sanitized = $sanitized -replace '(?i)((?:password|passwd|secret|token|api[_-]?key)\s*[:=]\s*)(?:"[^"]*"|\S+)', '$1***'
    $sanitized = $sanitized -replace '(?i)(hooks\.slack\.com/services/)\S+', '$1***'
    $sanitized = $sanitized -replace '(?i)(discord(?:app)?\.com/api/webhooks/)\S+', '$1***'
    return $sanitized
}

function Protect-HookText {
    <#
        Єдина точка входу для редагування тексту перед пересиланням
        назовні. Спершу пробує канонічний редактор (якщо переданий),
        інакше — fail-safe fallback. Якщо навіть fallback впаде — а це
        означало б зламаний .NET regex engine, тобто щось значно гірше за
        просту відсутність модуля — повертає $null: викликач МУСИТЬ
        трактувати $null як "не надсилати", а не як "надіслати як є".
        Краще не переслати потенційно чутливе тіло, ніж відправити секрет.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Text,

        [System.Management.Automation.CommandInfo]$CanonicalRedactor
    )

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    try {
        if ($CanonicalRedactor) {
            return (Protect-BRAVOLogSecret -Text $Text)
        }
    }
    catch {
        # Канонічний редактор впав під час фактичного виклику — не
        # довіряємо частковому результату, падаємо на fail-safe нижче.
    }

    try {
        return Protect-HookTextFailSafe -Text $Text
    }
    catch {
        return $null
    }
}
