# Microsoft 365 Copilot agents from the Agent 365 package catalog (Graph),
# with a Teams org app catalog fallback when the package API isn't available.

function Get-PackageAgentTools {
    # Pulls actions/capabilities out of the declarative agent manifest JSON in elementDetails.
    param($Detail, [string]$AgentKey, [string]$AgentName)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($ed in @(Get-Prop $Detail 'elementDetails' @())) {
        foreach ($el in @(Get-Prop $ed 'elements' @())) {
            $def = ConvertFrom-JsonSafe (Get-Prop $el 'definition')
            if (-not $def) { continue }
            foreach ($cap in @(Get-Prop $def 'capabilities' @())) {
                $rows.Add([pscustomobject]@{
                        AgentKey = $AgentKey; AgentName = $AgentName; ToolName = Get-Prop $cap 'name'; ToolType = 'Capability'
                        ActionKind = $ed.elementType; OperationId = $null; ConnectionReference = $null; AuthMode = $null
                        Description = $null; Source = 'Manifest'; SchemaName = $null
                    })
            }
            foreach ($act in @(Get-Prop $def 'actions' @())) {
                $rows.Add([pscustomobject]@{
                        AgentKey = $AgentKey; AgentName = $AgentName; ToolName = (Get-Prop $act 'id' (Get-Prop $act 'file')); ToolType = 'Action (API plugin)'
                        ActionKind = $ed.elementType; OperationId = Get-Prop $act 'file'; ConnectionReference = $null; AuthMode = $null
                        Description = $null; Source = 'Manifest'; SchemaName = $null
                    })
            }
        }
    }
    return $rows.ToArray()
}

function Get-M365AgentInventory {
    param([int]$MaxGroupMembers = 5000)
    $result = @{ Agents = @(); Tools = @(); Sharing = @(); Usage = @(); Available = $false }

    $filter = [uri]::EscapeDataString("supportedHosts/any(h:h eq 'Copilot')")
    try {
        $packages = @(Invoke-GraphPaged -Uri "https://graph.microsoft.com/v1.0/copilot/admin/catalog/packages?`$filter=$filter")
        $result.Available = $true
    }
    catch {
        Write-Log "Agent 365 package API unavailable ($($_.Exception.Message)). It needs CopilotPackages.Read.All and a Microsoft Agent 365 license. Falling back to the Teams org app catalog." -Level Warn -Area 'M365Agents'
        return Get-TeamsCatalogFallback
    }
    Write-Log "$($packages.Count) M365 Copilot agent package(s) found." -Area 'M365Agents'

    $agents = New-Object System.Collections.Generic.List[object]
    $tools = New-Object System.Collections.Generic.List[object]
    $sharing = New-Object System.Collections.Generic.List[object]

    foreach ($p in $packages) {
        $detail = $p
        try { $detail = Invoke-GraphApi -Uri "https://graph.microsoft.com/v1.0/copilot/admin/catalog/packages/$($p.id)" }
        catch { Write-Log "Package detail failed for '$($p.displayName)': $($_.Exception.Message)" -Level Warn -Area 'M365Agents' }

        $key = "m365:$($p.id)"
        $name = Get-Prop $detail 'displayName'
        $agentTools = @(Get-PackageAgentTools -Detail $detail -AgentKey $key -AgentName $name)
        foreach ($t in $agentTools) { $tools.Add($t) }

        # Sharing: explicit shares plus admin "allowed" scope.
        $reach = New-Object 'System.Collections.Generic.HashSet[string]'
        $extra = 0
        $groupCount = 0
        $principals = @()
        foreach ($set in @(@{ Name = 'sharedWithUsersAndGroups'; Role = 'Shared with' }, @{ Name = 'allowedUsersAndGroups'; Role = 'Allowed (admin)' })) {
            foreach ($e in @(Get-Prop $detail $set.Name @())) { $principals += [pscustomobject]@{ Entity = $e; Role = $set.Role } }
        }
        Resolve-DirectoryObjects @($principals | ForEach-Object { $_.Entity.resourceId })
        foreach ($pr in $principals) {
            $id = [string]$pr.Entity.resourceId
            $obj = Get-DirectoryObject $id
            $gm = $null
            if ($pr.Entity.resourceType -eq 'group') {
                $groupCount++
                $gm = Get-GroupMembers -GroupId $id -MaxMembers $MaxGroupMembers
                if ($gm) { foreach ($m in $gm.MemberIds) { [void]$reach.Add($m) }; if ($gm.Truncated) { $extra += $gm.Count } }
            }
            elseif ($id) { [void]$reach.Add($id.ToLowerInvariant()) }
            $sharing.Add([pscustomobject]@{
                    AgentKey = $key; AgentName = $name; PrincipalType = (Get-Culture).TextInfo.ToTitleCase([string]$pr.Entity.resourceType)
                    PrincipalId = $id; PrincipalName = if ($obj) { $obj.DisplayName } else { $null }
                    UserPrincipalName = if ($obj) { $obj.UserPrincipalName } else { $null }
                    Role = $pr.Role; Via = 'Package catalog'; GroupMemberCount = if ($gm) { $gm.Count } else { $null }
                })
        }
        $availableTo = [string](Get-Prop $detail 'availableTo')
        if ($availableTo -eq 'all') {
            $sharing.Add([pscustomobject]@{
                    AgentKey = $key; AgentName = $name; PrincipalType = 'Organization'; PrincipalId = $null; PrincipalName = 'Everyone in organization'
                    UserPrincipalName = $null; Role = 'Allowed (admin)'; Via = 'availableTo = all'; GroupMemberCount = $null
                })
        }

        $created = Get-Prop $detail 'createdDateTime'
        $agents.Add([pscustomobject][ordered]@{
                AgentKey              = $key
                Source                = 'M365 Copilot'
                AgentId               = $p.id
                Name                  = $name
                SchemaName            = Get-Prop $detail 'manifestId'
                ApplicationId         = Get-Prop $detail 'appId'
                Description           = Get-Prop $detail 'shortDescription'
                Instructions          = $null
                EnvironmentName       = $null
                EnvironmentId         = $null
                EnvironmentType       = (@(Get-Prop $detail 'elementTypes' @()) -join ', ')
                Owner                 = Get-Prop $detail 'publisher'
                OwnerUPN              = $null
                CreatedBy             = Get-Prop $detail 'publisher'
                CreatedOn             = $created
                ModifiedOn            = Get-Prop $detail 'lastModifiedDateTime'
                IsPublished           = ([string](Get-Prop $detail 'deployedTo') -ne 'none' -or $availableTo -ne 'none')
                LastPublishedOn       = Get-Prop $detail 'lastModifiedDateTime'
                PublishedBy           = Get-Prop $detail 'publisher'
                FirstPublishInAudit   = $null
                PublishCountInAudit   = $null
                Status                = if (Get-Prop $detail 'isBlocked' $false) { 'Blocked' } else { 'Active' }
                IsManaged             = Get-Prop $detail 'governanceMetadata'
                AuthenticationMode    = $null
                AccessPolicy          = "availableTo=$availableTo; deployedTo=$(Get-Prop $detail 'deployedTo')"
                Audience              = if ($availableTo -eq 'all') { 'Entire organization' } elseif ($availableTo -eq 'none') { 'Not available' } else { 'Specific users/groups' }
                SharedWithEveryone    = ($availableTo -eq 'all')
                SharedUserCount       = $reach.Count + $extra
                SharedGroupCount      = $groupCount
                EditorCount           = $null
                Orchestration         = Get-Prop $detail 'type'
                UsesModelKnowledge    = $null
                IsAutonomous          = $null
                ToolCount             = $agentTools.Count
                TriggerCount          = 0
                ConnectorCount        = 0
                KnowledgeCount        = @($agentTools | Where-Object { $_.ToolName -in 'OneDriveAndSharePoint', 'GraphConnectors', 'WebSearch', 'Dataverse', 'TeamsMessages', 'Email', 'People', 'Meetings' }).Count
                UsesMCP               = $null
                Connectors            = $null
                CatalogActiveUsers30d = Get-Prop $detail 'activeUsers'
                CatalogSessions30d    = Get-Prop $detail 'totalSessions'
                CatalogLastUsed       = Get-Prop $detail 'lastUsedDateTime'
                CatalogInstalledCount = @(Get-Prop $detail 'acquireUsersAndGroups' @()).Count
            })
    }
    $result.Agents = $agents.ToArray()
    $result.Tools = $tools.ToArray()
    $result.Sharing = $sharing.ToArray()
    return $result
}

