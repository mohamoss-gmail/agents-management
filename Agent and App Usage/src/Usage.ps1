# Usage collection. Every source is normalised to "usage events":
#   AgentRef (raw id/name used for matching), Date, UserKey, SessionId, Source, Channel

function New-UsageEvent {
    param($AgentKey, $AgentRef, $AgentName, [datetime]$Time, $UserKey, $SessionId, $Source, $Channel)
    [pscustomobject]@{
        AgentKey  = $AgentKey
        AgentRef  = $AgentRef
        AgentName = $AgentName
        Date      = $Time.ToUniversalTime().Date
        Time      = $Time.ToUniversalTime()
        UserKey   = $UserKey
        SessionId = $SessionId
        Source    = $Source
        Channel   = $Channel
    }
}

# ---------------------------------------------------------------- Dataverse transcripts

function Get-TranscriptUsage {
    <#
      Reads conversationtranscript rows and extracts the users (role=1) in each session.
      Test-pane conversations (channel 'pva-studio') are excluded.
    #>
    param([Parameter(Mandatory)]$Environment, [int]$Days = 30)
    $org = $Environment.DataverseUrl
    $since = (Get-Date).ToUniversalTime().AddDays(-$Days).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $uri = "$org/api/data/v9.2/conversationtranscripts?`$select=conversationtranscriptid,_bot_conversationtranscriptid_value,conversationstarttime,content&`$filter=conversationstarttime ge $since"
    $hf = {
        $h = Get-DataverseHeaders $org
        $h.Prefer = 'odata.maxpagesize=500'
        $h
    }
    try { $rows = @(Invoke-PagedRequest -Uri $uri -HeaderFactory $hf) }
    catch {
        Write-Log "Cannot read transcripts in '$($Environment.DisplayName)': $($_.Exception.Message)" -Level Warn -Area 'Usage'
        return @()
    }
    Write-Log "$($rows.Count) transcript(s) in '$($Environment.DisplayName)' (last $Days days)." -Area 'Usage'

    $events = New-Object System.Collections.Generic.List[object]
    $testSessions = 0
    foreach ($r in $rows) {
        $botId = $r._bot_conversationtranscriptid_value
        $start = [datetime]$r.conversationstarttime
        $content = ConvertFrom-JsonSafe $r.content
        $acts = @(Get-Prop $content 'activities' @())
        $channel = ($acts | ForEach-Object { Get-Prop $_ 'channelId' } | Where-Object { $_ } | Select-Object -First 1)
        if ($channel -eq 'pva-studio') { $testSessions++; continue }

        $userIds = @($acts | Where-Object { [string](Get-Prop (Get-Prop $_ 'from') 'role') -in '1', 'user' } |
            ForEach-Object { $f = $_.from; $aad = Get-Prop $f 'aadObjectId'; if ($aad) { $aad } else { Get-Prop $f 'id' } } |
            Where-Object { $_ } | Select-Object -Unique)
        if ($userIds.Count -eq 0) { $userIds = @($null) }
        foreach ($u in $userIds) {
            $events.Add((New-UsageEvent -AgentKey "cs:$botId" -AgentRef $botId -Time $start -UserKey $u -SessionId $r.conversationtranscriptid -Source 'Transcripts' -Channel $channel))
        }
    }
    if ($testSessions -gt 0) { Write-Log "$testSessions test-pane session(s) excluded." -Area 'Usage' }

    # Resolve Entra object IDs to UPN keys.
    $guidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
    Resolve-DirectoryObjects @($events | Where-Object { $_.UserKey -match $guidPattern } | ForEach-Object { $_.UserKey })
    foreach ($e in $events) {
        if ($e.UserKey -match $guidPattern) { $e.UserKey = Get-UserKey -ObjectId $e.UserKey }
    }
    return $events.ToArray()
}

# ---------------------------------------------------------------- Purview audit log
# Uses the Microsoft Purview Audit Search API in Microsoft Graph. Searches run
# server-side: they are submitted right after sign-in and collected at the end,
# so they run while the inventory is being built.

$script:AuditQueryUri = 'https://graph.microsoft.com/v1.0/security/auditLog/queries'
$script:AuditQueryState = @{}   # query id -> final status
$script:LifecycleOperations = @('BotUpdateOperation-BotPublish', 'BotCreate', 'BotUpdateOperation-BotShare')

