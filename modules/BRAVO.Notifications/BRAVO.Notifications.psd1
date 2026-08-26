@{
    RootModule = 'BRAVO.Notifications.psm1'
    ModuleVersion = '5.2.0'
    GUID = 'b7229730-af64-4cb1-822e-9cf44c4d6546'
    PowerShellVersion = '3.0'
    FunctionsToExport = @(
        'Get-HostInformation',
        'Format-BRAVOUkrainianCount',
        'Format-BRAVOOperatorDuration',
        'Test-BRAVOValidIpAddressText',
        'Format-BRAVOOperatorHostLine',
        'Get-BRAVOOperatorPublicIpLine',
        'Format-BRAVOOperatorVersionLine',
        'Format-BRAVOOperatorStatusLine',
        'New-BRAVOOperatorNotificationMessage',
        'ConvertTo-DiscordNotificationText',
        'Split-DiscordNotificationText',
        'Resolve-BRAVONotificationRoute',
        'Resolve-BRAVONotificationEndpoint',
        'Format-BRAVONotificationListSummary',
        'Limit-BRAVONotificationPayload',
        'ConvertTo-BRAVONotificationPayloadText',
        'Send-BRAVONotificationChunks',
        'Send-BRAVONotification'
    )
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
