<#
    SafePath.ps1
    Спільна логіка санітизації session_id для хуків Claude Code, що
    використовують його як ім'я файлу/підпапки (save-task.ps1,
    precompact-checkpoint.ps1).

    Канонічна реалізація: раніше цей самий allowlist-регекс був
    продубльований окремо у двох хуках і лише один з них ловив крайній
    випадок чисто крапкових значень ("..", "."). Тепер обидва хуки
    dot-source'ять цей файл — одна реалізація, один набір тестів
    (.claude/hooks/tests/Test-SafePath.ps1).
#>

function ConvertTo-SafeSessionId {
    <#
        Перетворює довільний рядок session_id на безпечне ім'я файлу/
        підпапки Windows.

        - Лишає лише [A-Za-z0-9._-] — прибирає роздільники шляху
          (/, \), keywords пристроїв (наприклад "NUL"), пробіли тощо.
        - Allowlist сам по собі НЕ блокує значення, що складаються лише
          з крапок ("..", "."): такий рядок повністю проходить allowlist,
          але "." і ".." — спеціальні посилання на каталог у файловій
          системі. session_id = ".." після allowlist лишився б ".." і
          Join-Path з ним підняв би шлях на рівень вище цільової теки.
          Тому крапково-лише значення відкидаються окремою перевіркою.
        - Порожнє чи відкинуте значення замінюється детермінованим
          fallback'ом 'unknown-session', а не помилкою: хук ніколи не
          повинен впасти через дивний вхід від Claude Code.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$SessionId,

        [string]$Fallback = 'unknown-session'
    )

    $value = if ($null -eq $SessionId) { '' } else { $SessionId }
    $value = $value -replace '[^A-Za-z0-9._-]', ''

    if ([string]::IsNullOrWhiteSpace($value) -or $value -match '^\.+$') {
        return $Fallback
    }

    return $value
}
