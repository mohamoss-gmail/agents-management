# Entra ID lookups through Microsoft Graph: users, groups, and group expansion.

$script:DirectoryCache = @{}   # objectId (lower) -> directory object summary
$script:UpnIndex = @{}         # upn (lower) -> objectId
$script:GroupMemberCache = @{} # groupId -> @{ Count; MemberIds; Truncated }

function Get-GraphHeaders {
    param([hashtable]$Extra)
    $h = @{ Authorization = "Bearer $(Get-ResourceToken 'https://graph.microsoft.com')" }
    if ($Extra) { foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] } }
    return $h
}

# Not named Invoke-GraphRequest: Microsoft.Graph.Authentication exports that as an alias,
# and aliases win over functions when the module is loaded in the session.
function Invoke-GraphApi {
    param([Parameter(Mandatory)][string]$Uri, [string]$Method = 'GET', $Body, [hashtable]$Headers)
    Invoke-ApiRequest -Uri $Uri -Method $Method -Body $Body -Headers (Get-GraphHeaders $Headers)
}

function Invoke-GraphPaged {
    param([Parameter(Mandatory)][string]$Uri, [hashtable]$Headers = @{}, [int]$MaxItems = 0)
    $graphExtraHeaders = $Headers
    Invoke-PagedRequest -Uri $Uri -MaxItems $MaxItems -HeaderFactory { Get-GraphHeaders $graphExtraHeaders }
}

function Add-DirectoryObject {
    param($Obj)
    $type = ([string](Get-Prop $Obj '@odata.type' '')).Replace('#microsoft.graph.', '')
    $entry = [pscustomobject]@{
        ObjectId          = ([string]$Obj.id).ToLowerInvariant()
        Type              = $type
        DisplayName       = Get-Prop $Obj 'displayName'
        UserPrincipalName = Get-Prop $Obj 'userPrincipalName'
        Mail              = Get-Prop $Obj 'mail'
    }
    $script:DirectoryCache[$entry.ObjectId] = $entry
    if ($entry.UserPrincipalName) { $script:UpnIndex[$entry.UserPrincipalName.ToLowerInvariant()] = $entry.ObjectId }
    return $entry
}

function Resolve-DirectoryObjects {
    <#
      Resolves Entra object IDs to names/UPNs in batches of 1000. Results are cached.
    #>
    param([string[]]$ObjectIds)
    $guidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
    $pending = @($ObjectIds | Where-Object { $_ -and $_ -match $guidPattern } |
        ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique |
        Where-Object { -not $script:DirectoryCache.ContainsKey($_) })
    for ($i = 0; $i -lt $pending.Count; $i += 1000) {
        $batch = $pending[$i..([math]::Min($i + 999, $pending.Count - 1))]
        $body = @{ ids = @($batch); types = @('user', 'group', 'servicePrincipal') } | ConvertTo-Json
        try {
            $resp = Invoke-GraphApi -Method POST -Uri 'https://graph.microsoft.com/v1.0/directoryObjects/getByIds' -Body $body
            foreach ($o in $resp.value) { Add-DirectoryObject $o | Out-Null }
        }
        catch { Write-Log "Directory lookup failed: $($_.Exception.Message)" -Level Warn -Area 'Identity' }
        # Mark unresolved IDs (deleted users etc.) so they are not retried.
        foreach ($id in $batch) {
            if (-not $script:DirectoryCache.ContainsKey($id)) {
                $script:DirectoryCache[$id] = [pscustomobject]@{ ObjectId = $id; Type = 'unknown'; DisplayName = $null; UserPrincipalName = $null; Mail = $null }
            }
        }
    }
}

function Get-DirectoryObject {
    param([string]$ObjectId)
    if (-not $ObjectId) { return $null }
    $key = $ObjectId.ToLowerInvariant()
    if (-not $script:DirectoryCache.ContainsKey($key)) { Resolve-DirectoryObjects @($key) }
    return $script:DirectoryCache[$key]
}

