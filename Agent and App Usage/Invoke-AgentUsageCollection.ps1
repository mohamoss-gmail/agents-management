<#
.SYNOPSIS
    Collects an inventory and usage report for Copilot Studio and Microsoft 365 Copilot agents.

.DESCRIPTION
    For every agent: owner, publish date/publisher, tools, connectors, knowledge, triggers,
    who it is shared with (users, groups, org-wide) and how often it is used.

    Usage sources (each optional):
      - Dataverse conversation transcripts (Copilot Studio, default retention 30 days)
      - Purview unified audit log (CopilotInteraction + Copilot Studio publish events)
      - Application Insights (per agent, configured in config.json)
      - Agent 365 package catalog totals (M365 agents, last 30 days)

    Sign-in happens in your default browser. No PowerShell modules are required.

    Output: a timestamped folder with CSV files plus AgentUsageReport.html.

.EXAMPLE
    .\Invoke-AgentUsageCollection.ps1 -AllEnvironments
.EXAMPLE
    .\Invoke-AgentUsageCollection.ps1 -Environments 'Contoso (default)','HR Prod' -UsageDays 90
.EXAMPLE
    .\Invoke-AgentUsageCollection.ps1 -EnvironmentFile .\environments.txt -SkipPurview
#>
[CmdletBinding()]
param(
    # Environment display names or IDs to scan. Omit (with no file/config list) to be prompted.
    [string[]]$Environments,
    # Text file with one environment name or ID per line.
    [string]$EnvironmentFile,
    # Scan every environment without prompting.
    [switch]$AllEnvironments,
    [ValidateRange(1, 180)][int]$UsageDays = 30,
    [string]$OutputPath = (Join-Path $PSScriptRoot 'Output'),
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$TenantId,
    [switch]$SkipCopilotStudio,
    [switch]$SkipM365Agents,
    [switch]$SkipTranscripts,
    [switch]$SkipPurview,
    [switch]$SkipAppInsights,
    # Groups larger than this are counted but not enumerated member-by-member.
    [int]$MaxGroupMembers = 5000,
    # How long to wait for Purview audit searches to finish after the inventory is done.
    [int]$PurviewTimeoutMinutes = 90
)

$ErrorActionPreference = 'Stop'
foreach ($f in 'Common', 'Auth', 'Environments', 'Identity', 'CopilotStudio', 'M365Agents', 'Usage', 'Report') {
    . (Join-Path $PSScriptRoot "src\$f.ps1")
}

$config = $null
if (Test-Path $ConfigPath) { $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json }
if (-not $TenantId) { $TenantId = Get-Prop $config 'TenantId' }
$warnings = New-Object System.Collections.Generic.List[string]
$sourcesUsed = New-Object System.Collections.Generic.List[string]

# ------------------------------------------------------------------ browser sign-in
$aiTargets = @()
if (-not $SkipAppInsights) { $aiTargets = @(Get-Prop $config 'AppInsights' @()) }

$graphScopes = @('User.Read.All', 'GroupMember.Read.All', 'Directory.Read.All')
if (-not $SkipM365Agents) { $graphScopes += 'CopilotPackages.Read.All', 'AppCatalog.Read.All' }
if (-not $SkipPurview) { $graphScopes += 'AuditLogsQuery.Read.All' }
$azureResource = $null
if (-not $SkipCopilotStudio) { $azureResource = $script:PowerPlatformResource }
elseif ($aiTargets.Count -gt 0) { $azureResource = 'https://api.applicationinsights.io' }
Connect-AgentCollector -TenantId $TenantId -GraphScopes $graphScopes -AzureResource $azureResource

# Purview searches run server-side while the inventory below is collected.
$auditQueries = $null
if (-not $SkipPurview) {
    try { $auditQueries = Start-PurviewQueries -Days $UsageDays }
    catch {
        Write-Log "Purview audit search could not start: $($_.Exception.Message)" -Level Warn -Area 'Purview'
        $warnings.Add('Purview audit usage skipped: the audit search could not be started (check the Purview audit role and the AuditLogsQuery.Read.All consent).')
        $SkipPurview = $true
    }
}

