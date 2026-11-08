# Browser sign-in: OAuth 2.0 authorization code flow with PKCE and a localhost redirect.
# The user signs in once in their default browser; tokens for every API are then
# refreshed silently from refresh tokens. No PowerShell modules are required.

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:AuthClients = @{
    # Microsoft Graph Command Line Tools (the app Connect-MgGraph uses): accepts any delegated Graph permission.
    Graph = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
    # Microsoft Azure PowerShell (the app Connect-AzAccount uses): pre-authorized for Power Platform, Dataverse and App Insights.
    Azure = '1950a258-227b-4e31-a9cf-717495945fc2'
}
$script:Auth = @{ Tenant = 'organizations'; LoginHint = $null; RefreshTokens = @{}; GraphScopes = @() }
$script:TokenCache = @{}

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-JwtPayload {
    param([string]$Jwt)
    if (-not $Jwt) { return $null }
    $p = $Jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    ConvertFrom-JsonSafe ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)))
}

function Get-AuthClient {
    param([string]$ResourceUrl)
    if ($ResourceUrl -match '^https://graph\.microsoft\.com') { return 'Graph' }
    return 'Azure'
}

function Invoke-TokenRequest {
    param([hashtable]$Body)
    $uri = "https://login.microsoftonline.com/$($script:Auth.Tenant)/oauth2/v2.0/token"
    try { return Invoke-RestMethod -Method POST -Uri $uri -Body $Body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop }
    catch {
        $err = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $err = ConvertFrom-JsonSafe $_.ErrorDetails.Message }
        if ($err -and (Get-Prop $err 'error')) {
            $desc = ([string](Get-Prop $err 'error_description' '') -split "`r?`n")[0]
            throw "$($err.error): $desc"
        }
        throw
    }
}

function Save-TokenResponse {
    param([string]$Client, [string]$ResourceUrl, $Response)
    if (Get-Prop $Response 'refresh_token') { $script:Auth.RefreshTokens[$Client] = $Response.refresh_token }
    $id = ConvertFrom-JwtPayload (Get-Prop $Response 'id_token')
    if ($id) {
        if (-not $script:Auth.LoginHint) { $script:Auth.LoginHint = Get-Prop $id 'preferred_username' }
        if ($script:Auth.Tenant -in 'organizations', 'common') { $script:Auth.Tenant = Get-Prop $id 'tid' 'organizations' }
    }
    if ($ResourceUrl) {
        $script:TokenCache[$ResourceUrl] = @{ Token = $Response.access_token; ExpiresOn = (Get-Date).AddSeconds([int]$Response.expires_in) }
    }
}

function Receive-AuthRedirect {
    <#
      Waits for the browser to hit the localhost redirect and returns its query
      parameters. Requests without a code or error (favicon, preconnects) are ignored.
    #>
    param([System.Net.Sockets.TcpListener[]]$Listeners, [int]$TimeoutSeconds = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $ready = $Listeners | Where-Object { $_.Pending() } | Select-Object -First 1
        if (-not $ready) { Start-Sleep -Milliseconds 200; continue }
        $client = $ready.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 3000
            $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::ASCII)
            $requestLine = $reader.ReadLine()
            while ($reader.ReadLine()) { }   # skip headers up to the blank line

            $target = ([string]$requestLine -split ' ')[1]
            $query = @{}
            if ($target -and $target.Contains('?')) {
                foreach ($pair in $target.Substring($target.IndexOf('?') + 1).Split('&')) {
                    if (-not $pair) { continue }
                    $kv = $pair -split '=', 2
                    $val = if ($kv.Count -gt 1) { [uri]::UnescapeDataString($kv[1].Replace('+', ' ')) } else { '' }
                    $query[[uri]::UnescapeDataString($kv[0])] = $val
                }
            }
            $isAuth = $query.ContainsKey('code') -or $query.ContainsKey('error')
            if ($query.ContainsKey('error')) {
                $msg = "Sign-in failed: $([Net.WebUtility]::HtmlEncode($query['error_description']))"
            }
            else { $msg = 'Signed in. You can close this tab and return to PowerShell.' }
            $html = if ($isAuth) { "<!doctype html><html><head><meta charset=`"utf-8`"><title>Agent usage collection</title></head><body style=`"font-family:Segoe UI,sans-serif;padding:40px`"><h2>Agent usage collection</h2><p>$msg</p></body></html>" } else { '' }
            $body = [Text.Encoding]::UTF8.GetBytes($html)
            $status = if ($isAuth) { '200 OK' } else { '404 Not Found' }
            $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
            $stream.Write($head, 0, $head.Length)
            $stream.Write($body, 0, $body.Length)
            $stream.Flush()
            if ($isAuth) { return $query }
        }
        catch { }   # idle or broken connection: keep listening
        finally { $client.Close() }
    }
    throw "Timed out after $TimeoutSeconds seconds waiting for the browser sign-in to finish."
}

