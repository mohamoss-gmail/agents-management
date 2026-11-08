# Environment discovery and selection.

# Token audience of the Power Platform admin (BAP) API. The trailing slash is part of it.
$script:PowerPlatformResource = 'https://service.powerapps.com/'

function Get-TargetEnvironments {
    <#
      Returns environments that have Dataverse, optionally filtered by a list of
      display names or environment IDs. An empty filter means all environments.
    #>
    param([string[]]$Filter)

    Write-Log 'Discovering Power Platform environments...' -Area 'Environments'
    $uri = 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2020-10-01'
    $all = @(Invoke-PagedRequest -Uri $uri -HeaderFactory { @{ Authorization = "Bearer $(Get-ResourceToken $script:PowerPlatformResource)" } })

    $envs = foreach ($e in $all) {
        $props = Get-Prop $e 'properties'
        $meta = Get-Prop $props 'linkedEnvironmentMetadata'
        [pscustomobject]@{
            EnvironmentId   = $e.name
            DisplayName     = Get-Prop $props 'displayName' $e.name
            EnvironmentType = Get-Prop $props 'environmentSku'
            Region          = Get-Prop $e 'location'
            IsDefault       = [bool](Get-Prop $props 'isDefault' $false)
            DataverseUrl    = if ($meta) { ([string](Get-Prop $meta 'instanceUrl')).TrimEnd('/') } else { $null }
            OrgUniqueName   = if ($meta) { Get-Prop $meta 'uniqueName' } else { $null }
        }
    }

    if ($Filter -and $Filter.Count -gt 0) {
        $wanted = $Filter | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ }
        $matched = @($envs | Where-Object {
                $wanted -contains $_.DisplayName.ToLowerInvariant() -or $wanted -contains $_.EnvironmentId.ToLowerInvariant()
            })
        $found = @($matched | ForEach-Object { $_.DisplayName.ToLowerInvariant(); $_.EnvironmentId.ToLowerInvariant() })
        foreach ($w in $wanted) {
            if ($found -notcontains $w) { Write-Log "Environment '$w' was not found and is skipped." -Level Warn -Area 'Environments' }
        }
        $envs = $matched
    }

    $noDv = @($envs | Where-Object { -not $_.DataverseUrl })
    foreach ($e in $noDv) {
        Write-Log "Environment '$($e.DisplayName)' has no Dataverse and is skipped for Copilot Studio." -Level Warn -Area 'Environments'
    }
    $result = @($envs | Where-Object { $_.DataverseUrl })
    Write-Log "$($result.Count) environment(s) with Dataverse selected." -Area 'Environments'
    return $result
}

function Resolve-EnvironmentFilter {
    <#
      Decides which environments to scan, from (in order):
      -Environments parameter, -EnvironmentFile, config file, or an interactive prompt.
    #>
    param(
        [string[]]$Environments,
        [string]$EnvironmentFile,
        [switch]$AllEnvironments,
        $Config
    )
    if ($AllEnvironments) { return @() }
    if ($Environments -and $Environments.Count -gt 0) { return $Environments }
    if ($EnvironmentFile) {
        if (-not (Test-Path $EnvironmentFile)) { throw "Environment file not found: $EnvironmentFile" }
        return @(Get-Content $EnvironmentFile | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') })
    }
    $cfgEnvs = @(Get-Prop $Config 'Environments' @())
    if ($cfgEnvs.Count -gt 0) { return $cfgEnvs }

    Write-Host ''
    Write-Host 'Which environments should be scanned?' -ForegroundColor Yellow
    Write-Host '  Press Enter to scan ALL environments, or type environment names/IDs separated by commas.'
    $answer = Read-Host 'Environments'
    if ([string]::IsNullOrWhiteSpace($answer)) { return @() }
    return @($answer.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