# ------------------------------------------------------------------ inventory
$agents = New-Object System.Collections.Generic.List[object]
$tools = New-Object System.Collections.Generic.List[object]
$connectors = New-Object System.Collections.Generic.List[object]
$knowledge = New-Object System.Collections.Generic.List[object]
$sharing = New-Object System.Collections.Generic.List[object]
$events = New-Object System.Collections.Generic.List[object]
$envs = @()

if (-not $SkipCopilotStudio) {
    $filter = Resolve-EnvironmentFilter -Environments $Environments -EnvironmentFile $EnvironmentFile -AllEnvironments:$AllEnvironments -Config $config
    $envs = @(Get-TargetEnvironments -Filter $filter)
    $i = 0
    foreach ($env in $envs) {
        $i++
        Write-Progress -Activity 'Copilot Studio inventory' -Status "$($env.DisplayName) ($i of $($envs.Count))" -PercentComplete (($i / [math]::Max(1, $envs.Count)) * 100)
        try {
            $inv = Get-CopilotStudioInventory -Environment $env -MaxGroupMembers $MaxGroupMembers
            foreach ($x in $inv.Agents) { $agents.Add($x) }
            foreach ($x in $inv.Tools) { $tools.Add($x) }
            foreach ($x in $inv.Connectors) { $connectors.Add($x) }
            foreach ($x in $inv.Knowledge) { $knowledge.Add($x) }
            foreach ($x in $inv.Sharing) { $sharing.Add($x) }
            if (-not $SkipTranscripts -and $inv.Agents.Count -gt 0) {
                foreach ($e in (Get-TranscriptUsage -Environment $env -Days $UsageDays)) { $events.Add($e) }
            }
        }
        catch { Write-Log "Environment '$($env.DisplayName)' failed: $($_.Exception.Message)" -Level Error -Area 'CopilotStudio' }
    }
    Write-Progress -Activity 'Copilot Studio inventory' -Completed
    if (-not $SkipTranscripts) { $sourcesUsed.Add('Dataverse transcripts') }
}

if (-not $SkipM365Agents) {
    $m365 = Get-M365AgentInventory -MaxGroupMembers $MaxGroupMembers
    foreach ($x in $m365.Agents) { $agents.Add($x) }
    foreach ($x in $m365.Tools) { $tools.Add($x) }
    foreach ($x in $m365.Sharing) { $sharing.Add($x) }
    if ($m365.Available) { $sourcesUsed.Add('Agent 365 catalog') }
    else { $warnings.Add('Agent 365 package API was unavailable; M365 agents come from the Teams org app catalog without sharing or usage detail.') }
}

# ------------------------------------------------------------------ usage
$publishEvents = @()
if (-not $SkipPurview) {
    $purview = @(Get-PurviewUsage -QueryIds $auditQueries.Interactions -TimeoutMinutes $PurviewTimeoutMinutes)
    Resolve-Upns @($purview | ForEach-Object { $_.UserKey })
    foreach ($e in $purview) { $events.Add($e) }
    $publishEvents = @(Get-PurviewPublishEvents -QueryIds $auditQueries.Lifecycle -TimeoutMinutes $PurviewTimeoutMinutes)
    $sourcesUsed.Add('Purview audit')
}
if ($aiTargets.Count -gt 0) {
    foreach ($e in (Get-AppInsightsUsage -Targets $aiTargets -Days $UsageDays)) { $events.Add($e) }
    $sourcesUsed.Add('Application Insights')
}

$eventArray = $events.ToArray()
Resolve-UsageAgents -Events $eventArray -Agents $agents.ToArray()
$roll = Get-UsageRollups -Events $eventArray -WindowDays $UsageDays
$usageRan = ($sourcesUsed | Where-Object { $_ -ne 'Agent 365 catalog' }).Count -gt 0

