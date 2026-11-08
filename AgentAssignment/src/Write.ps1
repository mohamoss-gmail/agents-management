# Applies assignments from a CSV: read the file, resolve names, plan the changes, then run them.

$script:MakerRole = 'Environment Maker'
# Roles that already let someone open or chat with agents in an environment.
$script:SufficientRoles = @('System Administrator', 'System Customizer', 'Environment Maker', 'Bot Author')
$script:MaxPolicyGroups = 20
$script:AssigneeCache = @{}

function Split-Assignees {
    param([string]$Cell)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in ($Cell -split ';')) {
        $v = $t.Trim()
        if ($v -and $seen.Add($v)) { $v }
    }
}

function Read-AssignmentCsv {
    <#
      Reads the CSV into row objects. A missing Makers or Users column means "leave that
      role alone"; a blank cell in a present column means "nobody".
    #>
    param([Parameter(Mandatory)][string]$Path, [string]$TargetEnvironment)
    if (-not (Test-Path $Path)) { throw "CSV file not found: $Path" }
    $csv = @(Import-Csv -Path $Path)
    if ($csv.Count -eq 0) { throw "No rows in $Path" }
    $cols = @($csv[0].PSObject.Properties.Name)
    if ($cols -notcontains 'AgentName') { throw "The CSV needs an AgentName column. Found: $($cols -join ', ')" }
    if ($cols -notcontains 'Makers' -and $cols -notcontains 'Users') { throw 'The CSV needs a Makers column, a Users column, or both.' }
    if ($cols -notcontains 'Environment' -and -not $TargetEnvironment) { throw 'The CSV needs an Environment column, or use -TargetEnvironment.' }

    $line = 1
    foreach ($r in $csv) {
        $line++
        $env = if ($TargetEnvironment) { $TargetEnvironment } else { ([string](Get-Prop $r 'Environment' '')).Trim() }
        [pscustomobject]@{
            Line        = $line
            Environment = $env
            AgentName   = ([string]$r.AgentName).Trim()
            # An agent ID only means something in the environment it came from.
            AgentId     = if ($TargetEnvironment) { $null } else { ([string](Get-Prop $r 'AgentId' '')).Trim() }
            HasMakers   = ($cols -contains 'Makers')
            HasUsers    = ($cols -contains 'Users')
            Makers      = @(Split-Assignees ([string](Get-Prop $r 'Makers' '')))
            Users       = @(Split-Assignees ([string](Get-Prop $r 'Users' '')))
        }
    }
}

