# Reads who is assigned to each Copilot Studio agent.
#   Makers: the owner, members of the agent's own Dataverse team, users with write access.
#   Users:  users and groups with read access, groups in the agent's access policy, or Everyone.

$script:EveryoneToken = 'Everyone'
$script:UserSelect = 'systemuserid,fullname,domainname,azureactivedirectoryobjectid,isdisabled,applicationid,accessmode,_businessunitid_value'

# accesscontrolpolicy values on the bot table.
$script:PolicyAny = 0
$script:PolicyAgentReaders = 1
$script:PolicyGroupMembership = 2
$script:PolicyAnyMultiTenant = 3

function New-EnvironmentContext {
    # Per-environment caches, so each user, team and role is only looked up once.
    param([Parameter(Mandatory)]$Environment)
    [pscustomobject]@{
        Environment = $Environment
        Org         = $Environment.DataverseUrl
        Api         = "$($Environment.DataverseUrl)/api/data/v9.2"
        UsersById   = @{}
        UsersByOid  = @{}
        Teams       = @{}
        RoleOk      = @{}
        RoleIds     = @{}
        RootBu      = $null
    }
}

function Get-EnvironmentAgents {
    param([Parameter(Mandatory)]$Ctx)
    $org = $Ctx.Org
    $select = 'botid,name,schemaname,accesscontrolpolicy,authenticationmode,authorizedsecuritygroupids,_owninguser_value,_owningteam_value'
    Invoke-PagedRequest -Uri "$($Ctx.Api)/bots?`$select=$select&`$filter=statecode eq 0" -HeaderFactory { Get-DataverseHeaders $org }
}

function Add-SystemUser {
    param($Ctx, $Row)
    $oid = Get-Prop $Row 'azureactivedirectoryobjectid'
    $appId = [string](Get-Prop $Row 'applicationid')
    $u = [pscustomobject]@{
        SystemUserId   = ([string]$Row.systemuserid).ToLowerInvariant()
        ObjectId       = if ($oid) { ([string]$oid).ToLowerInvariant() } else { $null }
        Upn            = Get-Prop $Row 'domainname'
        Name           = Get-Prop $Row 'fullname'
        Disabled       = [bool](Get-Prop $Row 'isdisabled' $false)
        # Application, support and non-interactive users are platform accounts, not people.
        IsService      = (($appId -and $appId -ne '00000000-0000-0000-0000-000000000000') -or ([int](Get-Prop $Row 'accessmode' 0) -in 3, 4))
        BusinessUnitId = Get-Prop $Row '_businessunitid_value'
    }
    $Ctx.UsersById[$u.SystemUserId] = $u
    if ($u.ObjectId) { $Ctx.UsersByOid[$u.ObjectId] = $u }
    return $u
}

function Get-SystemUserById {
    param($Ctx, [string]$Id)
    $key = $Id.ToLowerInvariant()
    if ($Ctx.UsersById.ContainsKey($key)) { return $Ctx.UsersById[$key] }
    try { return Add-SystemUser $Ctx (Invoke-ApiRequest -Uri "$($Ctx.Api)/systemusers($key)?`$select=$script:UserSelect" -Headers (Get-DataverseHeaders $Ctx.Org)) }
    catch {
        Write-Log "Could not read user ${key}: $($_.Exception.Message)" -Level Warn -Area 'Read'
        return $null
    }
}

function Get-SystemUserByObjectId {
    # Returns $null when the Entra user isn't in this environment yet.
    param($Ctx, [string]$ObjectId, [switch]$Refresh)
    $key = $ObjectId.ToLowerInvariant()
    if (-not $Refresh -and $Ctx.UsersByOid.ContainsKey($key)) { return $Ctx.UsersByOid[$key] }
    $org = $Ctx.Org
    $rows = @(Invoke-PagedRequest -Uri "$($Ctx.Api)/systemusers?`$select=$script:UserSelect&`$filter=azureactivedirectoryobjectid eq $key" -HeaderFactory { Get-DataverseHeaders $org })
    if ($rows.Count -eq 0) { return $null }
    return Add-SystemUser $Ctx $rows[0]
}

function Get-TeamInfo {
    # Team details plus members for owner and access teams (group team members live in Entra ID).
    param($Ctx, [string]$TeamId)
    $key = $TeamId.ToLowerInvariant()
    if ($Ctx.Teams.ContainsKey($key)) { return $Ctx.Teams[$key] }
    $org = $Ctx.Org
    $t = Invoke-ApiRequest -Uri "$($Ctx.Api)/teams($key)?`$select=name,teamtype,azureactivedirectoryobjectid,isdefault" -Headers (Get-DataverseHeaders $org)
    $type = [int]$t.teamtype
    $isDefault = [bool](Get-Prop $t 'isdefault' $false)
    $members = @()
    if ($type -in 0, 1 -and -not $isDefault) {
        $rows = @(Invoke-PagedRequest -Uri "$($Ctx.Api)/teams($key)/teammembership_association?`$select=$script:UserSelect" -HeaderFactory { Get-DataverseHeaders $org })
        $members = @($rows | ForEach-Object { Add-SystemUser $Ctx $_ })
    }
    $groupId = Get-Prop $t 'azureactivedirectoryobjectid'
    $info = [pscustomobject]@{
        TeamId    = $key
        Name      = $t.name
        Type      = $type
        IsGroup   = ($type -in 2, 3)
        IsDefault = $isDefault
        GroupId   = if ($groupId) { ([string]$groupId).ToLowerInvariant() } else { $null }
        Members   = $members
    }
    $Ctx.Teams[$key] = $info
    return $info
}