function Start-AuditQuery {
    param([datetime]$Start, [datetime]$End, [string[]]$Operations, [string]$Label)
    $body = @{
        displayName         = "Agent usage collection - $Label $($Start.ToString('yyyy-MM-dd')) to $($End.ToString('yyyy-MM-dd'))"
        filterStartDateTime = $Start.ToString('yyyy-MM-ddTHH:mm:ssZ')
        filterEndDateTime   = $End.ToString('yyyy-MM-ddTHH:mm:ssZ')
        operationFilters    = @($Operations)
    }
    $q = Invoke-GraphApi -Method POST -Uri $script:AuditQueryUri -Body $body
    return [string]$q.id
}

function Start-PurviewQueries {
    <#
      Submits the audit searches: CopilotInteraction in slices of SliceDays (each
      search is capped at about 1,000,000 records) plus one for agent lifecycle events.
    #>
    param([int]$Days = 30, [int]$SliceDays = 7)
    $end = (Get-Date).ToUniversalTime()
    $start = $end.AddDays(-$Days)
    $interactions = New-Object System.Collections.Generic.List[string]
    for ($s = $start; $s -lt $end; $s = $s.AddDays($SliceDays)) {
        $e = $s.AddDays($SliceDays)
        if ($e -gt $end) { $e = $end }
        $interactions.Add((Start-AuditQuery -Start $s -End $e -Operations @('CopilotInteraction') -Label 'Copilot interactions'))
    }
    $lifecycle = Start-AuditQuery -Start $start -End $end -Operations $script:LifecycleOperations -Label 'Copilot Studio lifecycle'
    Write-Log "Submitted $($interactions.Count + 1) Purview audit search(es); they run while agents are inventoried." -Area 'Purview'
    return @{ Interactions = $interactions.ToArray(); Lifecycle = @($lifecycle) }
}

function Wait-AuditQueries {
    # Polls until every query reaches a final state. Returns the IDs that succeeded.
    param([string[]]$QueryIds, [int]$TimeoutMinutes = 90)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $pending = New-Object System.Collections.Generic.List[string]
    foreach ($id in $QueryIds) { if (-not $script:AuditQueryState.ContainsKey($id)) { $pending.Add($id) } }
    $started = Get-Date
    while ($pending.Count -gt 0) {
        foreach ($id in @($pending)) {
            try { $q = Invoke-GraphApi -Uri "$script:AuditQueryUri/$id" }
            catch { Write-Log "Could not read audit search status: $($_.Exception.Message)" -Level Warn -Area 'Purview'; continue }
            $status = [string](Get-Prop $q 'status')
            if ($status -notin 'succeeded', 'failed', 'cancelled') { continue }
            $pending.Remove($id) | Out-Null
            $script:AuditQueryState[$id] = $status
            if ($status -ne 'succeeded') {
                Write-Log "Audit search '$($q.displayName)' ended with status '$status'." -Level Warn -Area 'Purview'
            }
            elseif (Get-Prop $q 'isRecordCountLimitExceeded' $false) {
                Write-Log "Audit search '$($q.displayName)' hit its record limit, so some interactions are missing. Use a shorter -UsageDays window." -Level Warn -Area 'Purview'
            }
        }
        if ($pending.Count -eq 0) { break }
        if ((Get-Date) -gt $deadline) {
            Write-Log "$($pending.Count) audit search(es) didn't finish within $TimeoutMinutes minutes and are skipped. Rerun with a larger -PurviewTimeoutMinutes." -Level Warn -Area 'Purview'
            foreach ($id in $pending) { $script:AuditQueryState[$id] = 'timeout' }
            break
        }
        $done = $QueryIds.Count - $pending.Count
        $mins = [int]((Get-Date) - $started).TotalMinutes
        Write-Progress -Activity 'Waiting for Purview audit searches' -Status "$done of $($QueryIds.Count) finished ($mins min)" -PercentComplete (($done / [math]::Max(1, $QueryIds.Count)) * 100)
        Start-Sleep -Seconds 20
    }
    Write-Progress -Activity 'Waiting for Purview audit searches' -Completed
    return @($QueryIds | Where-Object { $script:AuditQueryState[$_] -eq 'succeeded' })
}

function Get-AuditRecords {
    # Streams records of finished queries page by page, skipping duplicates across slices.
    param([string[]]$QueryIds)
    $seen = New-Object System.Collections.Generic.HashSet[string]
    foreach ($id in $QueryIds) {
        $next = "$script:AuditQueryUri/$id/records"
        while ($next) {
            $resp = Invoke-GraphApi -Uri $next
            foreach ($r in @(Get-Prop $resp 'value' @())) {
                if ($seen.Add([string]$r.id)) { $r }
            }
            $next = Get-Prop $resp '@odata.nextLink'
        }
    }
}

