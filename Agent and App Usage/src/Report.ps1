# CSV export and the self-contained HTML report.

$script:AgentColumns = @(
    'AgentKey', 'Source', 'Name', 'AgentId', 'EnvironmentName', 'EnvironmentType', 'Owner', 'OwnerUPN', 'CreatedOn',
    'IsPublished', 'LastPublishedOn', 'PublishedBy', 'FirstPublishInAudit', 'PublishCountInAudit', 'Status',
    'Audience', 'SharedWithEveryone', 'SharedUserCount', 'SharedGroupCount', 'EditorCount', 'AuthenticationMode', 'AccessPolicy',
    'Orchestration', 'IsAutonomous', 'ToolCount', 'TriggerCount', 'ConnectorCount', 'KnowledgeCount', 'UsesMCP', 'Connectors',
    'TotalSessions', 'UniqueUsers', 'ActiveDays', 'AvgSessionsPerDay', 'UsageFrequency', 'FirstUse', 'LastUse',
    'TranscriptSessions', 'TranscriptUsers', 'PurviewInteractions', 'PurviewUsers', 'AppInsightsSessions', 'AppInsightsUsers',
    'CatalogActiveUsers30d', 'CatalogSessions30d', 'CatalogLastUsed', 'CatalogInstalledCount', 'UsageSources',
    'ApplicationId', 'SchemaName', 'EnvironmentId', 'ModifiedOn', 'CreatedBy', 'IsManaged', 'UsesModelKnowledge', 'Description', 'Instructions'
)

function ConvertTo-PlainRow {
    # Projects to a fixed column set and turns dates into ISO strings so CSV and JSON agree.
    param($Row, [string[]]$Columns)
    $o = [ordered]@{}
    foreach ($c in $Columns) {
        $v = Get-Prop $Row $c
        if ($v -is [datetime]) { $v = $v.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        elseif ($v -is [datetimeoffset]) { $v = $v.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') }
        $o[$c] = $v
    }
    [pscustomobject]$o
}

function Get-Columns {
    param([object[]]$Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return @() }
    $cols = New-Object System.Collections.Generic.List[string]
    foreach ($r in $Rows) { foreach ($p in $r.PSObject.Properties.Name) { if (-not $cols.Contains($p)) { $cols.Add($p) } } }
    return $cols.ToArray()
}

function Export-Dataset {
    param([hashtable]$Data, [string]$OutputPath)
    $tables = [ordered]@{
        'Agents'          = @{ Rows = $Data.Agents; Columns = $script:AgentColumns }
        'AgentTools'      = @{ Rows = $Data.Tools }
        'AgentConnectors' = @{ Rows = $Data.Connectors }
        'AgentKnowledge'  = @{ Rows = $Data.Knowledge }
        'AgentSharing'    = @{ Rows = $Data.Sharing }
        'AgentUsers'      = @{ Rows = $Data.Users }
        'AgentUsageDaily' = @{ Rows = $Data.Daily }
        'AgentLifecycleEvents' = @{ Rows = $Data.PublishEvents }
        'Environments'    = @{ Rows = $Data.Environments }
        'CollectionLog'   = @{ Rows = $Data.Log }
    }
    $plain = @{}
    foreach ($name in $tables.Keys) {
        $rows = @($tables[$name].Rows | Where-Object { $_ })
        $cols = if ($tables[$name].Columns) { $tables[$name].Columns } else { Get-Columns $rows }
        $plainRows = @($rows | ForEach-Object { ConvertTo-PlainRow $_ $cols })
        $plain[$name] = $plainRows
        $file = Join-Path $OutputPath "$name.csv"
        if ($plainRows.Count -gt 0) { $plainRows | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8 }
        elseif ($cols.Count -gt 0) { ($cols -join ',') | Set-Content -Path $file -Encoding UTF8 }
        else { '' | Set-Content -Path $file -Encoding UTF8 }
    }
    return $plain
}

function Write-HtmlReport {
    param([hashtable]$Plain, [hashtable]$Meta, [string]$OutputPath, [string]$TemplatePath)
    $payload = @{
        meta       = $Meta
        agents     = @($Plain['Agents'])
        tools      = @($Plain['AgentTools'])
        connectors = @($Plain['AgentConnectors'])
        knowledge  = @($Plain['AgentKnowledge'])
        sharing    = @($Plain['AgentSharing'])
        users      = @($Plain['AgentUsers'])
        daily      = @($Plain['AgentUsageDaily'])
        lifecycle  = @($Plain['AgentLifecycleEvents'])
    }
    $json = ConvertTo-Json -InputObject $payload -Depth 6 -Compress
    # Keep embedded JSON from closing the <script> element.
    $json = $json.Replace('</', '<\/')
    $html = (Get-Content -Path $TemplatePath -Raw -Encoding UTF8).Replace('/*__DATA__*/null', $json)
    $file = Join-Path $OutputPath 'AgentUsageReport.html'
    [System.IO.File]::WriteAllText($file, $html, (New-Object System.Text.UTF8Encoding($false)))
    return $file
}
