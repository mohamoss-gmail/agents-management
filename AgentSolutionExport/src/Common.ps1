# Shared helpers: logging, HTTP with paging/retry, parsing.

$script:Log = New-Object System.Collections.Generic.List[object]

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info',
        [string]$Area = 'General'
    )
    $entry = [pscustomobject]@{
        Time    = (Get-Date).ToString('s')
        Level   = $Level
        Area    = $Area
        Message = $Message
    }
    $script:Log.Add($entry)
    switch ($Level) {
        'Warn'  { Write-Warning "[$Area] $Message" }
        'Error' { Write-Host "[$Area] $Message" -ForegroundColor Red }
        default { Write-Host "[$Area] $Message" -ForegroundColor Cyan }
    }
}

function Get-CollectionLog { $script:Log }

function Invoke-ApiRequest {
    <#
      Generic request with retry on 429/5xx. Returns the parsed body. Errors carry
      the service's own message (e.g. which permission is missing).
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [string]$Method = 'GET',
        $Body,
        [int]$MaxRetries = 5
    )
    $attempt = 0
    while ($true) {
        try {
            $params = @{ Uri = $Uri; Headers = $Headers; Method = $Method; ErrorAction = 'Stop' }
            if ($Body) {
                $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 }
                $params.ContentType = 'application/json'
            }
            return Invoke-RestMethod @params
        }
        catch {
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            $attempt++
            if (($status -eq 429 -or $status -ge 500) -and $attempt -le $MaxRetries) {
                $wait = [math]::Min(60, [math]::Pow(2, $attempt))
                $retryAfter = $null
                try { $retryAfter = $_.Exception.Response.Headers['Retry-After'] } catch { }
                if ($retryAfter) { $wait = [int]"$retryAfter" }
                Start-Sleep -Seconds $wait
                continue
            }
            $detail = $null
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $j = ConvertFrom-JsonSafe $_.ErrorDetails.Message
                $detail = Get-Prop (Get-Prop $j 'error') 'message' (Get-Prop $j 'message')
            }
            if ($detail) { throw "HTTP $status from $($Uri.Split('?')[0]): $detail" }
            throw
        }
    }
}

function Invoke-PagedRequest {
    <#
      Follows @odata.nextLink and returns all items from .value.
      -HeaderFactory is called per page so long-running loops refresh tokens.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][scriptblock]$HeaderFactory,
        [int]$MaxItems = 0
    )
    $items = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    while ($next) {
        $resp = Invoke-ApiRequest -Uri $next -Headers (& $HeaderFactory)
        if ($resp.value) { foreach ($v in $resp.value) { $items.Add($v) } }
        $next = Get-Prop $resp '@odata.nextLink' (Get-Prop $resp 'nextLink')
        if ($MaxItems -gt 0 -and $items.Count -ge $MaxItems) { break }
    }
    # Unrolled on purpose: callers wrap the call in @(), which would nest a ", array" return.
    return $items.ToArray()
}

function Get-Prop {
    # Safe property read that tolerates missing members and nulls.
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function ConvertFrom-JsonSafe {
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    try { return $Json | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
}

function Get-RegexValues {
    param([string]$Text, [string]$Pattern)
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    $vals = [regex]::Matches($Text, $Pattern) | ForEach-Object { $_.Groups[1].Value.Trim().Trim('"', "'") }
    return @($vals | Where-Object { $_ } | Select-Object -Unique)
}

function Get-FirstRegexValue {
    param([string]$Text, [string]$Pattern)
    $v = @(Get-RegexValues -Text $Text -Pattern $Pattern)
    if ($v.Count -gt 0) { return $v[0] }
    return $null
}

function Get-UsageFrequency {
    <#
      Classifies how often an agent is used, from active days in the window.
    #>
    param([int]$ActiveDays, [int]$WindowDays)
    if ($ActiveDays -le 0 -or $WindowDays -le 0) { return 'Not used' }
    $ratio = $ActiveDays / [double]$WindowDays
    if ($ratio -ge 0.5) { return 'Daily' }
    if ($ratio -ge (1 / 7.0)) { return 'Weekly' }
    if ($ratio -ge (1 / 30.0)) { return 'Monthly' }
    return 'Occasional'
}