function Get-AuditData {
    # auditData holds the workload-specific record (the same fields as AuditData in the audit log export).
    param($Record)
    $a = Get-Prop $Record 'auditData'
    if ($a -is [string]) { $a = ConvertFrom-JsonSafe $a }
    return $a
}

function Get-PurviewUsage {
    <#
      CopilotInteraction records that involve an agent (AgentId/AgentName, or a
      Copilot Studio AppIdentity). Returns events with AgentRef set for matching.
    #>
    param([string[]]$QueryIds, [int]$TimeoutMinutes = 90)
    $ok = @(Wait-AuditQueries -QueryIds $QueryIds -TimeoutMinutes $TimeoutMinutes)
    $events = New-Object System.Collections.Generic.List[object]
    $scanned = 0
    try {
        Get-AuditRecords -QueryIds $ok | ForEach-Object {
            $scanned++
            if ($scanned % 5000 -eq 0) { Write-Progress -Activity 'Reading Purview CopilotInteraction records' -Status "$scanned read, $($events.Count) involve agents" }
            $r = $_
            $a = Get-AuditData $r
            if (-not $a) { return }
            $ced = Get-Prop $a 'CopilotEventData'
            $agentId = Get-Prop $a 'AgentId' (Get-Prop $ced 'AgentId')
            $agentName = Get-Prop $a 'AgentName' (Get-Prop $ced 'AgentName')
            $appIdentity = Get-Prop $a 'AppIdentity' (Get-Prop $ced 'AppIdentity')
            if (-not $agentId -and -not $agentName -and -not ([string]$appIdentity).StartsWith('Copilot.Studio.')) { return }
            $ref = if ($agentId) { $agentId } else { $appIdentity }
            $session = Get-Prop $ced 'ThreadId' (Get-Prop $a 'Id' $r.id)
            $time = [datetime](Get-Prop $r 'createdDateTime' (Get-Prop $a 'CreationTime'))
            $user = [string](Get-Prop $r 'userPrincipalName' (Get-Prop $a 'UserId' (Get-Prop $r 'userId')))
            $events.Add((New-UsageEvent -AgentKey $null -AgentRef $ref -AgentName $agentName -Time $time `
                        -UserKey $user.ToLowerInvariant() -SessionId $session -Source 'Purview' -Channel (Get-Prop $ced 'AppHost')))
        }
    }
    catch { Write-Log "Reading Purview interaction records failed: $($_.Exception.Message)" -Level Warn -Area 'Purview' }
    Write-Progress -Activity 'Reading Purview CopilotInteraction records' -Completed
    Write-Log "$($events.Count) agent interaction record(s) from Purview ($scanned Copilot interaction record(s) read)." -Area 'Purview'
    return $events.ToArray()
}

function Get-PurviewPublishEvents {
    # Copilot Studio create, publish and share events with the user and time.
    param([string[]]$QueryIds, [int]$TimeoutMinutes = 90)
    $ok = @(Wait-AuditQueries -QueryIds $QueryIds -TimeoutMinutes $TimeoutMinutes)
    try {
        $rows = Get-AuditRecords -QueryIds $ok | ForEach-Object {
            $r = $_
            $a = Get-AuditData $r
            $op = Get-Prop $r 'operation' (Get-Prop $a 'Operation')
            if (-not $a -or $op -notin $script:LifecycleOperations) { return }
            $botId = Get-Prop $a 'BotId'
            [pscustomobject]@{
                AgentKey      = if ($botId) { "cs:$(([string]$botId).ToLowerInvariant())" } else { $null }
                BotId         = $botId
                BotSchemaName = Get-Prop $a 'BotSchemaName'
                Operation     = $op
                Time          = ([datetime](Get-Prop $r 'createdDateTime' (Get-Prop $a 'CreationTime'))).ToUniversalTime()
                User          = Get-Prop $r 'userPrincipalName' (Get-Prop $a 'UserId')
                EnvironmentId = Get-Prop $a 'EnvironmentName'
            }
        }
    }
    catch {
        Write-Log "Reading Purview lifecycle records failed: $($_.Exception.Message)" -Level Warn -Area 'Purview'
        $rows = @()
    }
    Write-Log "$(@($rows).Count) Copilot Studio create/publish/share event(s) from Purview." -Area 'Purview'
    return @($rows)
}

# ---------------------------------------------------------------- Application Insights

$script:DefaultAppInsightsQuery = @'
customEvents
| where timestamp > ago({DAYS}d)
| where name == "BotMessageReceived"
| extend conv = tostring(customDimensions["conversationId"]),
         usr = coalesce(tostring(customDimensions["fromId"]), user_Id),
         design = tostring(customDimensions["designMode"]),
         channel = tostring(customDimensions["channelId"])
| where design != "True"
{FILTER}
| summarize ts = min(timestamp) by day = startofday(timestamp), conv, usr, channel
'@

function Get-AppInsightsUsage {
    <#
      Queries each configured App Insights resource. Config entries:
        { "AgentId": "<botid>", "AppId": "<App Insights application ID>", "Filter": "| where ..." }
    #>
    param([object[]]$Targets, [int]$Days = 30)
    $events = New-Object System.Collections.Generic.List[object]
    foreach ($t in $Targets) {
        $appId = Get-Prop $t 'AppId'
        $agentId = Get-Prop $t 'AgentId'
        if (-not $appId -or -not $agentId) { Write-Log 'App Insights entry needs AgentId and AppId; skipped.' -Level Warn -Area 'AppInsights'; continue }
        $query = Get-Prop $t 'Query' $script:DefaultAppInsightsQuery
        $query = $query.Replace('{DAYS}', [string]$Days).Replace('{FILTER}', [string](Get-Prop $t 'Filter' ''))
        try {
            $headers = @{ Authorization = "Bearer $(Get-ResourceToken 'https://api.applicationinsights.io')" }
            $resp = Invoke-ApiRequest -Method POST -Uri "https://api.applicationinsights.io/v1/apps/$appId/query" -Headers $headers -Body @{ query = $query }
        }
        catch {
            Write-Log "App Insights query failed for agent ${agentId}: $($_.Exception.Message)" -Level Warn -Area 'AppInsights'
            continue
        }
        $table = $resp.tables[0]
        $cols = @{}
        for ($i = 0; $i -lt $table.columns.Count; $i++) { $cols[$table.columns[$i].name] = $i }
        foreach ($row in $table.rows) {
            $events.Add((New-UsageEvent -AgentKey "cs:$($agentId.ToLowerInvariant())" -AgentRef $agentId -Time ([datetime]$row[$cols['ts']]) `
                        -UserKey $row[$cols['usr']] -SessionId $row[$cols['conv']] -Source 'AppInsights' -Channel $row[$cols['channel']]))
        }
        Write-Log "$($table.rows.Count) session-user row(s) from App Insights for agent $agentId." -Area 'AppInsights'
    }
    return $events.ToArray()
}