function New-AccessRow {
    param([string]$Kind, $User, [string]$Via, $Team, [string]$GroupId, [string]$GroupName)
    [pscustomobject]@{
        Kind         = $Kind
        Key          = if ($Kind -eq 'Group') { $GroupId } elseif ($User.ObjectId) { $User.ObjectId } else { $User.SystemUserId }
        ObjectId     = if ($Kind -eq 'Group') { $GroupId } else { $User.ObjectId }
        SystemUserId = if ($User) { $User.SystemUserId } else { $null }
        TeamId       = if ($Team) { $Team.TeamId } else { $null }
        Name         = if ($Kind -eq 'Group') { $GroupName } else { $User.Name }
        Upn          = if ($User) { $User.Upn } else { $null }
        Via          = $Via
    }
}

function Select-AgentTeam {
    <#
      The agent's own team is the owner/access team with write access. If a maker shared the
      agent with other teams too, only a team named after the agent is trusted.
    #>
    param([object[]]$Candidates, $Bot)
    $list = @($Candidates | Where-Object { $_ })
    if ($list.Count -eq 0) { return $null }
    if ($list.Count -eq 1) { return $list[0] }
    $named = @($list | Where-Object {
            $_.Name -match [regex]::Escape([string]$Bot.botid) -or
            ($Bot.schemaname -and $_.Name -match [regex]::Escape([string]$Bot.schemaname))
        })
    if ($named.Count -eq 1) { return $named[0] }
    return $null
}

function Get-AgentAccess {
    # Current makers and users of one agent. Throws if the agent's sharing can't be read.
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Bot)
    $botId = ([string]$Bot.botid).ToLowerInvariant()
    $policy = [int](Get-Prop $Bot 'accesscontrolpolicy' $script:PolicyAny)
    $makers = New-Object System.Collections.Generic.List[object]
    $users = New-Object System.Collections.Generic.List[object]
    $writeTeams = New-Object System.Collections.Generic.List[object]

    $ownerId = Get-Prop $Bot '_owninguser_value'
    $ownerKey = $null
    if ($ownerId) {
        $owner = Get-SystemUserById $Ctx $ownerId
        if ($owner) {
            $makers.Add((New-AccessRow -Kind 'User' -User $owner -Via 'Owner'))
            $ownerKey = $makers[0].Key
        }
    }
    $owningTeam = Get-Prop $Bot '_owningteam_value'
    if ($owningTeam) { $writeTeams.Add((Get-TeamInfo $Ctx $owningTeam)) }

    $uri = "$($Ctx.Api)/RetrieveSharedPrincipalsAndAccess(Target=@t)?@t={'@odata.id':'bots($botId)'}"
    $resp = Invoke-ApiRequest -Uri $uri -Headers (Get-DataverseHeaders $Ctx.Org)
    foreach ($pa in @(Get-Prop $resp 'PrincipalAccesses' @())) {
        $canWrite = ([string]$pa.AccessMask) -match 'WriteAccess'
        $principal = $pa.Principal
        $ptype = ([string](Get-Prop $principal '@odata.type' '')) -replace '#Microsoft.Dynamics.CRM.', ''
        $principalId = Get-Prop $principal 'ownerid' (Get-Prop $principal 'systemuserid' (Get-Prop $principal 'teamid'))
        if (-not $principalId) { continue }

        if ($ptype -eq 'systemuser') {
            $u = Get-SystemUserById $Ctx $principalId
            if (-not $u -or $u.IsService) { continue }
            $row = New-AccessRow -Kind 'User' -User $u -Via 'Direct'
            if ($canWrite) { $makers.Add($row) } else { $users.Add($row) }
        }
        elseif ($ptype -eq 'team') {
            $team = Get-TeamInfo $Ctx $principalId
            if ($team.IsDefault) {
                Write-Log "'$($Bot.name)' is shared with the default team '$($team.Name)' (everyone in that business unit). It isn't listed." -Level Warn -Area 'Read'
            }
            elseif ($team.IsGroup) {
                $users.Add((New-AccessRow -Kind 'Group' -Via 'GroupShare' -Team $team -GroupId $team.GroupId -GroupName $team.Name))
            }
            elseif ($canWrite) { $writeTeams.Add($team) }
            else {
                foreach ($m in $team.Members) {
                    if (-not $m.IsService) { $users.Add((New-AccessRow -Kind 'User' -User $m -Via "Team: $($team.Name)")) }
                }
            }
        }
    }

    $agentTeam = Select-AgentTeam -Candidates $writeTeams.ToArray() -Bot $Bot
    foreach ($team in $writeTeams) {
        $via = if ($agentTeam -and $team.TeamId -eq $agentTeam.TeamId) { 'AgentTeam' } else { "Team: $($team.Name)" }
        foreach ($m in $team.Members) {
            if (-not $m.IsService) { $makers.Add((New-AccessRow -Kind 'User' -User $m -Via $via -Team $team)) }
        }
    }

    # Groups can also be listed on the agent itself, which only applies under the group membership policy.
    $policyGroups = @(Get-PolicyGroupIds $Bot)
    foreach ($g in $policyGroups) { $users.Add((New-AccessRow -Kind 'Group' -Via 'GroupPolicy' -GroupId $g)) }

    $note = $null
    if (-not $agentTeam) {
        $note = if ($writeTeams.Count -gt 1) { "more than one team has edit access ($(($writeTeams | ForEach-Object { $_.Name }) -join ', '))" } else { 'no team with edit access was found' }
    }
    [pscustomobject]@{
        Bot          = $Bot
        Policy       = $policy
        AuthMode     = [int](Get-Prop $Bot 'authenticationmode' 0)
        Everyone     = ($policy -in $script:PolicyAny, $script:PolicyAnyMultiTenant)
        OwnerKey     = $ownerKey
        AgentTeam    = $agentTeam
        TeamNote     = $note
        Makers       = $makers.ToArray()
        Users        = $users.ToArray()
        PolicyGroups = $policyGroups
    }
}