function Resolve-Assignee {
    # Turns a CSV entry (Everyone, UPN, group name, or object ID) into a user or group in Entra ID.
    param([Parameter(Mandatory)][string]$Token)
    $key = $Token.ToLowerInvariant()
    if ($script:AssigneeCache.ContainsKey($key)) { return $script:AssigneeCache[$key] }

    $result = [pscustomobject]@{ Token = $Token; Kind = 'Unresolved'; ObjectId = $null; Name = $null; Error = $null; SystemUserId = $null; Disabled = $false; HasRole = $false }
    $setGroup = {
        param($g)
        if (-not [bool](Get-Prop $g 'securityEnabled' $false)) { $result.Error = "'$Token' isn't a security group, so it can't be given access."; return }
        $result.Kind = 'Group'
        $result.ObjectId = ([string]$g.id).ToLowerInvariant()
        $result.Name = $g.displayName
    }
    $select = '$select=id,displayName,securityEnabled'
    try {
        if ($key -eq $script:EveryoneToken.ToLowerInvariant()) { $result.Kind = 'Everyone' }
        elseif ($key -match '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$') {
            $o = Get-DirectoryObject $key
            if ($o -and $o.Type -eq 'user') { $result.Kind = 'User'; $result.ObjectId = $key; $result.Name = $o.DisplayName }
            elseif ($o -and $o.Type -eq 'group') { & $setGroup (Invoke-GraphApi -Uri "https://graph.microsoft.com/v1.0/groups/${key}?$select") }
            else { $result.Error = "No user or group has the ID '$Token'." }
        }
        elseif ($key.Contains('@')) {
            Resolve-Upns @($key)
            $oid = $script:UpnIndex[$key]
            if ($oid) { $result.Kind = 'User'; $result.ObjectId = $oid; $result.Name = $script:DirectoryCache[$oid].DisplayName }
            else {
                $escaped = [uri]::EscapeDataString($key.Replace("'", "''"))
                $groups = @(Invoke-GraphPaged -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=mail eq '$escaped'&$select")
                if ($groups.Count -eq 1) { & $setGroup $groups[0] }
                else { $result.Error = "No user or group was found for '$Token'." }
            }
        }
        else {
            $escaped = [uri]::EscapeDataString($Token.Replace("'", "''"))
            $groups = @(Invoke-GraphPaged -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$escaped'&$select")
            if ($groups.Count -eq 1) { & $setGroup $groups[0] }
            elseif ($groups.Count -gt 1) { $result.Error = "$($groups.Count) groups are named '$Token'. Use the group's object ID instead." }
            else { $result.Error = "No group is named '$Token'. Users must be listed by UPN." }
        }
    }
    catch { $result.Error = "Could not look up '$Token': $($_.Exception.Message)" }
    $script:AssigneeCache[$key] = $result
    return $result
}

function Test-UserHasAgentRole {
    # True if the user has a sufficient role directly or through a team.
    param($Ctx, [string]$SystemUserId)
    if ($Ctx.RoleOk.ContainsKey($SystemUserId)) { return $Ctx.RoleOk[$SystemUserId] }
    $org = $Ctx.Org
    $hf = { Get-DataverseHeaders $org }
    $names = @(Invoke-PagedRequest -Uri "$($Ctx.Api)/systemusers($SystemUserId)/systemuserroles_association?`$select=name" -HeaderFactory $hf | ForEach-Object { $_.name })
    $teams = @(Invoke-PagedRequest -Uri "$($Ctx.Api)/systemusers($SystemUserId)/teammembership_association?`$select=teamid&`$expand=teamroles_association(`$select=name)" -HeaderFactory $hf)
    $names += @($teams | ForEach-Object { @(Get-Prop $_ 'teamroles_association' @()) } | ForEach-Object { $_.name })
    $ok = @($names | Where-Object { $script:SufficientRoles -contains $_ }).Count -gt 0
    $Ctx.RoleOk[$SystemUserId] = $ok
    return $ok
}

function Get-EnvironmentAssignee {
    # A copy of the assignee with this environment's details: Dataverse user, disabled state, role.
    param($Ctx, $Assignee)
    $a = $Assignee.PSObject.Copy()
    if ($a.Kind -ne 'User') { return $a }
    $u = Get-SystemUserByObjectId $Ctx $a.ObjectId
    if ($u) {
        $a.SystemUserId = $u.SystemUserId
        $a.Disabled = $u.Disabled
        $a.HasRole = Test-UserHasAgentRole $Ctx $u.SystemUserId
    }
    return $a
}

function New-PlanAction {
    param($Row, $Access, [string]$Action, [string]$Target, [string]$Detail, [string]$Status = 'Planned',
        [string]$ObjectId, [string]$SystemUserId, [string]$TeamId, $Value)
    [pscustomobject]@{
        Environment  = $Row.Environment
        AgentName    = $Row.AgentName
        Action       = $Action
        Target       = $Target
        Status       = $Status
        Detail       = $Detail
        AgentId      = if ($Access) { $Access.Bot.botid } else { $Row.AgentId }
        ObjectId     = $ObjectId
        SystemUserId = $SystemUserId
        TeamId       = $TeamId
        Value        = $Value
    }
}

function Get-AssignmentPlan {
    <#
      Compares a resolved CSV row with an agent's current access and returns the changes.
      Changes nothing itself, so every decision can be reviewed in the preview and tested offline.

      Order matters: access is added before anything is narrowed or removed, so nobody
      listed in the CSV loses access part way through.
    #>
    param(
        [Parameter(Mandatory)]$Row,      # Read-AssignmentCsv row with Makers/Users as Get-EnvironmentAssignee objects
        [Parameter(Mandatory)]$Access,
        [switch]$Mirror,
        [switch]$SkipSecurityRoles
    )
    $roles = New-Object System.Collections.Generic.List[object]
    $adds = New-Object System.Collections.Generic.List[object]
    $policyChanges = New-Object System.Collections.Generic.List[object]
    $removals = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[object]

    $unresolved = @(@($Row.Makers) + @($Row.Users) | Where-Object { $_ -and $_.Kind -eq 'Unresolved' })
    foreach ($a in $unresolved) { $notes.Add((New-PlanAction $Row $Access 'Blocked' $a.Token $a.Error 'Blocked')) }
    # A misspelled name must never read as "remove this person".
    $removeOthers = $Mirror -and $unresolved.Count -eq 0
    if ($Mirror -and -not $removeOthers) {
        $notes.Add((New-PlanAction $Row $Access 'Note' '' 'Nothing is removed from this agent because some names could not be found.' 'Info'))
    }

    $canShare = {
        param($a)
        if ($a.Disabled) {
            $notes.Add((New-PlanAction $Row $Access 'Blocked' $a.Token 'This user is disabled in the environment.' 'Blocked'))
            return $false
        }
        if ($a.HasRole) { return $true }
        if (-not $SkipSecurityRoles) {
            $roles.Add((New-PlanAction $Row $Access 'AddRole' $a.Token "Assign the $script:MakerRole security role." -ObjectId $a.ObjectId -SystemUserId $a.SystemUserId))
            return $true
        }
        if (-not $a.SystemUserId) {
            $notes.Add((New-PlanAction $Row $Access 'Blocked' $a.Token 'This user is not in the environment, and -SkipSecurityRoles is set.' 'Blocked'))
            return $false
        }
        $notes.Add((New-PlanAction $Row $Access 'Note' $a.Token "Has no $script:MakerRole role and -SkipSecurityRoles is set, so this user may not be able to open the agent." 'Info'))
        return $true
    }

    # ---- Makers
    $currentMakers = @{}
    foreach ($m in $Access.Makers) {
        if (-not $currentMakers.ContainsKey($m.Key)) { $currentMakers[$m.Key] = New-Object System.Collections.Generic.List[object] }
        $currentMakers[$m.Key].Add($m)
    }
    $desiredMakers = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($Row.HasMakers) {
        foreach ($a in $Row.Makers) {
            if ($a.Kind -eq 'Unresolved') { continue }
            if ($a.Kind -ne 'User') {
                $notes.Add((New-PlanAction $Row $Access 'Blocked' $a.Token 'Makers must be individual users. Groups can only be chat users.' 'Blocked'))
                continue
            }
            [void]$desiredMakers.Add($a.ObjectId)
            if ($currentMakers.ContainsKey($a.ObjectId)) { continue }
            if (-not $Access.AgentTeam) {
                $notes.Add((New-PlanAction $Row $Access 'Blocked' $a.Token "Can't add a maker: $($Access.TeamNote)." 'Blocked'))
                continue
            }
            if (& $canShare $a) {
                $adds.Add((New-PlanAction $Row $Access 'AddMaker' $a.Token "Add to team '$($Access.AgentTeam.Name)'." -ObjectId $a.ObjectId -SystemUserId $a.SystemUserId -TeamId $Access.AgentTeam.TeamId))
            }
        }
    }
    $staysMaker = {
        param($key)
        if ($key -eq $Access.OwnerKey -or $desiredMakers.Contains($key)) { return $true }
        return ($currentMakers.ContainsKey($key) -and -not ($removeOthers -and $Row.HasMakers))
    }

    # ---- Users
    $desiredUsers = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($Row.HasUsers -and $Access.AuthMode -eq 1) {
        $notes.Add((New-PlanAction $Row $Access 'Note' '' "This agent has no authentication, so anyone with the link can chat. Users aren't changed." 'Info'))
    }
    elseif ($Row.HasUsers) {
        $wantEveryone = @($Row.Users | Where-Object { $_.Kind -eq 'Everyone' }).Count -gt 0
        $groups = @($Row.Users | Where-Object { $_.Kind -eq 'Group' })
        $people = @($Row.Users | Where-Object { $_.Kind -eq 'User' })
        $isOpen = $Access.Policy -in $script:PolicyAny, $script:PolicyAnyMultiTenant
        $isGroupPolicy = $Access.Policy -eq $script:PolicyGroupMembership

        $readers = @{}
        foreach ($u in $Access.Users) { $readers[$u.Key] = $u }
        foreach ($a in $people) {
            [void]$desiredUsers.Add($a.ObjectId)
            if (& $staysMaker $a.ObjectId) { continue }
            if ($readers.ContainsKey($a.ObjectId)) { continue }
            # A direct editor being demoted keeps the share; it's reduced to read-only below.
            if (@($currentMakers[$a.ObjectId] | Where-Object { $_.Via -eq 'Direct' }).Count -gt 0) { continue }
            if (& $canShare $a) {
                $adds.Add((New-PlanAction $Row $Access 'AddUser' $a.Token 'Share the agent with this user (read access).' -ObjectId $a.ObjectId -SystemUserId $a.SystemUserId))
            }
        }

        # Which policy the agent should end up with. $null means leave it as it is.
        $newPolicy = $null
        if ($wantEveryone) { if (-not $isOpen) { $newPolicy = $script:PolicyAny } }
        elseif ($removeOthers) {
            if ($isOpen) {
                $groupsOnly = $groups.Count -gt 0 -and $people.Count -eq 0 -and $groups.Count -le $script:MaxPolicyGroups
                $newPolicy = if ($groupsOnly) { $script:PolicyGroupMembership } else { $script:PolicyAgentReaders }
            }
            elseif ($isGroupPolicy -and $groups.Count -eq 0) { $newPolicy = $script:PolicyAgentReaders }
        }
        $useGroupList = ($newPolicy -eq $script:PolicyGroupMembership) -or ($isGroupPolicy -and $null -eq $newPolicy)

        foreach ($g in $groups) { [void]$desiredUsers.Add($g.ObjectId) }
        if ($useGroupList) {
            $list = New-Object System.Collections.Generic.List[string]
            if (-not $removeOthers) { foreach ($g in $Access.PolicyGroups) { $list.Add($g) } }
            foreach ($g in $groups) { if (-not $list.Contains($g.ObjectId)) { $list.Add($g.ObjectId) } }
            $sameList = (-not $newPolicy) -and ((@($list | Sort-Object) -join ',') -eq (@($Access.PolicyGroups | Sort-Object) -join ','))
            if ($list.Count -gt $script:MaxPolicyGroups) {
                $notes.Add((New-PlanAction $Row $Access 'Blocked' '' "An agent can list at most $script:MaxPolicyGroups groups, and this would need $($list.Count)." 'Blocked'))
            }
            elseif (-not $sameList) {
                $policyChanges.Add((New-PlanAction $Row $Access 'SetGroupList' (($groups | ForEach-Object { $_.Token }) -join ';') "Set the agent's allowed groups ($($list.Count))." -Value ($list -join ',')))
            }
        }
        else {
            foreach ($g in $groups) {
                $shared = $readers.ContainsKey($g.ObjectId) -and $readers[$g.ObjectId].Via -eq 'GroupShare'
                if (-not $shared) {
                    $adds.Add((New-PlanAction $Row $Access 'AddGroup' $g.Token 'Share the agent with this group (read access).' -ObjectId $g.ObjectId))
                }
            }
            if ($null -ne $newPolicy) {
                $label = if ($newPolicy -eq $script:PolicyAny) { 'everyone in the organization' } else { 'only the people and groups it is shared with' }
                $policyChanges.Add((New-PlanAction $Row $Access 'SetPolicy' 'Chat access' "Let $label chat with this agent." -Value $newPolicy))
            }
        }

        if (-not $wantEveryone -and -not $removeOthers -and $isOpen -and ($people.Count + $groups.Count) -gt 0) {
            $notes.Add((New-PlanAction $Row $Access 'Note' '' 'This agent is open to everyone, so these shares only matter once it is restricted. Use -Mirror to restrict it.' 'Info'))
        }
        if ($useGroupList -and $people.Count -gt 0) {
            $notes.Add((New-PlanAction $Row $Access 'Note' '' 'This agent allows chat by group membership, so individual users may not be able to chat. Add them to one of its groups.' 'Info'))
        }

        if ($removeOthers) {
            foreach ($u in $Access.Users) {
                if ($desiredUsers.Contains($u.Key) -or $desiredMakers.Contains($u.Key)) { continue }
                if ($u.Via -eq 'Direct') {
                    $removals.Add((New-PlanAction $Row $Access 'RemoveUser' (Get-PrincipalText $u) 'Stop sharing the agent with this user.' -ObjectId $u.ObjectId -SystemUserId $u.SystemUserId))
                }
                elseif ($u.Via -eq 'GroupShare') {
                    $removals.Add((New-PlanAction $Row $Access 'RemoveGroup' (Get-PrincipalText $u) 'Stop sharing the agent with this group.' -ObjectId $u.ObjectId -TeamId $u.TeamId))
                }
                elseif ($u.Via -like 'Team:*') {
                    $notes.Add((New-PlanAction $Row $Access 'Note' (Get-PrincipalText $u) "Has access through $($u.Via.Substring(6)), which this tool doesn't change." 'Info'))
                }
            }
        }
    }

    # ---- Makers no longer listed
    if ($removeOthers -and $Row.HasMakers) {
        foreach ($key in @($currentMakers.Keys)) {
            if ($desiredMakers.Contains($key)) { continue }
            if ($key -eq $Access.OwnerKey) {
                $notes.Add((New-PlanAction $Row $Access 'Note' (Get-PrincipalText $currentMakers[$key][0]) "The owner always keeps access and isn't removed." 'Info'))
                continue
            }
            foreach ($m in $currentMakers[$key]) {
                $token = Get-PrincipalText $m
                if ($m.Via -eq 'AgentTeam') {
                    $removals.Add((New-PlanAction $Row $Access 'RemoveMaker' $token "Remove from team '$($Access.AgentTeam.Name)'." -ObjectId $m.ObjectId -SystemUserId $m.SystemUserId -TeamId $m.TeamId))
                }
                elseif ($m.Via -eq 'Direct' -and $desiredUsers.Contains($key)) {
                    $removals.Add((New-PlanAction $Row $Access 'SetReadOnly' $token 'Reduce this user to read access.' -ObjectId $m.ObjectId -SystemUserId $m.SystemUserId))
                }
                elseif ($m.Via -eq 'Direct') {
                    $removals.Add((New-PlanAction $Row $Access 'RemoveUser' $token 'Stop sharing the agent with this user.' -ObjectId $m.ObjectId -SystemUserId $m.SystemUserId))
                }
                else {
                    $notes.Add((New-PlanAction $Row $Access 'Note' $token "Has edit access through $($m.Via.Substring(6)), which this tool doesn't change." 'Info'))
                }
            }
        }
    }

    foreach ($list in $roles, $adds, $policyChanges, $removals, $notes) { foreach ($x in $list) { $x } }
}

function Get-EnvironmentRoleId {
    # Roles exist per business unit; a user can only be given the copy in their own.
    param($Ctx, [string]$RoleName, [string]$BusinessUnitId)
    $org = $Ctx.Org
    $hf = { Get-DataverseHeaders $org }
    if (-not $BusinessUnitId) {
        if (-not $Ctx.RootBu) {
            $bu = @(Invoke-PagedRequest -Uri "$($Ctx.Api)/businessunits?`$select=businessunitid&`$filter=_parentbusinessunitid_value eq null" -HeaderFactory $hf)
            $Ctx.RootBu = $bu[0].businessunitid
        }
        $BusinessUnitId = $Ctx.RootBu
    }
    if ($Ctx.RoleIds.ContainsKey($BusinessUnitId)) { return $Ctx.RoleIds[$BusinessUnitId] }
    $rows = @(Invoke-PagedRequest -Uri "$($Ctx.Api)/roles?`$select=roleid&`$filter=name eq '$RoleName' and _businessunitid_value eq $BusinessUnitId" -HeaderFactory $hf)
    if ($rows.Count -eq 0) { throw "The '$RoleName' role wasn't found in this environment." }
    $Ctx.RoleIds[$BusinessUnitId] = $rows[0].roleid
    return $rows[0].roleid
}

function Get-GroupTeam {
    # The Dataverse team linked to an Entra group, created on first use.
    param($Ctx, [string]$GroupId)
    $org = $Ctx.Org
    $hf = { Get-DataverseHeaders $org }
    $uri = "$($Ctx.Api)/teams?`$select=teamid,membershiptype&`$filter=azureactivedirectoryobjectid eq $GroupId"
    $rows = @(Invoke-PagedRequest -Uri $uri -HeaderFactory $hf)
    if ($rows.Count -eq 0) {
        Invoke-ApiRequest -Method POST -Uri "$($Ctx.Api)/teams" -Headers (Get-DataverseHeaders $org) -Body @{ azureactivedirectoryobjectid = $GroupId; membershiptype = 0 } | Out-Null
        $rows = @(Invoke-PagedRequest -Uri $uri -HeaderFactory $hf)
    }
    if ($rows.Count -eq 0) { throw "Could not create a Dataverse team for group $GroupId." }
    $team = @($rows | Sort-Object membershiptype)[0]
    return $team.teamid
}

function Get-ActionUserId {
    # New users appear in Dataverse shortly after their first role is assigned.
    param($Ctx, $Action)
    if ($Action.SystemUserId) { return $Action.SystemUserId }
    for ($i = 0; $i -lt 6; $i++) {
        $u = Get-SystemUserByObjectId $Ctx $Action.ObjectId -Refresh
        if ($u) { $Action.SystemUserId = $u.SystemUserId; return $u.SystemUserId }
        Start-Sleep -Seconds 5
    }
    throw "User $($Action.Target) has not appeared in the environment yet."
}

function Invoke-PlanAction {
    # Runs one planned change. Throws on failure.
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Action)
    $headers = Get-DataverseHeaders $Ctx.Org
    $api = $Ctx.Api
    $target = @{ botid = $Action.AgentId; '@odata.type' = 'Microsoft.Dynamics.CRM.bot' }
    $userRef = { @{ systemuserid = (Get-ActionUserId $Ctx $Action); '@odata.type' = 'Microsoft.Dynamics.CRM.systemuser' } }
    $patchBot = {
        param($Fields)
        $h = Get-DataverseHeaders $Ctx.Org
        $h['If-Match'] = '*'
        Invoke-ApiRequest -Method PATCH -Uri "$api/bots($($Action.AgentId))" -Headers $h -Body $Fields | Out-Null
    }

    switch ($Action.Action) {
        'AddRole' {
            $u = Get-SystemUserByObjectId $Ctx $Action.ObjectId
            $roleId = Get-EnvironmentRoleId $Ctx $script:MakerRole $(if ($u) { $u.BusinessUnitId } else { $null })
            # Addressing the user by object ID also adds them to Dataverse if they aren't there yet.
            Invoke-ApiRequest -Method POST -Headers $headers -Uri "$api/systemusers(azureactivedirectoryobjectid=$($Action.ObjectId))/systemuserroles_association/`$ref" -Body @{ '@odata.id' = "$api/roles($roleId)" } | Out-Null
            if ($u) { $Ctx.RoleOk[$u.SystemUserId] = $true }
        }
        'AddMaker' {
            Invoke-ApiRequest -Method POST -Headers $headers -Uri "$api/teams($($Action.TeamId))/Microsoft.Dynamics.CRM.AddMembersTeam" -Body @{ Members = @(& $userRef) } | Out-Null
        }
        'RemoveMaker' {
            Invoke-ApiRequest -Method POST -Headers $headers -Uri "$api/teams($($Action.TeamId))/Microsoft.Dynamics.CRM.RemoveMembersTeam" -Body @{ Members = @(& $userRef) } | Out-Null
        }
        'AddUser' {
            Invoke-ApiRequest -Method POST -Headers $headers -Uri "$api/GrantAccess" -Body @{ Target = $target; PrincipalAccess = @{ AccessMask = 'ReadAccess'; Principal = (& $userRef) } } | Out-Null
        }
        'SetReadOnly' {
            Invoke-ApiRequest -Method POST -Headers $headers -Uri "$api/ModifyAccess" -Body @{ Target = $target; PrincipalAccess = @{ AccessMask = 'ReadAccess'; Principal = (& $userRef) } } | Out-Null
        }
        'RemoveUser' {
            Invoke-ApiRequest -Method POST -Headers $headers -Uri "$api/RevokeAccess" -Body @{ Target = $target; Revokee = (& $userRef) } | Out-Null
        }
        'AddGroup' {
            $teamId = Get-GroupTeam $Ctx $Action.ObjectId
            Invoke-ApiRequest -Method POST -Headers $headers -Uri "$api/GrantAccess" -Body @{ Target = $target; PrincipalAccess = @{ AccessMask = 'ReadAccess'; Principal = @{ teamid = $teamId; '@odata.type' = 'Microsoft.Dynamics.CRM.team' } } } | Out-Null
        }
        'RemoveGroup' {
            Invoke-ApiRequest -Method POST -Headers $headers -Uri "$api/RevokeAccess" -Body @{ Target = $target; Revokee = @{ teamid = $Action.TeamId; '@odata.type' = 'Microsoft.Dynamics.CRM.team' } } | Out-Null
        }
        'SetPolicy' {
            # authorizedsecuritygroupids only applies under the group membership policy.
            & $patchBot @{ accesscontrolpolicy = [int]$Action.Value; authorizedsecuritygroupids = $null }
        }
        'SetGroupList' {
            & $patchBot @{ accesscontrolpolicy = $script:PolicyGroupMembership; authorizedsecuritygroupids = [string]$Action.Value }
        }
        default { throw "Unknown action '$($Action.Action)'." }
    }
}

function Get-ImportPlan {
    <#
      Reads current access and builds the change list for every CSV row.
      Returns the actions, the before-change rows for backup, and each environment's context.
    #>
    param([object[]]$Rows, [object[]]$Environments, [switch]$Mirror, [switch]$SkipSecurityRoles)
    $actions = New-Object System.Collections.Generic.List[object]
    $before = New-Object System.Collections.Generic.List[object]
    $contexts = @{}

    # Listing an agent twice would make the second row undo the first.
    $dupes = @{}
    foreach ($g in ($Rows | Group-Object { "$($_.Environment)|$($_.AgentName)|$($_.AgentId)".ToLowerInvariant() })) {
        if ($g.Count -gt 1) { foreach ($r in $g.Group) { $dupes[$r.Line] = $true } }
    }

    foreach ($envRows in ($Rows | Group-Object { $_.Environment.ToLowerInvariant() })) {
        $wanted = $envRows.Name
        $matched = @($Environments | Where-Object { $_.DisplayName.ToLowerInvariant() -eq $wanted -or $_.EnvironmentId.ToLowerInvariant() -eq $wanted })
        if ($matched.Count -ne 1) {
            $why = if ($matched.Count -eq 0) { 'Environment not found, or it has no Dataverse.' } else { 'More than one environment has this name. Use the environment ID.' }
            foreach ($r in $envRows.Group) { $actions.Add((New-PlanAction $r $null 'Blocked' $r.Environment $why 'Blocked')) }
            continue
        }
        $ctx = New-EnvironmentContext $matched[0]
        $contexts[$wanted] = $ctx
        $bots = @(Get-EnvironmentAgents $ctx)
        foreach ($r in $envRows.Group) {
            if ($dupes.ContainsKey($r.Line)) {
                $actions.Add((New-PlanAction $r $null 'Blocked' $r.AgentName 'This agent is listed more than once in the CSV.' 'Blocked'))
                continue
            }
            $found = @()
            if ($r.AgentId) { $found = @($bots | Where-Object { [string]$_.botid -eq $r.AgentId }) }
            if ($found.Count -eq 0) { $found = @($bots | Where-Object { [string]$_.name -eq $r.AgentName }) }
            if ($found.Count -ne 1) {
                $why = if ($found.Count -eq 0) { 'No active agent has this name here.' } else { "$($found.Count) agents have this name. Add the AgentId column." }
                $actions.Add((New-PlanAction $r $null 'Blocked' $r.AgentName $why 'Blocked'))
                continue
            }
            try {
                $access = Get-AgentAccess -Ctx $ctx -Bot $found[0]
                $before.Add((ConvertTo-AssignmentRow -Access $access -EnvironmentName $ctx.Environment.DisplayName))
                $resolved = $r.PSObject.Copy()
                $resolved.Makers = @($r.Makers | ForEach-Object { Get-EnvironmentAssignee $ctx (Resolve-Assignee $_) })
                $resolved.Users = @($r.Users | ForEach-Object { Get-EnvironmentAssignee $ctx (Resolve-Assignee $_) })
                foreach ($x in (Get-AssignmentPlan -Row $resolved -Access $access -Mirror:$Mirror -SkipSecurityRoles:$SkipSecurityRoles)) { $actions.Add($x) }
            }
            catch { $actions.Add((New-PlanAction $r $null 'Blocked' $r.AgentName "Could not read this agent: $($_.Exception.Message)" 'Blocked')) }
        }
    }

    # A role is assigned once per user, however many agents they appear on.
    $seenRoles = New-Object 'System.Collections.Generic.HashSet[string]'
    $unique = @($actions | Where-Object { $_.Action -ne 'AddRole' -or $seenRoles.Add("$($_.Environment)|$($_.ObjectId)".ToLowerInvariant()) })
    return @{ Actions = $unique; Before = $before.ToArray(); Contexts = $contexts }
}

function Invoke-ImportPlan {
    # Runs planned actions, recording the result on each. A failed role stops that user's other changes.
    param([object[]]$Actions, [hashtable]$Contexts)
    $failedUsers = New-Object 'System.Collections.Generic.HashSet[string]'
    $planned = @($Actions | Where-Object { $_.Status -eq 'Planned' })
    $i = 0
    foreach ($a in $planned) {
        $i++
        Write-Progress -Activity 'Applying agent assignments' -Status "$($a.AgentName): $($a.Action) $($a.Target)" -PercentComplete (($i / $planned.Count) * 100)
        $userKey = "$($a.Environment)|$($a.ObjectId)".ToLowerInvariant()
        if ($a.ObjectId -and $failedUsers.Contains($userKey)) {
            $a.Status = 'Skipped'
            $a.Detail = 'Skipped because assigning the security role failed.'
            continue
        }
        try {
            Invoke-PlanAction -Ctx $Contexts[$a.Environment.ToLowerInvariant()] -Action $a
            $a.Status = 'Done'
        }
        catch {
            $a.Status = 'Failed'
            $a.Detail = $_.Exception.Message
            Write-Log "$($a.AgentName): $($a.Action) $($a.Target) failed: $($_.Exception.Message)" -Level Error -Area 'Write'
            if ($a.Action -eq 'AddRole') { [void]$failedUsers.Add($userKey) }
        }
    }
    Write-Progress -Activity 'Applying agent assignments' -Completed
}
