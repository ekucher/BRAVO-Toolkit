Set-StrictMode -Version Latest

# ApiPool.Transport: transport layer of the OFFLINE build. Depends on ApiPool.Core
# (and, by contract, ApiPool.Credentials for the credential provider type), which
# the entrypoint/test runner imports into the global scope before this module.
#
# This build ships NO network-capable code. The only working transport is a
# scripted fake. The live transport constructor always throws. The fake never
# resolves the credential: the secret is not needed offline and must not be
# materialized in memory without a reason.

$script:ApiPoolTransportHeaderNames = @('x-api-key', 'anthropic-version', 'content-type')
$script:ApiPoolFakeKinds = @('timeout', 'transportError', 'timeoutAfterSend')

function New-ApiPoolFakeTransport {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Responses
    )

    $queue = New-Object System.Collections.Queue
    if ($null -ne $Responses) {
        foreach ($item in $Responses) {
            if ($null -eq $item -or $item -isnot [System.Collections.IDictionary]) {
                Invoke-ApiPoolThrow -Code 'INTERNAL_ERROR' -Message 'A scripted fake response must be a hashtable.'
            }
            if ($item.Contains('Kind')) {
                if (-not ($script:ApiPoolFakeKinds -ccontains [string]$item['Kind'])) {
                    Invoke-ApiPoolThrow -Code 'INTERNAL_ERROR' -Message ("Unknown scripted fake kind '{0}'." -f [string]$item['Kind'])
                }
                $queue.Enqueue(@{ Kind = [string]$item['Kind'] })
                continue
            }
            if (-not $item.Contains('StatusCode') -or ($item['StatusCode'] -isnot [int])) {
                Invoke-ApiPoolThrow -Code 'INTERNAL_ERROR' -Message 'A scripted fake response needs an integer StatusCode or a Kind.'
            }
            $headers = @{}
            if ($item.Contains('Headers') -and $null -ne $item['Headers']) {
                if ($item['Headers'] -isnot [System.Collections.IDictionary]) {
                    Invoke-ApiPoolThrow -Code 'INTERNAL_ERROR' -Message 'Scripted fake Headers must be a hashtable.'
                }
                foreach ($k in $item['Headers'].Keys) { $headers[[string]$k] = $item['Headers'][$k] }
            }
            $body = ''
            if ($item.Contains('Body') -and $null -ne $item['Body']) { $body = [string]$item['Body'] }
            $queue.Enqueue(@{ Kind = 'Response'; StatusCode = [int]$item['StatusCode']; Headers = $headers; Body = $body })
        }
    }

    return [pscustomobject]@{
        PSTypeName = 'ApiPool.Transport'
        Kind       = 'Fake'
        Calls      = New-Object System.Collections.ArrayList
        Queue      = $queue
    }
}

function Get-ApiPoolFakeTransportCall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Transport
    )

    if ($null -eq $Transport -or $Transport.Kind -cne 'Fake') {
        Invoke-ApiPoolThrow -Code 'INTERNAL_ERROR' -Message 'Not a fake transport.'
    }
    return @($Transport.Calls.ToArray())
}

function New-ApiPoolHttpTransport {
    # Deliberately a simple function without a param block: it must refuse ANY arguments.
    Invoke-ApiPoolThrow -Code 'LIVE_DISABLED_IN_BUILD' -Message 'The live transport is not shipped in this build.'
}

function Send-ApiPoolTransportRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Transport,

        [Parameter(Mandatory = $true)]
        $Request,

        [AllowNull()]
        [psobject]$CredentialProvider
    )

    if ($null -eq $Transport -or $null -eq $Transport.PSObject.Properties['Kind'] -or $Transport.Kind -cne 'Fake') {
        Invoke-ApiPoolThrow -Code 'INTERNAL_ERROR' -Message 'Unsupported transport kind (only Fake exists in this build).'
    }
    if ($Request -isnot [System.Collections.IDictionary]) {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'The transport request must be a hashtable.'
    }
    foreach ($field in @('Method', 'Uri', 'Body', 'TimeoutSec')) {
        if (-not $Request.Contains($field) -or $null -eq $Request[$field]) {
            Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message ("The transport request is missing '{0}'." -f $field)
        }
    }
    if ($Request['Body'] -isnot [string]) {
        Invoke-ApiPoolThrow -Code 'REQUEST_INVALID' -Message 'The transport request Body must be a string.'
    }

    # CredentialProvider is intentionally NOT used: the fake transport never resolves a credential.
    $bodyBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes([string]$Request['Body'])
    [void]$Transport.Calls.Add([pscustomobject]@{
            Uri         = [string]$Request['Uri']
            Method      = [string]$Request['Method']
            HeaderNames = @($script:ApiPoolTransportHeaderNames)
            BodyBytes   = [int]$bodyBytes.Length
            BodySha256  = (Get-ApiPoolSha256Hex -Text ([string]$Request['Body']))
            TimeoutSec  = $Request['TimeoutSec']
        })

    if ($Transport.Queue.Count -eq 0) {
        Invoke-ApiPoolThrow -Code 'TRANSPORT_ERROR' -Message 'fake transport exhausted' -Details @{ sent = $false }
    }
    $item = $Transport.Queue.Dequeue()
    switch ($item['Kind']) {
        'timeout' {
            Invoke-ApiPoolThrow -Code 'TRANSPORT_TIMEOUT' -Message 'The request timed out before it was sent.' -Retryable -Details @{ sent = $false }
        }
        'timeoutAfterSend' {
            Invoke-ApiPoolThrow -Code 'TRANSPORT_TIMEOUT' -Message 'The request timed out after it was sent; no response was received.' -Retryable -Details @{ sent = $true }
        }
        'transportError' {
            Invoke-ApiPoolThrow -Code 'TRANSPORT_ERROR' -Message 'The transport failed before the request was sent.' -Retryable -Details @{ sent = $false }
        }
    }
    return [pscustomobject]@{
        StatusCode = [int]$item['StatusCode']
        Headers    = $item['Headers']
        Body       = [string]$item['Body']
    }
}

Export-ModuleMember -Function @(
    'New-ApiPoolFakeTransport',
    'Get-ApiPoolFakeTransportCall',
    'New-ApiPoolHttpTransport',
    'Send-ApiPoolTransportRequest'
)
