# Copilot Studio inventory from Dataverse: agents, tools, connectors, knowledge, triggers, sharing.
# Detection rules follow Microsoft's Copilot Agent Kit "Agent Inventory data source" reference.

$script:FormattedSuffix = '@OData.Community.Display.V1.FormattedValue'

$script:ToolKindLabels = @{
    'InvokeConnectorTaskAction'        = 'Connector'
    'InvokeFlowTaskAction'             = 'Agent flow'
    'InvokeAIBuilderModelTaskAction'   = 'Prompt'
    'InvokeExternalAgentTaskAction'    = 'MCP / external agent'
    'InvokeConnectedAgentTaskAction'   = 'Connected agent'
    'InvokeCustomConnectorTaskAction'  = 'Custom connector'
    'InvokeComputerUseTaskAction'      = 'Computer use'
    'InvokeFlowAction'                 = 'Agent flow (topic)'
    'InvokeConnectorAction'            = 'Connector (topic)'
    'HttpRequestAction'                = 'HTTP request (topic)'
    'InvokeAIBuilderModelAction'       = 'Prompt (topic)'
    'InvokeSkillAction'                = 'Bot Framework skill (topic)'
}
$script:TopicActionKinds = @('InvokeFlowAction', 'InvokeConnectorAction', 'HttpRequestAction', 'InvokeAIBuilderModelAction', 'InvokeSkillAction')

function Get-DataverseHeaders {
    param([string]$OrgUrl)
    @{
        Authorization      = "Bearer $(Get-ResourceToken $OrgUrl)"
        Accept             = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version'    = '4.0'
        Prefer             = 'odata.include-annotations="OData.Community.Display.V1.FormattedValue",odata.maxpagesize=5000'
    }
}

function Get-Formatted {
    param($Row, [string]$Field)
    Get-Prop $Row ($Field + $script:FormattedSuffix)
}

function Get-ConnectorShortName {
    param([string]$ConnectorId)
    if (-not $ConnectorId) { return $null }
    return ($ConnectorId.TrimEnd('/') -split '/')[-1]
}

function Get-DataverseUserCache {
    # systemuserid -> @{ ObjectId; Upn; Name } per environment.
    param([string]$OrgUrl, [string[]]$SystemUserIds, [hashtable]$Cache)
    foreach ($id in ($SystemUserIds | Where-Object { $_ } | Select-Object -Unique)) {
        if ($Cache.ContainsKey($id)) { continue }
        try {
            $u = Invoke-ApiRequest -Uri "$OrgUrl/api/data/v9.2/systemusers($id)?`$select=fullname,domainname,azureactivedirectoryobjectid" -Headers (Get-DataverseHeaders $OrgUrl)
            $Cache[$id] = [pscustomobject]@{ ObjectId = $u.azureactivedirectoryobjectid; Upn = $u.domainname; Name = $u.fullname }
        }
        catch { $Cache[$id] = [pscustomobject]@{ ObjectId = $null; Upn = $null; Name = $null } }
    }
}

function Get-FlowConnections {
    <#
      Reads a cloud flow's connection references from workflow.clientdata.
    #>
    param([string]$OrgUrl, [string]$FlowId, [hashtable]$FlowCache)
    if ($FlowCache.ContainsKey($FlowId)) { return $FlowCache[$FlowId] }
    $info = [pscustomobject]@{ Name = $null; Connections = @() }
    try {
        $wf = Invoke-ApiRequest -Uri "$OrgUrl/api/data/v9.2/workflows($FlowId)?`$select=name,clientdata" -Headers (Get-DataverseHeaders $OrgUrl)
        $info.Name = $wf.name
        $cd = ConvertFrom-JsonSafe $wf.clientdata
        $refs = Get-Prop (Get-Prop $cd 'properties') 'connectionReferences'
        if ($refs) {
            $info.Connections = @(foreach ($p in $refs.PSObject.Properties) {
                    $r = $p.Value
                    $imp = Get-Prop $r 'impersonation'
                    $impSource = Get-Prop $imp 'source'
                    $runtime = Get-Prop $r 'runtimeSource'
                    $mode = if ($impSource -eq 'invoker') { 'Invoker' } elseif ($runtime -eq 'invoker') { 'Invoker' } else { 'Maker' }
                    [pscustomobject]@{
                        ConnectorId         = Get-Prop (Get-Prop $r 'api') 'name'
                        ConnectionReference = Get-Prop (Get-Prop $r 'connection') 'connectionReferenceLogicalName'
                        AuthMode            = $mode
                    }
                })
        }
    }
    catch { Write-Log "Could not read flow $FlowId : $($_.Exception.Message)" -Level Warn -Area 'CopilotStudio' }
    $FlowCache[$FlowId] = $info
    return $info
}