function Resolve-Upns {
    <#
      Looks up object IDs for UPNs (used to join Purview records, which carry UPNs).
    #>
    param([string[]]$Upns)
    $pending = @($Upns | Where-Object { $_ -and $_.Contains('@') } | ForEach-Object { $_.ToLowerInvariant() } |
        Select-Object -Unique | Where-Object { -not $script:UpnIndex.ContainsKey($_) })
    foreach ($upn in $pending) {
        try {
            $u = Invoke-GraphApi -Uri "https://graph.microsoft.com/v1.0/users/$([uri]::EscapeDataString($upn))?`$select=id,displayName,userPrincipalName,mail"
            $u | Add-Member -NotePropertyName '@odata.type' -NotePropertyValue '#microsoft.graph.user' -Force
            Add-DirectoryObject $u | Out-Null
        }
        catch { $script:UpnIndex[$upn] = $null }
    }
}

function Get-UserKey {
    <#
      Normalised user key used across all usage sources: UPN when known, else object ID.
    #>
    param([string]$ObjectId, [string]$Upn)
    if ($Upn) { return $Upn.ToLowerInvariant() }
    if ($ObjectId) {
        $o = Get-DirectoryObject $ObjectId
        if ($o -and $o.UserPrincipalName) { return $o.UserPrincipalName.ToLowerInvariant() }
        return $ObjectId.ToLowerInvariant()
    }
    return $null
}

function Get-UserDisplay {
    param([string]$UserKey)
    if (-not $UserKey) { return [pscustomobject]@{ DisplayName = $null; UserPrincipalName = $null; ObjectId = $null } }
    $oid = if ($UserKey.Contains('@')) { $script:UpnIndex[$UserKey] } else { $UserKey }
    $o = if ($oid) { $script:DirectoryCache[$oid] } else { $null }
    [pscustomobject]@{
        DisplayName       = if ($o) { $o.DisplayName } else { $null }
        UserPrincipalName = if ($o -and $o.UserPrincipalName) { $o.UserPrincipalName } elseif ($UserKey.Contains('@')) { $UserKey } else { $null }
        ObjectId          = $oid
    }
}

function Get-GroupMembers {
    <#
      Returns transitive user members of a group. Large groups are counted but
      not enumerated beyond MaxMembers to keep runs fast.
    #>
    param([string]$GroupId, [int]$MaxMembers = 5000)
    if (-not $GroupId) { return $null }
    $key = $GroupId.ToLowerInvariant()
    if ($script:GroupMemberCache.ContainsKey($key)) { return $script:GroupMemberCache[$key] }

    $result = @{ Count = 0; MemberIds = @(); Truncated = $false }
    try {
        $count = Invoke-GraphApi -Uri "https://graph.microsoft.com/v1.0/groups/$key/transitiveMembers/microsoft.graph.user/`$count" -Headers @{ ConsistencyLevel = 'eventual' }
        # Strip anything but digits: Windows PowerShell can decode a BOM into the plain-text count.
        $result.Count = [int](([string]$count) -replace '\D', '')
        if ($result.Count -le $MaxMembers) {
            $members = Invoke-GraphPaged -Uri "https://graph.microsoft.com/v1.0/groups/$key/transitiveMembers/microsoft.graph.user?`$select=id,displayName,userPrincipalName,mail&`$top=999"
            foreach ($m in $members) {
                $m | Add-Member -NotePropertyName '@odata.type' -NotePropertyValue '#microsoft.graph.user' -Force
                Add-DirectoryObject $m | Out-Null
            }
            $result.MemberIds = @($members | ForEach-Object { ([string]$_.id).ToLowerInvariant() })
        }
        else { $result.Truncated = $true }
    }
    catch { Write-Log "Could not expand group ${key}: $($_.Exception.Message)" -Level Warn -Area 'Identity' }
    $script:GroupMemberCache[$key] = $result
    return $result
}
