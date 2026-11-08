# Agent Usage Collection Tool

PowerShell tool that inventories **Copilot Studio agents** and **Microsoft 365 Copilot agents** and reports on how they are built, shared, and used. It works like the Power Platform admin collection tools: you run it interactively as an admin and it writes CSV files plus an HTML report.

For every agent, it collects:

| Area | What's collected |
|---|---|
| Identity | Name, ID, environment, owner (name + UPN), created/modified dates, status |
| Publishing | Last published date, published by, first publish and publish count seen in Purview audit |
| Tools | Connector actions, agent flows, prompts, MCP servers, connected agents, HTTP requests, triggers, M365 agent capabilities/actions |
| Connectors | Every connector used by tools, topics, triggers and the agent flows they call, with maker/invoker auth mode |
| Knowledge | SharePoint, websites, files, Dataverse and other knowledge sources |
| Sharing | Users, security groups and teams the agent is shared with, including groups listed on the agent under the Group membership policy, editor vs viewer role, org-wide/public access, total users reached (groups expanded) |
| Usage | Sessions, unique users, active days, first/last use, daily trend, per-user activity, and a **usage frequency** label |

To copy or bulk-edit who is assigned to each agent, see the [Agent Assignment tool](../AgentAssignment/README.md). To package each agent into its own solution, see the [Agent Solution Export tool](../AgentSolutionExport/README.md). The Agent Assignment tool uses the shared code in this folder's `src`, so keep those two folders side by side. The Agent Solution Export tool is self-contained, with its own copies of `Common.ps1`, `Auth.ps1` and `Environments.ps1`, so a fix to those files needs copying there too.

## Requirements

Windows PowerShell 5.1 or PowerShell 7. **No modules to install.** The tool calls the Microsoft APIs directly.

**Roles for the account that runs it**

| Needed for | Role |
|---|---|
| Environment discovery | Power Platform Administrator |
| Reading agents, sharing and transcripts | System Administrator in each scanned Dataverse environment (Power Platform admins can add themselves) |
| Names, UPNs, group expansion, M365 agents, Purview search | Consent to the Graph scopes `User.Read.All`, `GroupMember.Read.All`, `Directory.Read.All`, `CopilotPackages.Read.All`, `AppCatalog.Read.All` and `AuditLogsQuery.Read.All` (a Global/Privileged Role admin grants consent the first time) |
| Purview usage and publish events | Audit Reader or View-Only Audit Logs, with auditing turned on for the tenant |
| Application Insights (optional) | Reader on each Application Insights resource |

## Sign-in

You sign in through your default browser:

1. When you start the tool, your browser opens the Microsoft sign-in page. Pick your admin account and complete MFA as usual. On the first run, Entra ID asks you to consent to the Graph scopes above. Tick **Consent on behalf of your organization** if you're an admin.
2. If Copilot Studio or App Insights is in scope, a second tab opens and finishes by itself through single sign-on. This tab authorizes Power Platform, Dataverse and App Insights.
3. Both tabs end on "Signed in. You can close this tab." Collection then continues in PowerShell.

How it works: the tool runs a standard OAuth authorization code flow with PKCE. The browser redirects back to a temporary listener on `http://localhost:<random port>`, which only exists during sign-in. The sign-in uses Microsoft's own public client apps, so you don't register anything:

- **Microsoft Graph Command Line Tools** for Graph.
- **Microsoft Azure PowerShell** for Power Platform, Dataverse and App Insights.

Tokens stay in memory and refresh silently for long runs. Nothing is written to disk. If the browser doesn't open, the URL is printed in the console; paste it into a browser **on the same computer**. Use `-TenantId` (or `TenantId` in `config.json`) to sign in to a specific tenant, for example as a guest admin.

**Licensing note:** the M365 agent package API (sharing, active users and sessions per agent) requires a **Microsoft Agent 365** license. Without one, the tool falls back to the Teams org app catalog, which lists M365 agents but has no sharing or usage detail.

## Running it

```powershell
# Prompt for environments (press Enter for all)
.\Invoke-AgentUsageCollection.ps1

# Every environment, 90 days of usage
.\Invoke-AgentUsageCollection.ps1 -AllEnvironments -UsageDays 90

# Specific environments by display name or ID
.\Invoke-AgentUsageCollection.ps1 -Environments 'Contoso (default)', 'HR Prod'

# Environment list from a file (one per line, # for comments)
.\Invoke-AgentUsageCollection.ps1 -EnvironmentFile .\environments.txt
```