# Agents that appear only in audit data (e.g. in environments that weren't scanned).
$known = @{}
foreach ($a in $agents) { $known[$a.AgentKey] = $true }
foreach ($k in $roll.PerAgent.Keys) {
    if (-not $known.ContainsKey($k)) {
        $agents.Add([pscustomobject]@{
                AgentKey = $k; Source = 'Audit only'; AgentId = $k.Substring($k.IndexOf(':') + 1)
                Name = if ($roll.PerAgent[$k].AgentName) { $roll.PerAgent[$k].AgentName } else { $k }
            })
    }
}

# Merge usage and audit lifecycle into the agent rows.
$publishByAgent = $publishEvents | Where-Object { $_.Operation -eq 'BotUpdateOperation-BotPublish' -and $_.AgentKey } | Group-Object AgentKey -AsHashTable -AsString
$usageFields = 'TranscriptSessions', 'TranscriptUsers', 'PurviewInteractions', 'PurviewUsers', 'AppInsightsSessions', 'AppInsightsUsers',
'TotalSessions', 'UniqueUsers', 'ActiveDays', 'AvgSessionsPerDay', 'UsageFrequency', 'FirstUse', 'LastUse', 'UsageSources'
foreach ($a in $agents) {
    $u = $roll.PerAgent[$a.AgentKey]
    foreach ($f in $usageFields) {
        $val = if ($u) { $u.$f } else { $null }
        $a | Add-Member -NotePropertyName $f -NotePropertyValue $val -Force
    }
    if (-not $u) {
        $catalogSessions = Get-Prop $a 'CatalogSessions30d'
        if ($null -ne $catalogSessions) {
            $a.TotalSessions = [int]$catalogSessions
            $a.UniqueUsers = Get-Prop $a 'CatalogActiveUsers30d'
            $a.LastUse = Get-Prop $a 'CatalogLastUsed'
            $a.UsageSources = 'Agent 365 catalog (30d totals)'
            $a.UsageFrequency = if ([int]$catalogSessions -eq 0) { 'Not used' } else { 'Unknown' }
        }
        else {
            $a.TotalSessions = 0
            $a.UniqueUsers = 0
            $a.UsageFrequency = if ($usageRan) { 'Not used' } else { 'Unknown' }
        }
    }
    if ($publishByAgent -and $publishByAgent.ContainsKey($a.AgentKey)) {
        $pubs = @($publishByAgent[$a.AgentKey] | Sort-Object Time)
        $a | Add-Member -NotePropertyName FirstPublishInAudit -NotePropertyValue $pubs[0].Time -Force
        $a | Add-Member -NotePropertyName PublishCountInAudit -NotePropertyValue $pubs.Count -Force
    }
}

# ------------------------------------------------------------------ export
$runFolder = Join-Path $OutputPath ((Get-Date).ToString('yyyy-MM-dd_HHmm'))
New-Item -ItemType Directory -Path $runFolder -Force | Out-Null

$data = @{
    Agents        = $agents.ToArray()
    Tools         = $tools.ToArray()
    Connectors    = $connectors.ToArray()
    Knowledge     = $knowledge.ToArray()
    Sharing       = $sharing.ToArray()
    Users         = $roll.Users
    Daily         = $roll.Daily
    PublishEvents = $publishEvents
    Environments  = $envs
    Log           = @(Get-CollectionLog)
}
$plain = Export-Dataset -Data $data -OutputPath $runFolder

foreach ($l in (Get-CollectionLog | Where-Object { $_.Level -ne 'Info' })) { $warnings.Add("[$($l.Area)] $($l.Message)") }
$meta = @{
    GeneratedOn      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    WindowDays       = $UsageDays
    EnvironmentCount = $envs.Count
    Sources          = @($sourcesUsed)
    Warnings         = @($warnings | Select-Object -Unique -First 25)
}
$report = Write-HtmlReport -Plain $plain -Meta $meta -OutputPath $runFolder -TemplatePath (Join-Path $PSScriptRoot 'templates\report.html')

Write-Host ''
Write-Host "Done. $($agents.Count) agent(s) collected." -ForegroundColor Green
Write-Host "  Output folder: $runFolder"
Write-Host "  HTML report:   $report"