# ---------------------------------------------------------------- Matching and aggregation

function Resolve-UsageAgents {
    <#
      Fills AgentKey on events that only carry a raw reference (Purview), by
      matching any GUID in the reference against bot IDs, app IDs and package IDs.
    #>
    param([object[]]$Events, [object[]]$Agents)
    $index = @{}
    foreach ($a in $Agents) {
        foreach ($id in @($a.AgentId, $a.ApplicationId, $a.SchemaName)) {
            if ($id) { $index[([string]$id).ToLowerInvariant()] = $a.AgentKey }
        }
    }
    $nameIndex = @{}
    foreach ($a in $Agents) { if ($a.Name -and -not $nameIndex.ContainsKey($a.Name.ToLowerInvariant())) { $nameIndex[$a.Name.ToLowerInvariant()] = $a.AgentKey } }

    $unmatched = 0
    foreach ($e in $Events) {
        if ($e.AgentKey) { continue }
        $ref = ([string]$e.AgentRef).ToLowerInvariant()
        $key = $null
        if ($index.ContainsKey($ref)) { $key = $index[$ref] }
        if (-not $key) {
            foreach ($m in [regex]::Matches($ref, '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}')) {
                if ($index.ContainsKey($m.Value)) { $key = $index[$m.Value]; break }
            }
        }
        if (-not $key -and $e.AgentName -and $nameIndex.ContainsKey($e.AgentName.ToLowerInvariant())) { $key = $nameIndex[$e.AgentName.ToLowerInvariant()] }
        if (-not $key) { $key = "audit:$ref"; $unmatched++ }
        $e.AgentKey = $key
    }
    if ($unmatched -gt 0) { Write-Log "$unmatched audit record(s) could not be matched to an inventoried agent; they're reported as 'audit:' agents." -Level Warn -Area 'Usage' }
}