function Get-TeamsCatalogFallback {
    <#
      Lists org-published Teams/M365 apps. Less detail than the package API
      (no sharing or usage), but works without an Agent 365 license.
    #>
    $result = @{ Agents = @(); Tools = @(); Sharing = @(); Usage = @(); Available = $false }
    try {
        $apps = @(Invoke-GraphPaged -Uri "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps?`$filter=distributionMethod eq 'organization'&`$expand=appDefinitions(`$expand=bot)")
    }
    catch {
        Write-Log "Teams app catalog unavailable: $($_.Exception.Message)" -Level Warn -Area 'M365Agents'
        return $result
    }
    $result.Agents = @(foreach ($a in $apps) {
            $def = @($a.appDefinitions) | Sort-Object lastModifiedDateTime -Descending | Select-Object -First 1
            $creator = Get-Prop (Get-Prop (Get-Prop $def 'createdBy') 'user') 'id'
            $creatorObj = if ($creator) { Get-DirectoryObject $creator } else { $null }
            [pscustomobject][ordered]@{
                AgentKey = "teamsapp:$($a.id)"; Source = 'M365 org app (fallback)'; AgentId = $a.id; Name = $a.displayName
                SchemaName = $a.externalId; ApplicationId = Get-Prop (Get-Prop $def 'bot') 'id'; Description = Get-Prop $def 'shortDescription'
                Instructions = $null; EnvironmentName = $null; EnvironmentId = $null; EnvironmentType = if (Get-Prop $def 'bot') { 'Bot' } else { 'App' }
                Owner = if ($creatorObj) { $creatorObj.DisplayName } else { $null }; OwnerUPN = if ($creatorObj) { $creatorObj.UserPrincipalName } else { $null }
                CreatedBy = if ($creatorObj) { $creatorObj.DisplayName } else { $null }; CreatedOn = $null; ModifiedOn = Get-Prop $def 'lastModifiedDateTime'
                IsPublished = ((Get-Prop $def 'publishingState') -eq 'published'); LastPublishedOn = Get-Prop $def 'lastModifiedDateTime'; PublishedBy = $null
                FirstPublishInAudit = $null; PublishCountInAudit = $null; Status = Get-Prop $def 'publishingState'; IsManaged = $null
                AuthenticationMode = $null; AccessPolicy = $null; Audience = 'Unknown (see Teams admin center)'; SharedWithEveryone = $null
                SharedUserCount = $null; SharedGroupCount = $null; EditorCount = $null; Orchestration = $null; UsesModelKnowledge = $null
                IsAutonomous = $null; ToolCount = 0; TriggerCount = 0; ConnectorCount = 0; KnowledgeCount = 0; UsesMCP = $null; Connectors = $null
            }
        })
    Write-Log "$($result.Agents.Count) org app(s) found in the Teams catalog (fallback)." -Area 'M365Agents'
    return $result
}