function Invoke-BrowserSignIn {
    <#
      Opens the default browser at the Entra ID sign-in page and exchanges the
      returned code for tokens. Returns the token response.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Graph', 'Azure')][string]$Client,
        [Parameter(Mandatory)][string[]]$Scopes,
        [switch]$SelectAccount
    )
    $clientId = $script:AuthClients[$Client]
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $verifier = ConvertTo-Base64Url $bytes
    $challenge = ConvertTo-Base64Url ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier)))
    $state = [guid]::NewGuid().ToString('N')

    # Browsers may resolve "localhost" to 127.0.0.1 or ::1, so listen on both.
    $l4 = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $l4.Start()
    $port = $l4.LocalEndpoint.Port
    $listeners = @($l4)
    try {
        $l6 = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::IPv6Loopback, $port)
        $l6.Start()
        $listeners += $l6
    }
    catch { }
    $redirect = "http://localhost:$port/"

    $q = [ordered]@{
        client_id             = $clientId
        response_type         = 'code'
        response_mode         = 'query'
        redirect_uri          = $redirect
        scope                 = (@($Scopes) + @('offline_access', 'openid', 'profile')) -join ' '
        state                 = $state
        code_challenge        = $challenge
        code_challenge_method = 'S256'
    }
    if ($SelectAccount) { $q['prompt'] = 'select_account' }
    if ($script:Auth.LoginHint) { $q['login_hint'] = $script:Auth.LoginHint }
    $url = "https://login.microsoftonline.com/$($script:Auth.Tenant)/oauth2/v2.0/authorize?" +
        (($q.Keys | ForEach-Object { "$_=$([uri]::EscapeDataString([string]$q[$_]))" }) -join '&')

    try {
        Write-Host "A browser window is opening for sign-in. If it doesn't, open this URL in a browser on this computer:" -ForegroundColor Yellow
        Write-Host $url -ForegroundColor DarkGray
        try { Start-Process $url } catch { }
        $result = Receive-AuthRedirect -Listeners $listeners
    }
    finally { foreach ($l in $listeners) { $l.Stop() } }

    if ($result['error']) { throw "Sign-in failed: $($result['error']): $($result['error_description'])" }
    if ($result['state'] -ne $state) { throw 'Sign-in failed: the browser response did not match this sign-in request.' }

    return Invoke-TokenRequest @{
        client_id     = $clientId
        grant_type    = 'authorization_code'
        code          = $result['code']
        redirect_uri  = $redirect
        code_verifier = $verifier
        scope         = $q['scope']
    }
}

function Connect-AgentCollector {
    <#
      Signs the user in once through the browser. With Graph scopes, that sign-in is
      for Microsoft Graph, and when Power Platform, Dataverse or App Insights are also
      needed, a second browser round-trip authorizes that client; it completes on its
      own through single sign-on. Without Graph scopes, there is only the one sign-in.
    #>
    param([string]$TenantId, [string[]]$GraphScopes, [string]$AzureResource)
    if ($TenantId) { $script:Auth.Tenant = $TenantId }
    $script:Auth.GraphScopes = @($GraphScopes | ForEach-Object { "https://graph.microsoft.com/$_" })

    Write-Log 'Signing in through the browser...' -Area 'Auth'
    if ($GraphScopes) {
        $resp = Invoke-BrowserSignIn -Client 'Graph' -Scopes $script:Auth.GraphScopes -SelectAccount
        Save-TokenResponse -Client 'Graph' -ResourceUrl 'https://graph.microsoft.com' -Response $resp
        Write-Log "Signed in as $($script:Auth.LoginHint) (tenant $($script:Auth.Tenant))." -Area 'Auth'
    }

    if ($AzureResource) {
        if ($GraphScopes) { Write-Log 'Authorizing Power Platform, Dataverse and App Insights access (the browser tab completes on its own)...' -Area 'Auth' }
        $resp = Invoke-BrowserSignIn -Client 'Azure' -Scopes @("$AzureResource/.default") -SelectAccount:(-not $GraphScopes)
        Save-TokenResponse -Client 'Azure' -ResourceUrl $AzureResource -Response $resp
        if (-not $GraphScopes) { Write-Log "Signed in as $($script:Auth.LoginHint) (tenant $($script:Auth.Tenant))." -Area 'Auth' }
    }
}

function Get-ResourceToken {
    <#
      Returns an access token for a resource (Graph, Power Platform, a Dataverse
      org URL, App Insights). Uses the cache, then the refresh token, and opens
      the browser again only if Entra ID requires interaction.
    #>
    param([Parameter(Mandatory)][string]$ResourceUrl)
    $cached = $script:TokenCache[$ResourceUrl]
    if ($cached -and $cached.ExpiresOn -gt (Get-Date).AddMinutes(5)) { return $cached.Token }

    $client = Get-AuthClient $ResourceUrl
    $scope = "$ResourceUrl/.default"
    $rt = $script:Auth.RefreshTokens[$client]
    if ($rt) {
        try {
            $resp = Invoke-TokenRequest @{ client_id = $script:AuthClients[$client]; grant_type = 'refresh_token'; refresh_token = $rt; scope = "$scope offline_access" }
            Save-TokenResponse -Client $client -ResourceUrl $ResourceUrl -Response $resp
            return $resp.access_token
        }
        catch {
            if ("$($_.Exception.Message)" -notmatch 'interaction_required|invalid_grant|consent_required') { throw }
            Write-Log "Access to $ResourceUrl needs another browser sign-in: $($_.Exception.Message)" -Level Warn -Area 'Auth'
        }
    }
    $scopes = if ($client -eq 'Graph' -and $script:Auth.GraphScopes.Count -gt 0) { $script:Auth.GraphScopes } else { @($scope) }
    $resp = Invoke-BrowserSignIn -Client $client -Scopes $scopes
    Save-TokenResponse -Client $client -ResourceUrl $ResourceUrl -Response $resp
    return $resp.access_token
}
