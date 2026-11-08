# Builds one unmanaged solution per agent: finds what the agent uses, adds it, and exports the zip.

# The organization's default publisher has this fixed ID in every environment.
$script:DefaultPublisherId = 'd21aab71-79e7-11dd-8874-00188b01e34f'
$script:SolutionVersion = '1.0.0.0'
$script:FormattedSuffix = '@OData.Community.Display.V1.FormattedValue'

# Tables linked to agent components through many-to-many relationships (see the botcomponent table reference).
$script:LinkedTables = @(
    @{ Table = 'workflow'; Intersect = 'botcomponent_workflow'; Type = 'Flow' }
    @{ Table = 'connectionreference'; Intersect = 'botcomponent_connectionreference'; Type = 'Connection reference' }
    @{ Table = 'environmentvariabledefinition'; Intersect = 'botcomponent_environmentvariabledefinition'; Type = 'Environment variable' }
    @{ Table = 'msdyn_aimodel'; Intersect = 'botcomponent_msdyn_aimodel'; Type = 'AI prompt' }
    @{ Table = 'dvtablesearch'; Intersect = 'botcomponent_dvtablesearch'; Type = 'Dataverse search' }
    @{ Table = 'aipluginoperation'; Intersect = 'botcomponent_aipluginoperation'; Type = 'AI plugin operation' }
)

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

function New-ExportContext {
    # Per-environment caches, so tables and shared references are only looked up once.
    param([Parameter(Mandatory)]$Environment)
    [pscustomobject]@{
        Environment    = $Environment
        Org            = $Environment.DataverseUrl
        Api            = "$($Environment.DataverseUrl)/api/data/v9.2"
        Tables         = @{}
        Lookups        = @{}
        ComponentTypes = @{}
    }
}

function Get-EnvironmentBots {
    param([Parameter(Mandatory)]$Ctx)
    $org = $Ctx.Org
    Invoke-PagedRequest -Uri "$($Ctx.Api)/bots?`$select=botid,name,schemaname,ismanaged,_providerconnectionreferenceid_value&`$filter=statecode eq 0" -HeaderFactory { Get-DataverseHeaders $org }
}

function Get-TableInfo {
    # Entity set and key names for a table, or $null if the table isn't in this environment.
    param($Ctx, [string]$Table)
    if (-not $Ctx.Tables.ContainsKey($Table)) {
        $info = $null
        try { $info = Invoke-ApiRequest -Uri "$($Ctx.Api)/EntityDefinitions(LogicalName='$Table')?`$select=EntitySetName,PrimaryIdAttribute,PrimaryNameAttribute" -Headers (Get-DataverseHeaders $Ctx.Org) }
        catch { Write-Log "Table '$Table' isn't available here, so it's skipped: $($_.Exception.Message)" -Area 'Solutions' }
        $Ctx.Tables[$Table] = $info
    }
    return $Ctx.Tables[$Table]
}

function Get-TableColumns {
    param($Info)
    (@($Info.PrimaryIdAttribute, (Get-Prop $Info 'PrimaryNameAttribute')) | Where-Object { $_ }) -join ','
}

function New-DependencyItem {
    param([string]$Table, $Id, $Name, [string]$Type, [string]$FoundVia, [string]$Note)
    [pscustomobject]@{
        Table      = $Table
        Type       = $Type
        Name       = $Name
        Id         = if ($Id) { ([string]$Id).ToLowerInvariant() } else { $null }
        FoundVia   = $FoundVia
        InSolution = $false
        Note       = $Note
    }
}

function ConvertTo-DependencyItem {
    param($Row, $Info, [string]$Table, [string]$Type, [string]$FoundVia)
    $nameColumn = Get-Prop $Info 'PrimaryNameAttribute'
    $name = if ($nameColumn) { Get-Prop $Row $nameColumn } else { $null }
    New-DependencyItem -Table $Table -Id (Get-Prop $Row $Info.PrimaryIdAttribute) -Name $name -Type $Type -FoundVia $FoundVia
}

