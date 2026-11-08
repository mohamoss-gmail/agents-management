<#
.SYNOPSIS
    Copies Copilot Studio agent assignments (makers and users) to a CSV, or writes them from a CSV.

.DESCRIPTION
    Export (default): one CSV row per agent, with its makers and users.
    Import: reads a CSV and shows the changes it would make. Add -Apply to make them.

    CSV columns: Environment, AgentName, Makers, Users, AgentId (optional).
    Lists are separated by semicolons. Users are UPNs, groups are names or object IDs,
    and Everyone means everyone in the organization.

    Import only adds access unless you use -Mirror, which also removes anyone who isn't listed.

.EXAMPLE
    .\Invoke-AgentAssignment.ps1 -AllEnvironments
.EXAMPLE
    .\Invoke-AgentAssignment.ps1 -Environments 'HR Prod'
.EXAMPLE
    .\Invoke-AgentAssignment.ps1 -Import .\assignments.csv
.EXAMPLE
    .\Invoke-AgentAssignment.ps1 -Import .\assignments.csv -Apply
.EXAMPLE
    .\Invoke-AgentAssignment.ps1 -Import .\assignments.csv -Mirror -Apply
.EXAMPLE
    .\Invoke-AgentAssignment.ps1 -Import .\assignments.csv -TargetEnvironment 'HR Test' -Apply
#>
[CmdletBinding(DefaultParameterSetName = 'Export')]
param(
    # Environment display names or IDs to export. Omit (with no file/config list) to be prompted.
    [Parameter(ParameterSetName = 'Export')][string[]]$Environments,
    # Text file with one environment name or ID per line.
    [Parameter(ParameterSetName = 'Export')][string]$EnvironmentFile,
    # Export every environment without prompting.
    [Parameter(ParameterSetName = 'Export')][switch]$AllEnvironments,

    # CSV of assignments to write.
    [Parameter(Mandatory, ParameterSetName = 'Import')][string]$Import,
    # Make the changes. Without this, the import only shows what it would do.
    [Parameter(ParameterSetName = 'Import')][switch]$Apply,
    # Also remove access for anyone not listed, so each agent matches the CSV exactly.
    [Parameter(ParameterSetName = 'Import')][switch]$Mirror,
    # Write every row to this environment instead of the one in the CSV. Agents are matched by name.
    [Parameter(ParameterSetName = 'Import')][string]$TargetEnvironment,
    # Don't assign the Environment Maker security role to people who need it.
    [Parameter(ParameterSetName = 'Import')][switch]$SkipSecurityRoles,
    # Don't ask for confirmation before applying.
    [Parameter(ParameterSetName = 'Import')][switch]$Force,

    [string]$OutputPath = (Join-Path $PSScriptRoot 'Output'),
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\Agent and App Usage\config.json'),
    [string]$TenantId
)

$ErrorActionPreference = 'Stop'
foreach ($f in 'Common', 'Auth', 'Environments', 'Identity', 'CopilotStudio') {
    . (Join-Path $PSScriptRoot "..\Agent and App Usage\src\$f.ps1")
}
foreach ($f in 'Read', 'Write') { . (Join-Path $PSScriptRoot "src\$f.ps1") }

$config = $null
if (Test-Path $ConfigPath) { $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json }
if (-not $TenantId) { $TenantId = Get-Prop $config 'TenantId' }

$rows = @()
if ($Import) { $rows = @(Read-AssignmentCsv -Path $Import -TargetEnvironment $TargetEnvironment) }

Connect-AgentCollector -TenantId $TenantId -GraphScopes @('User.Read.All', 'Directory.Read.All') -AzureResource $script:PowerPlatformResource

$runFolder = Join-Path $OutputPath ((Get-Date).ToString('yyyy-MM-dd_HHmm'))
New-Item -ItemType Directory -Path $runFolder -Force | Out-Null