function Get-UsageRollups {
    <#
      Builds per-agent metrics, a daily table and a per-user table from events.
    #>
    param([object[]]$Events, [int]$WindowDays)
    $perAgent = @{}
    $daily = New-Object System.Collections.Generic.List[object]
    $users = New-Object System.Collections.Generic.List[object]

    foreach ($g in ($Events | Group-Object AgentKey)) {
        $ev = @($g.Group)
        $bySource = @{}
        foreach ($sg in ($ev | Group-Object Source)) {
            $bySource[$sg.Name] = [pscustomobject]@{
                Sessions = @($sg.Group | Select-Object -ExpandProperty SessionId -Unique).Count
                Users    = @($sg.Group | Where-Object { $_.UserKey } | Select-Object -ExpandProperty UserKey -Unique).Count
            }
            foreach ($dg in ($sg.Group | Group-Object { $_.Date.ToString('yyyy-MM-dd') })) {
                $daily.Add([pscustomobject]@{
                        AgentKey    = $g.Name
                        Date        = $dg.Name
                        Source      = $sg.Name
                        Sessions    = @($dg.Group | Select-Object -ExpandProperty SessionId -Unique).Count
                        UniqueUsers = @($dg.Group | Where-Object { $_.UserKey } | Select-Object -ExpandProperty UserKey -Unique).Count
                    })
            }
        }
        $activeDays = @($ev | ForEach-Object { $_.Date.ToString('yyyy-MM-dd') } | Select-Object -Unique).Count
        $sessions = ($bySource.Values | Measure-Object Sessions -Maximum).Maximum
        $times = @($ev | Select-Object -ExpandProperty Time | Sort-Object)
        $uniqueUsers = @($ev | Where-Object { $_.UserKey } | Select-Object -ExpandProperty UserKey -Unique)

        $perAgent[$g.Name] = [pscustomobject]@{
            AgentName           = ($ev | Where-Object { $_.AgentName } | Select-Object -First 1 -ExpandProperty AgentName)
            TranscriptSessions  = if ($bySource['Transcripts']) { $bySource['Transcripts'].Sessions } else { $null }
            TranscriptUsers     = if ($bySource['Transcripts']) { $bySource['Transcripts'].Users } else { $null }
            PurviewInteractions = @($ev | Where-Object { $_.Source -eq 'Purview' }).Count
            PurviewSessions     = if ($bySource['Purview']) { $bySource['Purview'].Sessions } else { $null }
            PurviewUsers        = if ($bySource['Purview']) { $bySource['Purview'].Users } else { $null }
            AppInsightsSessions = if ($bySource['AppInsights']) { $bySource['AppInsights'].Sessions } else { $null }
            AppInsightsUsers    = if ($bySource['AppInsights']) { $bySource['AppInsights'].Users } else { $null }
            TotalSessions       = [int]$sessions
            UniqueUsers         = $uniqueUsers.Count
            ActiveDays          = $activeDays
            FirstUse            = $times[0]
            LastUse             = $times[-1]
            AvgSessionsPerDay   = [math]::Round($sessions / [double][math]::Max(1, $WindowDays), 2)
            UsageFrequency      = Get-UsageFrequency -ActiveDays $activeDays -WindowDays $WindowDays
            UsageSources        = (($bySource.Keys | Sort-Object) -join ', ')
        }

        foreach ($ug in ($ev | Where-Object { $_.UserKey } | Group-Object UserKey)) {
            $disp = Get-UserDisplay $ug.Name
            $ut = @($ug.Group | Select-Object -ExpandProperty Time | Sort-Object)
            $users.Add([pscustomobject]@{
                    AgentKey          = $g.Name
                    UserKey           = $ug.Name
                    DisplayName       = $disp.DisplayName
                    UserPrincipalName = $disp.UserPrincipalName
                    Sessions          = @($ug.Group | Select-Object -ExpandProperty SessionId -Unique).Count
                    ActiveDays        = @($ug.Group | ForEach-Object { $_.Date.ToString('yyyy-MM-dd') } | Select-Object -Unique).Count
                    FirstSeen         = $ut[0]
                    LastSeen          = $ut[-1]
                    Channels          = (@($ug.Group | Where-Object { $_.Channel } | Select-Object -ExpandProperty Channel -Unique) -join ', ')
                    Sources           = (@($ug.Group | Select-Object -ExpandProperty Source -Unique) -join ', ')
                })
        }
    }
    return @{ PerAgent = $perAgent; Daily = $daily.ToArray(); Users = $users.ToArray() }
}