function Find-DependencyItem {
    # Looks up one row by an OData filter. Returns $null if it doesn't exist.
    param($Ctx, [string]$Table, [string]$Filter, [string]$Type, [string]$FoundVia)
    $info = Get-TableInfo $Ctx $Table
    if (-not $info) { return $null }
    $key = "$Table|$Filter"
    if (-not $Ctx.Lookups.ContainsKey($key)) {
        $org = $Ctx.Org
        $rows = @(Invoke-PagedRequest -Uri "$($Ctx.Api)/$($info.EntitySetName)?`$select=$(Get-TableColumns $info)&`$filter=$Filter&`$top=1" -HeaderFactory { Get-DataverseHeaders $org })
        $Ctx.Lookups[$key] = if ($rows.Count -gt 0) { $rows[0] } else { $null }
    }
    $row = $Ctx.Lookups[$key]
    if (-not $row) { return $null }
    ConvertTo-DependencyItem -Row $row -Info $info -Table $Table -Type $Type -FoundVia $FoundVia
}

function Get-OptionalRows {
    # For relationships that are useful but not essential: a failure is logged, not fatal.
    param([string]$Uri, [scriptblock]$HeaderFactory, [string]$What)
    try { Invoke-PagedRequest -Uri $Uri -HeaderFactory $HeaderFactory }
    catch { Write-Log "Could not read ${What}: $($_.Exception.Message)" -Level Warn -Area 'Solutions' }
}

function Get-LinkedItems {
    # Rows linked to the agent's components through the many-to-many relationships.
    param($Ctx, [string]$BotId, [string[]]$CollectionIds)
    $org = $Ctx.Org
    # FetchXML pages with its own attributes, so it can't be combined with odata.maxpagesize.
    $hf = {
        $h = Get-DataverseHeaders $org
        $h.Prefer = 'odata.include-annotations="OData.Community.Display.V1.FormattedValue"'
        $h
    }
    $conditions = "<condition attribute='parentbotid' operator='eq' value='$BotId'/>"
    foreach ($c in $CollectionIds) { $conditions += "<condition attribute='parentbotcomponentcollectionid' operator='eq' value='$c'/>" }

    foreach ($link in $script:LinkedTables) {
        $info = Get-TableInfo $Ctx $link.Table
        if (-not $info) { continue }
        $pk = $info.PrimaryIdAttribute
        $attributes = (@($pk, (Get-Prop $info 'PrimaryNameAttribute')) | Where-Object { $_ } | ForEach-Object { "<attribute name='$_'/>" }) -join ''
        $fetch = "<fetch distinct='true'><entity name='$($link.Table)'>$attributes" +
            "<link-entity name='$($link.Intersect)' from='$pk' to='$pk' link-type='inner' intersect='true'>" +
            "<link-entity name='botcomponent' from='botcomponentid' to='botcomponentid' link-type='inner'>" +
            "<filter type='or'>$conditions</filter></link-entity></link-entity></entity></fetch>"
        $rows = Get-OptionalRows -Uri "$($Ctx.Api)/$($info.EntitySetName)?fetchXml=$([uri]::EscapeDataString($fetch))" -HeaderFactory $hf -What "$($link.Type) links"
        foreach ($row in $rows) { ConvertTo-DependencyItem -Row $row -Info $info -Table $link.Table -Type $link.Type -FoundVia 'Linked to a component' }
    }
}