function Get-BotSharing {
    <#
      Returns principals with access to the bot record (users, owner/access teams,
      Entra group teams) via RetrieveSharedPrincipalsAndAccess.
    #>
    param([string]$OrgUrl, [string]$BotId, [hashtable]$TeamCache)
    $rows = New-Object System.Collections.Generic.List[object]
    $uri = "$OrgUrl/api/data/v9.2/RetrieveSharedPrincipalsAndAccess(Target=@t)?@t={'@odata.id':'bots($BotId)'}"
    try { $resp = Invoke-ApiRequest -Uri $uri -Headers (Get-DataverseHeaders $OrgUrl) }
    catch {
        Write-Log "Sharing lookup failed for bot $BotId : $($_.Exception.Message)" -Level Warn -Area 'Sharing'
        return @()
    }
    foreach ($pa in @($resp.PrincipalAccesses)) {
        $mask = [string]$pa.AccessMask
        $role = if ($mask -match 'WriteAccess') { 'Editor' } else { 'Viewer' }
        $principal = $pa.Principal
        $ptype = ([string](Get-Prop $principal '@odata.type' '')) -replace '#Microsoft.Dynamics.CRM.', ''
        $principalId = Get-Prop $principal 'ownerid'
        if (-not $principalId) { $principalId = Get-Prop $principal 'systemuserid' }
        if (-not $principalId) { $principalId = Get-Prop $principal 'teamid' }

        if ($ptype -eq 'systemuser') {
            $rows.Add([pscustomobject]@{ PrincipalType = 'User'; DataverseId = $principalId; Role = $role; AccessMask = $mask; Via = 'Direct'; TeamType = $null; Members = $null })
        }
        elseif ($ptype -eq 'team') {
            if (-not $TeamCache.ContainsKey($principalId)) {
                try {
                    $t = Invoke-ApiRequest -Uri "$OrgUrl/api/data/v9.2/teams($principalId)?`$select=name,teamtype,azureactivedirectoryobjectid,isdefault" -Headers (Get-DataverseHeaders $OrgUrl)
                    $members = @()
                    if ([int]$t.teamtype -in 0, 1) {
                        $members = @(Invoke-PagedRequest -Uri "$OrgUrl/api/data/v9.2/teams($principalId)/teammembership_association?`$select=systemuserid,azureactivedirectoryobjectid,domainname,fullname" -HeaderFactory { Get-DataverseHeaders $OrgUrl })
                    }
                    $TeamCache[$principalId] = [pscustomobject]@{ Team = $t; Members = $members }
                }
                catch { $TeamCache[$principalId] = $null }
            }
            $tc = $TeamCache[$principalId]
            if (-not $tc) { continue }
            $teamType = [int]$tc.Team.teamtype
            if ($teamType -in 2, 3) {
                $rows.Add([pscustomobject]@{ PrincipalType = 'Group'; DataverseId = $principalId; ObjectId = $tc.Team.azureactivedirectoryobjectid; Name = $tc.Team.name; Role = $role; AccessMask = $mask; Via = 'Direct'; TeamType = (Get-Formatted $tc.Team 'teamtype'); Members = $null })
            }
            else {
                # Owner/access teams (including the agent's own auto-created team) are expanded to users.
                foreach ($m in $tc.Members) {
                    $rows.Add([pscustomobject]@{ PrincipalType = 'User'; DataverseId = $m.systemuserid; ObjectId = $m.azureactivedirectoryobjectid; Upn = $m.domainname; Name = $m.fullname; Role = $role; AccessMask = $mask; Via = "Team: $($tc.Team.name)"; TeamType = $null; Members = $null })
                }
            }
        }
    }
    return $rows.ToArray()
}

function Get-PolicyGroupIds {
    # Entra groups listed on the agent itself. The list only applies under the Group membership policy (2).
    param($Bot)
    if ([int](Get-Prop $Bot 'accesscontrolpolicy' 0) -ne 2) { return @() }
    ([string](Get-Prop $Bot 'authorizedsecuritygroupids' '')) -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ }
}