function Get-PrincipalText {
    # The text used for a principal in the CSV: UPN for users, name for groups, object ID as a fallback.
    param($Row)
    if ($Row.Kind -eq 'User') {
        if ($Row.Upn) { return $Row.Upn }
        return $Row.Key
    }
    $name = $Row.Name
    $dir = if ($Row.ObjectId) { Get-DirectoryObject $Row.ObjectId } else { $null }
    if ($dir -and $dir.DisplayName) { $name = $dir.DisplayName }
    # A semicolon would split the name when the CSV is read back.
    if ($name -and -not $name.Contains(';')) { return $name }
    return $Row.ObjectId
}

function ConvertTo-AssignmentRow {
    # One CSV row per agent. Makers can always chat, so they aren't repeated under Users.
    param([Parameter(Mandatory)]$Access, [string]$EnvironmentName)
    $makerKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    $makers = New-Object System.Collections.Generic.List[string]
    # The owner comes first; everything else is sorted so two exports can be compared.
    foreach ($m in ($Access.Makers | Sort-Object @{ Expression = { $_.Via -ne 'Owner' } }, Upn)) {
        if ($makerKeys.Add([string]$m.Key)) { $makers.Add((Get-PrincipalText $m)) }
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $groups = New-Object System.Collections.Generic.List[string]
    $people = New-Object System.Collections.Generic.List[string]
    foreach ($u in $Access.Users) {
        if ($makerKeys.Contains([string]$u.Key) -or -not $seen.Add([string]$u.Key)) { continue }
        if ($u.Kind -eq 'Group') { $groups.Add((Get-PrincipalText $u)) } else { $people.Add((Get-PrincipalText $u)) }
    }
    $users = @(if ($Access.Everyone) { $script:EveryoneToken }) + @($groups | Sort-Object) + @($people | Sort-Object)
    [pscustomobject][ordered]@{
        Environment = $EnvironmentName
        AgentName   = $Access.Bot.name
        Makers      = ($makers -join ';')
        Users       = ($users -join ';')
        AgentId     = $Access.Bot.botid
    }
}

function Get-EnvironmentAssignments {
    # Assignment rows for every agent in an environment. An agent that can't be read is logged and skipped.
    param([Parameter(Mandatory)]$Environment)
    $ctx = New-EnvironmentContext $Environment
    $bots = @(Get-EnvironmentAgents $ctx)
    Write-Log "$($bots.Count) agent(s) in '$($Environment.DisplayName)'." -Area 'Read'
    $accessList = New-Object System.Collections.Generic.List[object]
    foreach ($bot in $bots) {
        try { $accessList.Add((Get-AgentAccess -Ctx $ctx -Bot $bot)) }
        catch { Write-Log "Could not read assignments for '$($bot.name)': $($_.Exception.Message)" -Level Error -Area 'Read' }
    }
    # Resolve all group names in one call instead of one per group.
    Resolve-DirectoryObjects @($accessList | ForEach-Object { $_.Users } | Where-Object { $_.Kind -eq 'Group' } | ForEach-Object { $_.ObjectId })
    foreach ($a in $accessList) { ConvertTo-AssignmentRow -Access $a -EnvironmentName $Environment.DisplayName }
}