function Get-AgentDependencies {
    <#
      Everything one agent uses, from three sources: its components and their relationships,
      and references inside the topic YAML, which catches links the relationships miss.
      Connected agents come back in ChildBots so the caller can walk them too.
    #>
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Bot, [object[]]$AllBots)
    $botId = ([string]$Bot.botid).ToLowerInvariant()
    $org = $Ctx.Org
    $api = $Ctx.Api
    $hf = { Get-DataverseHeaders $org }
    $items = New-Object System.Collections.Generic.List[object]
    $select = 'botcomponentid,name,componenttype,data'

    # The agent's own components are essential, so this one is allowed to fail the agent.
    $components = New-Object System.Collections.Generic.List[object]
    foreach ($c in (Invoke-PagedRequest -Uri "$api/botcomponents?`$select=$select&`$filter=_parentbotid_value eq $botId" -HeaderFactory $hf)) { $components.Add($c) }
    foreach ($c in (Get-OptionalRows -Uri "$api/bots($botId)/bot_botcomponent?`$select=$select" -HeaderFactory $hf -What 'shared components')) { $components.Add($c) }

    $collectionIds = New-Object System.Collections.Generic.List[string]
    foreach ($col in (Get-OptionalRows -Uri "$api/bots($botId)/bot_botcomponentcollection?`$select=botcomponentcollectionid,name" -HeaderFactory $hf -What 'component collections')) {
        $collectionIds.Add($col.botcomponentcollectionid)
        $items.Add((New-DependencyItem -Table 'botcomponentcollection' -Id $col.botcomponentcollectionid -Name $col.name -Type 'Component collection' -FoundVia 'Linked to the agent'))
        foreach ($c in (Get-OptionalRows -Uri "$api/botcomponents?`$select=$select&`$filter=_parentbotcomponentcollectionid_value eq $($col.botcomponentcollectionid)" -HeaderFactory $hf -What 'collection components')) { $components.Add($c) }
    }
    foreach ($c in ($components | Sort-Object botcomponentid -Unique)) {
        $label = Get-Formatted $c 'componenttype'
        if (-not $label) { $label = 'Agent component' }
        $items.Add((New-DependencyItem -Table 'botcomponent' -Id $c.botcomponentid -Name $c.name -Type $label -FoundVia 'Part of the agent'))
    }

    foreach ($v in (Get-OptionalRows -Uri "$api/bots($botId)/bot_environmentvariabledefinition?`$select=environmentvariabledefinitionid,displayname" -HeaderFactory $hf -What 'environment variables')) {
        $items.Add((New-DependencyItem -Table 'environmentvariabledefinition' -Id $v.environmentvariabledefinitionid -Name $v.displayname -Type 'Environment variable' -FoundVia 'Linked to the agent'))
    }
    $provider = Get-Prop $Bot '_providerconnectionreferenceid_value'
    if ($provider) {
        $i = Find-DependencyItem $Ctx 'connectionreference' "connectionreferenceid eq $provider" 'Connection reference' 'Linked to the agent'
        if ($i) { $items.Add($i) }
    }
    foreach ($i in (Get-LinkedItems -Ctx $Ctx -BotId $botId -CollectionIds $collectionIds.ToArray())) { $items.Add($i) }

    # ---- References inside the topic YAML
    $yaml = (@($components | ForEach-Object { [string](Get-Prop $_ 'data' '') })) -join "`n"
    $addReference = {
        param([string]$Table, [string]$Filter, [string]$Type, [string]$Ref)
        try {
            $found = Find-DependencyItem $Ctx $Table $Filter $Type 'Used in a topic'
            if ($found) { $items.Add($found) }
            else { $items.Add((New-DependencyItem -Table $Table -Name $Ref -Type $Type -FoundVia 'Used in a topic' -Note 'Referenced by the agent but not found in this environment.')) }
        }
        catch { Write-Log "Could not look up $Type '$Ref': $($_.Exception.Message)" -Level Warn -Area 'Solutions' }
    }
    foreach ($id in (Get-RegexValues $yaml 'flowId:\s*([0-9a-fA-F-]{36})')) { & $addReference 'workflow' "workflowid eq $id" 'Flow' $id }
    foreach ($ref in (Get-RegexValues $yaml 'connectionReference:\s*(\S+)')) {
        & $addReference 'connectionreference' "connectionreferencelogicalname eq '$([uri]::EscapeDataString($ref.Replace("'", "''")))'" 'Connection reference' $ref
    }
    foreach ($id in (Get-RegexValues $yaml '(?i)aiModelId:\s*([0-9a-f-]{36})')) { & $addReference 'msdyn_aimodel' "msdyn_aimodelid eq $id" 'AI prompt' $id }
    # Env.x also matches ordinary text, so a name that doesn't exist is just ignored.
    foreach ($schema in (Get-RegexValues $yaml '\bEnv\.([A-Za-z][A-Za-z0-9_]*)')) {
        try {
            $found = Find-DependencyItem $Ctx 'environmentvariabledefinition' "schemaname eq '$schema'" 'Environment variable' 'Used in a topic'
            if ($found) { $items.Add($found) }
        }
        catch { Write-Log "Could not look up environment variable '$schema': $($_.Exception.Message)" -Level Warn -Area 'Solutions' }
    }

    $children = New-Object System.Collections.Generic.List[object]
    foreach ($schema in (Get-RegexValues $yaml '(?i)botSchemaName:\s*(\S+)')) {
        $child = @($AllBots | Where-Object { [string]$_.schemaname -eq $schema }) | Select-Object -First 1
        if ($child) { $children.Add($child) }
        else { $items.Add((New-DependencyItem -Table 'bot' -Name $schema -Type 'Connected agent' -FoundVia 'Used in a topic' -Note 'Referenced by the agent but not found in this environment.')) }
    }
    [pscustomobject]@{ Items = $items.ToArray(); ChildBots = $children.ToArray() }
}