function Get-CopilotStudioInventory {
    param(
        [Parameter(Mandatory)]$Environment,
        [int]$MaxGroupMembers = 5000
    )
    $org = $Environment.DataverseUrl
    $api = "$org/api/data/v9.2"
    $hf = { Get-DataverseHeaders $org }

    $result = @{ Agents = @(); Tools = @(); Connectors = @(); Knowledge = @(); Sharing = @() }

    try { $bots = @(Invoke-PagedRequest -Uri "$api/bots" -HeaderFactory $hf) }
    catch {
        Write-Log "Cannot read bots in '$($Environment.DisplayName)': $($_.Exception.Message)" -Level Warn -Area 'CopilotStudio'
        return $result
    }
    if ($bots.Count -eq 0) { return $result }
    Write-Log "$($bots.Count) Copilot Studio agent(s) in '$($Environment.DisplayName)'." -Area 'CopilotStudio'

    $compFilter = 'statecode eq 0 and (componenttype eq 9 or componenttype eq 14 or componenttype eq 15 or componenttype eq 16 or componenttype eq 17)'
    $components = @(Invoke-PagedRequest -Uri "$api/botcomponents?`$select=botcomponentid,name,schemaname,componenttype,description,data,_parentbotid_value&`$filter=$compFilter" -HeaderFactory $hf)
    $compByBot = $components | Group-Object -Property '_parentbotid_value' -AsHashTable -AsString
    if (-not $compByBot) { $compByBot = @{} }

    $connRefs = @{}
    try {
        foreach ($cr in (Invoke-PagedRequest -Uri "$api/connectionreferences?`$select=connectionreferencelogicalname,connectionreferencedisplayname,connectorid,connectionid" -HeaderFactory $hf)) {
            $connRefs[$cr.connectionreferencelogicalname] = $cr
        }
    }
    catch { Write-Log "Cannot read connection references: $($_.Exception.Message)" -Level Warn -Area 'CopilotStudio' }

    $userCache = @{}
    Get-DataverseUserCache -OrgUrl $org -Cache $userCache -SystemUserIds @(
        $bots | ForEach-Object { $_._ownerid_value; $_._createdby_value; $_._modifiedby_value; (Get-Prop $_ '_publishedby_value') }
    )
    $flowCache = @{}
    $teamCache = @{}

    $agents = New-Object System.Collections.Generic.List[object]
    $tools = New-Object System.Collections.Generic.List[object]
    $connectors = New-Object System.Collections.Generic.List[object]
    $knowledge = New-Object System.Collections.Generic.List[object]
    $sharing = New-Object System.Collections.Generic.List[object]

    foreach ($bot in $bots) {
        $botId = $bot.botid
        $cfg = ConvertFrom-JsonSafe (Get-Prop $bot 'configuration')
        $sync = ConvertFrom-JsonSafe (Get-Prop $bot 'synchronizationstatus')
        $comps = if ($compByBot.ContainsKey([string]$botId)) { @($compByBot[[string]$botId]) } else { @() }
        $agentConnectors = New-Object System.Collections.Generic.List[object]

        $addConnector = {
            param($ConnectorId, $ConnRef, $Mode, $Source)
            $cid = $ConnectorId
            $displayRef = $ConnRef
            if (-not $cid -and $ConnRef -and $connRefs.ContainsKey($ConnRef)) {
                $cid = $connRefs[$ConnRef].connectorid
                $displayRef = $connRefs[$ConnRef].connectionreferencedisplayname
            }
            if (-not $cid -and $ConnRef) {
                # Logical names usually embed the connector, e.g. cr123_sharedoffice365_abc.
                $m = [regex]::Match($ConnRef, 'shared_?[a-z0-9]+', 'IgnoreCase')
                if ($m.Success) { $cid = $m.Value }
            }
            $agentConnectors.Add([pscustomobject]@{
                    AgentKey            = "cs:$botId"
                    AgentName           = $bot.name
                    ConnectorId         = $cid
                    Connector           = ((Get-ConnectorShortName $cid) -replace '^shared_')
                    ConnectionReference = $displayRef
                    AuthMode            = $Mode
                    UsedBy              = $Source
                })
        }

        # --- Tools (TaskDialog components) and actions inside topics ---
        foreach ($c in ($comps | Where-Object { $_.componenttype -eq 9 })) {
            $data = [string]$c.data
            if (-not $data) { continue }
            $connRefsInData = Get-RegexValues $data 'connectionReference:\s*(\S+)'
            $mode = Get-FirstRegexValue $data 'mode:\s*(Maker|Invoker)'
            $flowIds = Get-RegexValues $data 'flowId:\s*([0-9a-fA-F-]{36})'

            if ($data -match 'kind:\s*TaskDialog') {
                $kind = Get-FirstRegexValue $data '(?m)action:\s*\r?\n\s*kind:\s*(\w+)'
                if (-not $kind) { $kind = Get-FirstRegexValue $data 'kind:\s*(Invoke\w+TaskAction)' }
                $label = if ($kind) { $script:ToolKindLabels[$kind] } else { $null }
                if (-not $label) { $label = $kind }
                $tools.Add([pscustomobject]@{
                        AgentKey            = "cs:$botId"
                        AgentName           = $bot.name
                        ToolName            = $c.name
                        ToolType            = $label
                        ActionKind          = $kind
                        OperationId         = Get-FirstRegexValue $data 'operationId:\s*(\S+)'
                        ConnectionReference = ($connRefsInData -join '; ')
                        AuthMode            = $mode
                        Description         = $c.description
                        Source              = 'Tool'
                        SchemaName          = $c.schemaname
                    })
                foreach ($r in $connRefsInData) { & $addConnector $null $r $mode "Tool: $($c.name)" }
            }
            else {
                $kinds = Get-RegexValues $data 'kind:\s*(\w+)' | Where-Object { $script:TopicActionKinds -contains $_ }
                foreach ($k in $kinds) {
                    $tools.Add([pscustomobject]@{
                            AgentKey            = "cs:$botId"
                            AgentName           = $bot.name
                            ToolName            = "$($c.name) [$k]"
                            ToolType            = $script:ToolKindLabels[$k]
                            ActionKind          = $k
                            OperationId         = if ($k -eq 'HttpRequestAction') { Get-FirstRegexValue $data 'url:\s*(.+)' } else { Get-FirstRegexValue $data 'operationId:\s*(\S+)' }
                            ConnectionReference = ($connRefsInData -join '; ')
                            AuthMode            = $mode
                            Description         = $c.description
                            Source              = "Topic: $($c.name)"
                            SchemaName          = $c.schemaname
                        })
                }
                foreach ($r in $connRefsInData) { & $addConnector $null $r $mode "Topic: $($c.name)" }
            }
            foreach ($fid in $flowIds) {
                $flow = Get-FlowConnections -OrgUrl $org -FlowId $fid -FlowCache $flowCache
                foreach ($fc in $flow.Connections) { & $addConnector $fc.ConnectorId $fc.ConnectionReference $fc.AuthMode "Flow: $($flow.Name)" }
            }
        }

        # --- Triggers (autonomous agents) ---
        $triggers = @($comps | Where-Object { $_.componenttype -eq 17 })
        foreach ($t in $triggers) {
            $data = [string]$t.data
            $ttype = Get-FirstRegexValue $data 'triggerConnectionType:\s*(.+)'
            $tools.Add([pscustomobject]@{
                    AgentKey = "cs:$botId"; AgentName = $bot.name; ToolName = $t.name; ToolType = 'Trigger'
                    ActionKind = $ttype; OperationId = Get-FirstRegexValue $data 'operationId:\s*(\S+)'
                    ConnectionReference = ((Get-RegexValues $data 'connectionReference:\s*(\S+)') -join '; ')
                    AuthMode = $null; Description = $t.description; Source = 'Trigger'; SchemaName = $t.schemaname
                })
            foreach ($r in (Get-RegexValues $data 'connectionReference:\s*(\S+)')) { & $addConnector $null $r 'Maker' "Trigger: $($t.name)" }
            foreach ($fid in (Get-RegexValues $data 'flowId:\s*([0-9a-fA-F-]{36})')) {
                $flow = Get-FlowConnections -OrgUrl $org -FlowId $fid -FlowCache $flowCache
                foreach ($fc in $flow.Connections) { & $addConnector $fc.ConnectorId $fc.ConnectionReference $fc.AuthMode "Trigger flow: $($flow.Name)" }
            }
        }

        # --- Knowledge sources ---
        foreach ($k in ($comps | Where-Object { $_.componenttype -in 14, 16 })) {
            $data = [string]$k.data
            $srcKind = if ($k.componenttype -eq 14) { 'File' } else { Get-FirstRegexValue $data '(?m)source:\s*\r?\n\s*kind:\s*(\w+)' }
            $target = Get-FirstRegexValue $data '(?m)^\s*(?:site|url|siteUrl|webUrl):\s*(\S+)'
            $knowledge.Add([pscustomobject]@{
                    AgentKey   = "cs:$botId"; AgentName = $bot.name; KnowledgeName = $k.name
                    SourceType = $srcKind; Target = $target; Description = $k.description
                })
        }

        # --- Description / instructions (Custom GPT component) ---
        $gpt = $comps | Where-Object { $_.componenttype -eq 15 } | Select-Object -First 1
        $instructions = if ($gpt) { Get-FirstRegexValue ([string]$gpt.data) '(?s)instructions:\s*\|?-?\s*\r?\n(.+?)(?:\r?\n\S|\z)' } else { $null }
        if ($instructions -and $instructions.Length -gt 500) { $instructions = $instructions.Substring(0, 500) + '...' }

        # --- Sharing ---
        $shares = @(Get-BotSharing -OrgUrl $org -BotId $botId -TeamCache $teamCache)
        # Groups can also be listed on the agent itself rather than shared through a team.
        $teamGroups = @($shares | Where-Object { $_.PrincipalType -eq 'Group' } | ForEach-Object { ([string]$_.ObjectId).ToLowerInvariant() })
        foreach ($gid in @(Get-PolicyGroupIds $bot)) {
            if ($teamGroups -contains $gid) { continue }
            $dir = Get-DirectoryObject $gid
            $shares += [pscustomobject]@{
                PrincipalType = 'Group'; DataverseId = $null; ObjectId = $gid; Role = 'Viewer'; AccessMask = $null
                Name = if ($dir -and $dir.DisplayName) { $dir.DisplayName } else { $gid }
                Via = 'Access control policy'; TeamType = 'Security group'; Members = $null
            }
        }
        Get-DataverseUserCache -OrgUrl $org -Cache $userCache -SystemUserIds @($shares | Where-Object { $_.PrincipalType -eq 'User' -and -not $_.ObjectId } | ForEach-Object { $_.DataverseId })
        $ownerOid = if ($userCache[$bot._ownerid_value]) { $userCache[$bot._ownerid_value].ObjectId } else { $null }

        $reach = New-Object 'System.Collections.Generic.HashSet[string]'
        $extraReach = 0
        $editors = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($s in $shares) {
            if ($s.PrincipalType -eq 'User') {
                $u = $userCache[$s.DataverseId]
                $oid = if ($s.ObjectId) { $s.ObjectId } elseif ($u) { $u.ObjectId } else { $null }
                $upn = if ($s.PSObject.Properties['Upn'] -and $s.Upn) { $s.Upn } elseif ($u) { $u.Upn } else { $null }
                $name = if ($s.PSObject.Properties['Name'] -and $s.Name) { $s.Name } elseif ($u) { $u.Name } else { $null }
                if ($oid) {
                    if ($oid -ne $ownerOid) { [void]$reach.Add($oid.ToLowerInvariant()) }
                    if ($s.Role -eq 'Editor') { [void]$editors.Add($oid.ToLowerInvariant()) }
                }
                $sharing.Add([pscustomobject]@{
                        AgentKey = "cs:$botId"; AgentName = $bot.name; PrincipalType = 'User'; PrincipalId = $oid
                        PrincipalName = $name; UserPrincipalName = $upn; Role = $s.Role; Via = $s.Via; GroupMemberCount = $null
                    })
            }
            else {
                $gm = Get-GroupMembers -GroupId $s.ObjectId -MaxMembers $MaxGroupMembers
                if ($gm) {
                    foreach ($m in $gm.MemberIds) { if ($m -ne $ownerOid) { [void]$reach.Add($m) } }
                    if ($gm.Truncated) { $extraReach += $gm.Count }
                }
                $sharing.Add([pscustomobject]@{
                        AgentKey = "cs:$botId"; AgentName = $bot.name; PrincipalType = "Group ($($s.TeamType))"; PrincipalId = $s.ObjectId
                        PrincipalName = $s.Name; UserPrincipalName = $null; Role = $s.Role; Via = $s.Via
                        GroupMemberCount = if ($gm) { $gm.Count } else { $null }
                    })
            }
        }

        $authMode = [int](Get-Prop $bot 'authenticationmode' 0)
        $policy = Get-Prop $bot 'accesscontrolpolicy'
        $audience = if ($authMode -eq 1) { 'Public (no authentication)' }
        elseif ($null -ne $policy -and [int]$policy -in 0, 3 -and $authMode -eq 2) { 'Entire organization' }
        elseif ($null -ne $policy -and [int]$policy -eq 2) { 'Security groups' }
        else { 'Specific users/groups' }
        if ($audience -eq 'Entire organization') {
            $sharing.Add([pscustomobject]@{
                    AgentKey = "cs:$botId"; AgentName = $bot.name; PrincipalType = 'Organization'; PrincipalId = $null
                    PrincipalName = 'Everyone in organization'; UserPrincipalName = $null; Role = 'Viewer'; Via = 'Access control policy'; GroupMemberCount = $null
                })
        }

        # Distinct connectors for this agent.
        $distinctConnectors = @($agentConnectors | Where-Object { $_.Connector } | Sort-Object Connector, UsedBy -Unique)
        foreach ($dc in $distinctConnectors) { $connectors.Add($dc) }

        $owner = $userCache[$bot._ownerid_value]
        # Agents that were never published have no publisher.
        $publishedBy = Get-Prop $bot '_publishedby_value'
        $publisher = if ($publishedBy) { $userCache[$publishedBy] } else { $null }
        $agentTools = @($tools | Where-Object { $_.AgentKey -eq "cs:$botId" })
        $publishedOn = Get-Prop $bot 'publishedon'

        $agents.Add([pscustomobject][ordered]@{
                AgentKey              = "cs:$botId"
                Source                = 'Copilot Studio'
                AgentId               = $botId
                Name                  = $bot.name
                SchemaName            = $bot.schemaname
                ApplicationId         = Get-Prop $sync 'applicationId'
                Description           = if ($gpt) { $gpt.description } else { $null }
                Instructions          = $instructions
                EnvironmentName       = $Environment.DisplayName
                EnvironmentId         = $Environment.EnvironmentId
                EnvironmentType       = $Environment.EnvironmentType
                Owner                 = if ($owner) { $owner.Name } else { Get-Formatted $bot '_ownerid_value' }
                OwnerUPN              = if ($owner) { $owner.Upn } else { $null }
                CreatedBy             = Get-Formatted $bot '_createdby_value'
                CreatedOn             = Get-Prop $bot 'createdon'
                ModifiedOn            = Get-Prop $bot 'modifiedon'
                IsPublished           = [bool]$publishedOn
                LastPublishedOn       = $publishedOn
                PublishedBy           = if ($publisher) { $publisher.Name } else { Get-Formatted $bot '_publishedby_value' }
                FirstPublishInAudit   = $null
                PublishCountInAudit   = $null
                Status                = Get-Formatted $bot 'statecode'
                IsManaged             = Get-Prop $bot 'ismanaged'
                AuthenticationMode    = Get-Formatted $bot 'authenticationmode'
                AccessPolicy          = Get-Formatted $bot 'accesscontrolpolicy'
                Audience              = $audience
                SharedWithEveryone    = ($audience -in 'Entire organization', 'Public (no authentication)')
                SharedUserCount       = $reach.Count + $extraReach
                SharedGroupCount      = @($shares | Where-Object { $_.PrincipalType -eq 'Group' }).Count
                EditorCount           = $editors.Count
                Orchestration         = if ((Get-Prop $cfg 'GenerativeActionsEnabled') -or (Get-Prop (Get-Prop $cfg 'settings') 'GenerativeActionsEnabled')) { 'Generative' } else { 'Classic' }
                UsesModelKnowledge    = [bool](Get-Prop (Get-Prop $cfg 'aISettings') 'useModelKnowledge' (Get-Prop $cfg 'useModelKnowledge' $false))
                IsAutonomous          = ($triggers.Count -gt 0)
                ToolCount             = @($agentTools | Where-Object { $_.ToolType -ne 'Trigger' }).Count
                TriggerCount          = $triggers.Count
                ConnectorCount        = @($distinctConnectors | Select-Object -ExpandProperty Connector -Unique).Count
                KnowledgeCount        = @($knowledge | Where-Object { $_.AgentKey -eq "cs:$botId" }).Count
                UsesMCP               = [bool]($agentTools | Where-Object { $_.ActionKind -eq 'InvokeExternalAgentTaskAction' })
                Connectors            = (@($distinctConnectors | Select-Object -ExpandProperty Connector -Unique) -join ', ')
            })
    }

    $result.Agents = $agents.ToArray()
    $result.Tools = $tools.ToArray()
    $result.Connectors = $connectors.ToArray()
    $result.Knowledge = $knowledge.ToArray()
    $result.Sharing = $sharing.ToArray()
    return $result
}