# ------------------------------------------------------------------ export
if (-not $Import) {
    $filter = Resolve-EnvironmentFilter -Environments $Environments -EnvironmentFile $EnvironmentFile -AllEnvironments:$AllEnvironments -Config $config
    $envs = @(Get-TargetEnvironments -Filter $filter)
    $assignments = New-Object System.Collections.Generic.List[object]
    foreach ($env in $envs) {
        try { foreach ($r in (Get-EnvironmentAssignments -Environment $env)) { $assignments.Add($r) } }
        catch { Write-Log "Environment '$($env.DisplayName)' failed: $($_.Exception.Message)" -Level Error -Area 'Read' }
    }
    $csvPath = Join-Path $runFolder 'AgentAssignments.csv'
    $assignments | Sort-Object Environment, AgentName, AgentId | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Get-CollectionLog | Export-Csv -Path (Join-Path $runFolder 'AssignmentLog.csv') -NoTypeInformation -Encoding UTF8
    $errors = @(Get-CollectionLog | Where-Object { $_.Level -eq 'Error' })
    Write-Host ''
    if ($errors.Count -gt 0) { Write-Host "$($assignments.Count) agent(s) exported, with $($errors.Count) error(s). The CSV is incomplete; see AssignmentLog.csv." -ForegroundColor Yellow }
    else { Write-Host "Done. $($assignments.Count) agent(s) exported." -ForegroundColor Green }
    Write-Host "  CSV: $csvPath"
    return
}

# ------------------------------------------------------------------ import
$envNames = @($rows | ForEach-Object { $_.Environment } | Where-Object { $_ } | Sort-Object -Unique)
$envs = @(Get-TargetEnvironments -Filter $envNames)
$result = Get-ImportPlan -Rows $rows -Environments $envs -Mirror:$Mirror -SkipSecurityRoles:$SkipSecurityRoles
$actions = @($result.Actions)
$changes = @($actions | Where-Object { $_.Status -eq 'Planned' })
$removing = @($changes | Where-Object { $_.Action -in 'RemoveMaker', 'RemoveUser', 'RemoveGroup', 'SetReadOnly', 'SetPolicy', 'SetGroupList' })
$blocked = @($actions | Where-Object { $_.Status -eq 'Blocked' })

$changesPath = Join-Path $runFolder 'AssignmentChanges.csv'
$columns = 'Environment', 'AgentName', 'Action', 'Target', 'Status', 'Detail'
Write-Host ''
if ($actions.Count -gt 0) { $actions | Format-Table $columns -AutoSize -Wrap | Out-String -Width 200 | Write-Host }
Write-Host "$($changes.Count) change(s) planned, $($removing.Count) of them narrow or remove access. $($blocked.Count) blocked." -ForegroundColor Yellow

$applied = $false
if ($Apply -and $changes.Count -gt 0) {
    $proceed = $true
    if (-not $Force) {
        $answer = Read-Host "Apply $($changes.Count) change(s)? Type YES to continue"
        $proceed = $answer -ceq 'YES'
    }
    if ($proceed) {
        # This file can be imported with -Mirror to put the agents back as they were.
        $beforePath = Join-Path $runFolder 'BeforeChange.csv'
        $result.Before | Export-Csv -Path $beforePath -NoTypeInformation -Encoding UTF8
        Write-Host "Previous assignments saved to $beforePath"
        Invoke-ImportPlan -Actions $actions -Contexts $result.Contexts
        $applied = $true
    }
    else { Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow }
}

$actions | Select-Object $columns | Export-Csv -Path $changesPath -NoTypeInformation -Encoding UTF8
Get-CollectionLog | Export-Csv -Path (Join-Path $runFolder 'AssignmentLog.csv') -NoTypeInformation -Encoding UTF8

Write-Host ''
if ($applied) {
    $done = @($actions | Where-Object { $_.Status -eq 'Done' }).Count
    $failed = @($actions | Where-Object { $_.Status -in 'Failed', 'Skipped' }).Count
    Write-Host "Done. $done change(s) applied, $failed failed or skipped." -ForegroundColor Green
}
elseif (-not $Apply) { Write-Host 'Preview only. Nothing was changed. Add -Apply to make these changes.' -ForegroundColor Green }
Write-Host "  Details: $changesPath"