function Get-PublisherId {
    param([Parameter(Mandatory)]$Ctx, [string]$UniqueName)
    $org = $Ctx.Org
    $filter = if ($UniqueName) { "uniquename eq '$($UniqueName.Replace("'", "''"))'" } else { "publisherid eq $script:DefaultPublisherId" }
    $rows = @(Invoke-PagedRequest -Uri "$($Ctx.Api)/publishers?`$select=publisherid,friendlyname&`$filter=$filter" -HeaderFactory { Get-DataverseHeaders $org })
    if ($rows.Count -eq 0) {
        if ($UniqueName) { throw "No publisher has the unique name '$UniqueName' in this environment." }
        throw "The environment's default publisher wasn't found. Use -PublisherUniqueName."
    }
    Write-Log "Using publisher '$($rows[0].friendlyname)'." -Area 'Solutions'
    return $rows[0].publisherid
}

function Get-SolutionUniqueName {
    # Letters, numbers and underscores only, at most 65 characters, unique per agent.
    param($Bot)
    $schema = ([string]$Bot.schemaname) -replace '[^A-Za-z0-9_]', ''
    if ($schema.Length -gt 50) { $schema = $schema.Substring(0, 50) }
    "Agent_${schema}_$(([string]$Bot.botid).Replace('-', '').Substring(0, 8))"
}

function Get-AgentSolution {
    # Returns the agent's solution, creating it on the first run.
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Bot, [Parameter(Mandatory)][string]$PublisherId)
    $org = $Ctx.Org
    $name = Get-SolutionUniqueName $Bot
    $uri = "$($Ctx.Api)/solutions?`$select=solutionid,uniquename,ismanaged&`$filter=uniquename eq '$name'"
    $rows = @(Invoke-PagedRequest -Uri $uri -HeaderFactory { Get-DataverseHeaders $org })
    if ($rows.Count -eq 0) {
        Invoke-ApiRequest -Method POST -Uri "$($Ctx.Api)/solutions" -Headers (Get-DataverseHeaders $org) -Body @{
            uniquename                = $name
            friendlyname              = "Agent - $($Bot.name)"
            version                   = $script:SolutionVersion
            description               = 'Created by Invoke-AgentSolutionExport.'
            'publisherid@odata.bind'  = "/publishers($PublisherId)"
        } | Out-Null
        $rows = @(Invoke-PagedRequest -Uri $uri -HeaderFactory { Get-DataverseHeaders $org })
    }
    if ($rows.Count -eq 0) { throw "Solution '$name' could not be created." }
    if ([bool](Get-Prop $rows[0] 'ismanaged' $false)) { throw "Solution '$name' already exists as a managed solution, so components can't be added to it." }
    return $rows[0]
}

function Invoke-SolutionOperation {
    # Dataverse runs one solution operation at a time and rejects others while one is in progress.
    param([Parameter(Mandatory)][scriptblock]$Operation)
    for ($attempt = 1; ; $attempt++) {
        try { return & $Operation }
        catch {
            if ($attempt -ge 6 -or "$($_.Exception.Message)" -notmatch 'running at this moment|CustomizationLock') { throw }
            Start-Sleep -Seconds 30
        }
    }
}

function Get-ComponentType {
    # Some component types are numbered per environment, so read it from the item's own solution component row.
    param($Ctx, $Item)
    if ($Ctx.ComponentTypes.ContainsKey($Item.Table)) { return $Ctx.ComponentTypes[$Item.Table] }
    $org = $Ctx.Org
    $rows = @(Invoke-PagedRequest -Uri "$($Ctx.Api)/solutioncomponents?`$select=componenttype&`$filter=objectid eq $($Item.Id)&`$top=1" -HeaderFactory { Get-DataverseHeaders $org })
    if ($rows.Count -eq 0) { throw "$($Item.Type) '$($Item.Name)' can't be added to a solution." }
    $Ctx.ComponentTypes[$Item.Table] = [int]$rows[0].componenttype
    return $Ctx.ComponentTypes[$Item.Table]
}

function Add-ComponentToSolution {
    # Adds one component and everything Dataverse knows it requires.
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$SolutionName, [Parameter(Mandatory)]$Item)
    $type = Get-ComponentType $Ctx $Item
    $org = $Ctx.Org
    $api = $Ctx.Api
    Invoke-SolutionOperation {
        Invoke-ApiRequest -Method POST -Uri "$api/AddSolutionComponent" -Headers (Get-DataverseHeaders $org) -Body @{
            ComponentId               = $Item.Id
            ComponentType             = $type
            SolutionUniqueName        = $SolutionName
            AddRequiredComponents     = $true
            DoNotIncludeSubcomponents = $false
        }
    } | Out-Null
}

