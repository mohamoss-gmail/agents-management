<#
.SYNOPSIS
    Packages every Copilot Studio agent in an environment into its own unmanaged solution.

.DESCRIPTION
    For each agent: finds what it uses (topics, knowledge, flows, connection references,
    environment variables, AI prompts, connected agents and anything Dataverse says they
    require), creates or updates a solution for that agent, and downloads the solution zip.

    Output: one folder per agent, each with its zip and a Dependencies.csv, plus
    ExportSummary.csv for the whole run.

    The solutions stay in the environment and are reused on the next run.

.EXAMPLE
    .\Invoke-AgentSolutionExport.ps1 -Environment 'HR Prod'
.EXAMPLE
    .\Invoke-AgentSolutionExport.ps1 -Environment 'HR Prod' -AgentName 'HR Helper','IT Desk'
.EXAMPLE
    .\Invoke-AgentSolutionExport.ps1 -Environment 'HR Prod' -PublisherUniqueName contoso
#>
[CmdletBinding()]
param(
    # Environment display name or ID.
    [Parameter(Mandatory)][string]$Environment,
    # Only export these agents. Omit to export every agent in the environment.
    [string[]]$AgentName,
    # Publisher for the new solutions. Omit to use the environment's default publisher.
    [string]$PublisherUniqueName,
    # How long to wait for each agent's export to finish.
    [ValidateRange(1, 240)][int]$ExportTimeoutMinutes = 30,
    [string]$OutputPath = (Join-Path $PSScriptRoot 'Output'),
    [string]$TenantId
)

$ErrorActionPreference = 'Stop'
foreach ($f in 'Common', 'Auth', 'Environments', 'Solutions') {
    . (Join-Path $PSScriptRoot "src\$f.ps1")
}

Connect-AgentCollector -TenantId $TenantId -AzureResource $script:PowerPlatformResource

$envs = @(Get-TargetEnvironments -Filter @($Environment))
if ($envs.Count -eq 0) { throw "Environment '$Environment' was not found, or it has no Dataverse." }
if ($envs.Count -gt 1) { throw "More than one environment is named '$Environment'. Use the environment ID." }
$env = $envs[0]

$ctx = New-ExportContext $env
$allBots = @(Get-EnvironmentBots $ctx)
$bots = $allBots
if ($AgentName) {
    $bots = @($allBots | Where-Object { $AgentName -contains $_.name })
    foreach ($n in $AgentName) {
        if (-not ($allBots | Where-Object { $_.name -eq $n })) { Write-Log "No active agent is named '$n'." -Level Warn -Area 'Solutions' }
    }
}
if ($bots.Count -eq 0) { throw "No agents to export in '$($env.DisplayName)'." }
Write-Log "$($bots.Count) agent(s) to export from '$($env.DisplayName)'." -Area 'Solutions'
$publisherId = Get-PublisherId -Ctx $ctx -UniqueName $PublisherUniqueName

$usedNames = @{}
$runName = "$(Get-SafeFolderName -Name $env.DisplayName -Used @{} -Suffix $env.EnvironmentId)_$((Get-Date).ToString('yyyy-MM-dd_HHmm'))"
$runFolder = (New-Item -ItemType Directory -Path (Join-Path $OutputPath $runName) -Force).FullName

$summary = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($bot in ($bots | Sort-Object name)) {
    $i++
    Write-Progress -Activity 'Exporting agents as solutions' -Status "$($bot.name) ($i of $($bots.Count))" -PercentComplete (($i / $bots.Count) * 100)
    Write-Log "Exporting '$($bot.name)'..." -Area 'Solutions'
    $row = [ordered]@{
        AgentName = $bot.name; AgentId = $bot.botid; IsManagedAgent = [bool](Get-Prop $bot 'ismanaged' $false); Status = 'Failed'; Solution = (Get-SolutionUniqueName $bot)
        ComponentsInSolution = $null; Flows = $null; ConnectionReferences = $null; EnvironmentVariables = $null; ConnectedAgents = $null
        NotAdded = $null; MissingDependencies = $null; ZipFile = $null; Error = $null
    }
    try {
        $suffix = ([string]$bot.botid).Substring(0, 8)
        $folder = (New-Item -ItemType Directory -Path (Join-Path $runFolder (Get-SafeFolderName -Name $bot.name -Used $usedNames -Suffix $suffix)) -Force).FullName
        $result = Export-AgentSolution -Ctx $ctx -Bot $bot -AllBots $allBots -PublisherId $publisherId -Folder $folder -TimeoutMinutes $ExportTimeoutMinutes
        foreach ($p in $result.PSObject.Properties) { $row[$p.Name] = $p.Value }
    }
    catch {
        $row.Error = $_.Exception.Message
        Write-Log "'$($bot.name)' failed: $($_.Exception.Message)" -Level Error -Area 'Solutions'
    }
    $summary.Add([pscustomobject]$row)
}
Write-Progress -Activity 'Exporting agents as solutions' -Completed

$summary | Export-Csv -Path (Join-Path $runFolder 'ExportSummary.csv') -NoTypeInformation -Encoding UTF8
Get-CollectionLog | Export-Csv -Path (Join-Path $runFolder 'ExportLog.csv') -NoTypeInformation -Encoding UTF8

$exported = @($summary | Where-Object { $_.Status -like 'Exported*' }).Count
$failed = @($summary | Where-Object { $_.Status -eq 'Failed' }).Count
$warned = @($summary | Where-Object { $_.Status -eq 'Exported with warnings' }).Count
Write-Host ''
$summary | Format-Table AgentName, Status, ComponentsInSolution, Flows, NotAdded, MissingDependencies -AutoSize | Out-String -Width 200 | Write-Host
$color = if ($failed -gt 0 -or $warned -gt 0) { 'Yellow' } else { 'Green' }
Write-Host "$exported of $($summary.Count) agent(s) exported, $warned with warnings, $failed failed." -ForegroundColor $color
Write-Host "  Output folder: $runFolder"