The tool chooses which environments to scan in this order: `-AllEnvironments`, then `-Environments`, then `-EnvironmentFile`, then the `Environments` list in `config.json`. If none of these is set, it asks you interactively.

Useful switches: `-SkipCopilotStudio`, `-SkipM365Agents`, `-SkipTranscripts`, `-SkipPurview`, `-SkipAppInsights`, `-TenantId`, `-MaxGroupMembers` (groups larger than this are counted rather than enumerated; default 5000), `-PurviewTimeoutMinutes` (how long to wait for audit searches after the inventory finishes; default 90).

### Optional config.json

Copy `config.sample.json` to `config.json` to set a default tenant, an environment list, and Application Insights resources per agent:

```json
{
  "TenantId": "contoso.onmicrosoft.com",
  "Environments": ["Contoso (default)", "HR Prod"],
  "AppInsights": [
    { "AgentId": "<botid>", "AppId": "<App Insights Application ID>", "Filter": "" }
  ]
}
```

`Filter` is an optional KQL line such as `| where cloud_RoleName == "HR Agent"`, for App Insights resources that several agents share. You can also replace the whole query with a `Query` value; it must return the columns `ts`, `conv`, `usr` and `channel`.

## Output

Each run writes a timestamped folder under `Output\`:

| File | Content |
|---|---|
| `AgentUsageReport.html` | Self-contained report: KPIs, top agents, frequency mix, daily trend, searchable agent table, and a detail panel per agent |
| `Agents.csv` | One row per agent with all inventory, sharing and usage metrics |
| `AgentTools.csv` | Tools, topic actions, triggers and M365 capabilities |
| `AgentConnectors.csv` | Connectors per agent, what uses them, and the auth mode |
| `AgentKnowledge.csv` | Knowledge sources |
| `AgentSharing.csv` | Every principal with access, its role, and group member counts |
| `AgentUsers.csv` | Per agent per user: sessions, active days, first/last seen, channels |
| `AgentUsageDaily.csv` | Per agent per day per source: sessions and unique users |
| `AgentLifecycleEvents.csv` | Create, publish and share events from Purview |
| `Environments.csv`, `CollectionLog.csv` | The environments scanned, plus warnings and errors from the run |

All tables join on `AgentKey` (`cs:<botid>`, `m365:<packageId>` or `audit:<agentId>`), so they load straight into Power BI.

`samples\SampleReport.html` shows the report layout using mock data.

## How usage is measured

| Source | Covers | History |
|---|---|---|
| Dataverse `conversationtranscript` | Copilot Studio agents (all channels; test-pane chats excluded) | 30 days by default (configurable per environment) |
| Purview `CopilotInteraction` audit (Graph Audit Search API) | Agents used in M365 Copilot/Teams, including Copilot Studio agents published there | Up to 180 days (Audit Standard) |
| Application Insights | Copilot Studio agents connected to App Insights | Based on your retention |
| Agent 365 package catalog | M365 agents: 30-day active users and sessions | Last 30 days only (totals, no daily breakdown) |

- **Sessions** come from the single source with the highest count for that agent. Sources are never added together, so the same conversation isn't counted twice.
- **Unique users** are merged across sources by UPN.
- **Usage frequency** is based on the share of days in the window on which the agent was used:

| Frequency | Agent was used on |
|---|---|
| Daily | at least 50% of days |
| Weekly | at least 1 day per week |
| Monthly | at least 1 day per month |
| Occasional | fewer days than that |
| Not used | no days |
| Unknown | no usage source was available for the agent |

- Audit records that don't match any inventoried agent (for example, from an environment you didn't scan) still appear in the report as `Audit only` agents.

## Known limits

- `publishedon` on the agent is the **last** publish date. The first publish date is only available if it falls inside the Purview audit window.
- Tools and connectors are detected by parsing agent component YAML, using the same rules as Microsoft's Copilot Agent Kit. New tool types appear with their raw `ActionKind` until a label is added in `src\CopilotStudio.ps1`.
- Purview searches run in Microsoft's audit service right after sign-in, alongside the Dataverse scan. They usually take several minutes and can take longer in large tenants. The tool waits up to `-PurviewTimeoutMinutes` after the inventory finishes.
- Copilot interactions are searched in 7-day slices. Each slice is capped at about 1,000,000 records by the service, and the tool warns you if a slice hits the cap. Searches appear in the Purview portal's audit search history as "Agent usage collection - ...". Each run uses one search per slice plus one, which counts toward the tenant's daily limit (at least 200 a day).
- For agents shared with everyone, the report records the org-wide share but doesn't count every user in the tenant toward `SharedUserCount`.