function Get-SolutionComponents {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$SolutionId)
    $org = $Ctx.Org
    Invoke-PagedRequest -Uri "$($Ctx.Api)/solutioncomponents?`$select=objectid,componenttype&`$filter=_solutionid_value eq $SolutionId" -HeaderFactory { Get-DataverseHeaders $org }
}

function Get-MissingDependencies {
    # Components the solution requires but doesn't contain, usually system or managed components.
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$SolutionName)
    try {
        $resp = Invoke-ApiRequest -Uri "$($Ctx.Api)/RetrieveMissingDependencies(SolutionUniqueName=@s)?@s='$SolutionName'" -Headers (Get-DataverseHeaders $Ctx.Org)
        @(Get-Prop $resp 'value' @())
    }
    catch { Write-Log "Could not check missing dependencies for ${SolutionName}: $($_.Exception.Message)" -Level Warn -Area 'Solutions' }
}

function Save-SolutionZip {
    # Exports as unmanaged through the asynchronous job, so large agents don't time out, and saves the zip.
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$SolutionName, [Parameter(Mandatory)][string]$Path, [int]$TimeoutMinutes = 30)
    $org = $Ctx.Org
    $api = $Ctx.Api
    $job = Invoke-SolutionOperation {
        Invoke-ApiRequest -Method POST -Uri "$api/ExportSolutionAsync" -Headers (Get-DataverseHeaders $org) -Body @{ SolutionName = $SolutionName; Managed = $false }
    }
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        $op = Invoke-ApiRequest -Uri "$api/asyncoperations($($job.AsyncOperationId))?`$select=statecode,statuscode,message,friendlymessage" -Headers (Get-DataverseHeaders $org)
        if ([int]$op.statecode -eq 3) { break }
        if ((Get-Date) -gt $deadline) { throw "The export didn't finish within $TimeoutMinutes minutes." }
        Start-Sleep -Seconds 5
    }
    if ([int]$op.statuscode -ne 30) {
        $reason = Get-Prop $op 'friendlymessage' (Get-Prop $op 'message' "status $($op.statuscode)")
        throw "The export failed: $reason"
    }
    $file = Invoke-ApiRequest -Method POST -Uri "$api/DownloadSolutionExportData" -Headers (Get-DataverseHeaders $org) -Body @{ ExportJobId = $job.ExportJobId }
    [IO.File]::WriteAllBytes($Path, [Convert]::FromBase64String([string]$file.ExportSolutionFile))

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if (-not ($zip.Entries | Where-Object { $_.FullName -eq 'solution.xml' })) { throw 'The downloaded file is not a valid solution.' }
    }
    finally { $zip.Dispose() }
}

function Get-SafeFolderName {
    # A Windows-safe, unique folder name. Kept short so the full zip path stays within Windows limits.
    param([string]$Name, [hashtable]$Used, [string]$Suffix)
    $safe = ($Name -replace '[<>:"/\\|?*\x00-\x1f]', '_').Trim().TrimEnd('.')
    if ($safe.Length -gt 50) { $safe = $safe.Substring(0, 50).Trim() }
    if (-not $safe) { $safe = $Suffix }
    if ($Used.ContainsKey($safe)) { $safe = "$safe ($Suffix)" }
    $Used[$safe] = $true
    return $safe
}

function Export-AgentSolution {
    <#
      Creates or updates the agent's solution, adds everything it uses, and saves the zip
      and a Dependencies.csv into Folder. Throws if the agent can't be exported at all.
    #>
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)]$Bot,
        [object[]]$AllBots,
        [Parameter(Mandatory)][string]$PublisherId,
        [Parameter(Mandatory)][string]$Folder,
        [int]$TimeoutMinutes = 30
    )
    $solution = Get-AgentSolution -Ctx $Ctx -Bot $Bot -PublisherId $PublisherId
    $solutionName = $solution.uniquename

    # Walk the agent and any connected agents, which may connect back to each other.
    $root = New-DependencyItem -Table 'bot' -Id $Bot.botid -Name $Bot.name -Type 'Agent' -FoundVia 'This agent'
    $found = New-Object System.Collections.Generic.List[object]
    $found.Add($root)
    $visited = New-Object 'System.Collections.Generic.HashSet[string]'
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Bot)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $visited.Add(([string]$current.botid).ToLowerInvariant())) { continue }
        if ($current.botid -ne $Bot.botid) {
            $found.Add((New-DependencyItem -Table 'bot' -Id $current.botid -Name $current.name -Type 'Connected agent' -FoundVia 'Used in a topic'))
        }
        $deps = Get-AgentDependencies -Ctx $Ctx -Bot $current -AllBots $AllBots
        foreach ($i in $deps.Items) { $found.Add($i) }
        foreach ($child in $deps.ChildBots) { $queue.Enqueue($child) }
    }

    # The same component is often found through more than one route.
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $items = @($found | Where-Object { $seen.Add("$($_.Table)|$($_.Id)|$(if (-not $_.Id) { $_.Name })") })

    Add-ComponentToSolution -Ctx $Ctx -SolutionName $solutionName -Item $root

    # Only add what adding the agent didn't already bring in.
    $present = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($c in (Get-SolutionComponents -Ctx $Ctx -SolutionId $solution.solutionid)) { [void]$present.Add(([string]$c.objectid).ToLowerInvariant()) }
    $problems = 0
    foreach ($item in $items) {
        if (-not $item.Id) { $problems++; continue }
        if ($present.Contains($item.Id)) { continue }
        try { Add-ComponentToSolution -Ctx $Ctx -SolutionName $solutionName -Item $item }
        catch {
            $item.Note = $_.Exception.Message
            $problems++
            Write-Log "$($Bot.name): could not add $($item.Type) '$($item.Name)': $($_.Exception.Message)" -Level Warn -Area 'Solutions'
        }
    }

    $final = @(Get-SolutionComponents -Ctx $Ctx -SolutionId $solution.solutionid)
    $finalIds = @{}
    foreach ($c in $final) { $finalIds[([string]$c.objectid).ToLowerInvariant()] = $c }
    foreach ($item in $items) { $item.InSolution = [bool]($item.Id -and $finalIds.ContainsKey($item.Id)) }

    $known = @{}
    foreach ($item in $items) { if ($item.Id) { $known[$item.Id] = $true } }
    $report = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) { $report.Add($item) }
    foreach ($id in @($finalIds.Keys)) {
        if ($known.ContainsKey($id)) { continue }
        $c = $finalIds[$id]
        $type = Get-Formatted $c 'componenttype'
        if (-not $type) { $type = "Component type $($c.componenttype)" }
        $extra = New-DependencyItem -Table '' -Id $id -Type $type -FoundVia 'Required by another component'
        $extra.InSolution = $true
        $report.Add($extra)
    }
    $missing = @(Get-MissingDependencies -Ctx $Ctx -SolutionName $solutionName)
    foreach ($m in $missing) {
        $type = Get-Formatted $m 'requiredcomponenttype'
        if (-not $type) { $type = "Component type $(Get-Prop $m 'requiredcomponenttype')" }
        $report.Add((New-DependencyItem -Table '' -Id (Get-Prop $m 'requiredcomponentobjectid') -Type $type -FoundVia 'Required but not in the solution' -Note 'Must already exist in the environment you import into.'))
    }

    $report | Select-Object Type, Name, @{ Name = 'InSolution'; Expression = { if ($_.InSolution) { 'Yes' } else { 'No' } } }, FoundVia, Note, Id |
        Sort-Object @{ Expression = { $_.Type -ne 'Agent' } }, Type, Name |
        Export-Csv -Path (Join-Path $Folder 'Dependencies.csv') -NoTypeInformation -Encoding UTF8

    $zipPath = Join-Path $Folder "${solutionName}_$($script:SolutionVersion.Replace('.', '_')).zip"
    Save-SolutionZip -Ctx $Ctx -SolutionName $solutionName -Path $zipPath -TimeoutMinutes $TimeoutMinutes

    $count = { param($t) @($items | Where-Object { $_.Type -eq $t -and $_.InSolution }).Count }
    [pscustomobject]@{
        Status               = if ($problems -gt 0) { 'Exported with warnings' } else { 'Exported' }
        Solution             = $solutionName
        ComponentsInSolution = $final.Count
        Flows                = & $count 'Flow'
        ConnectionReferences = & $count 'Connection reference'
        EnvironmentVariables = & $count 'Environment variable'
        ConnectedAgents      = & $count 'Connected agent'
        NotAdded             = $problems
        MissingDependencies  = $missing.Count
        ZipFile              = $zipPath
    }
}
