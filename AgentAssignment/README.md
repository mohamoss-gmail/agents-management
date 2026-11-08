# Agent Assignment tool

Copies who is assigned to each **Copilot Studio** agent into a CSV, and writes assignments back from a CSV. Each row is one agent with its makers and users.

Use it to back up assignments, make bulk changes in Excel, or copy assignments to another environment.

> **Test it first.** Writing has only been tested against a simulated environment, not a live tenant. Before using it on production agents, try it on one agent in a developer environment and follow the check in [Before you rely on it](#before-you-rely-on-it).

## Requirements

Windows PowerShell 5.1 or PowerShell 7, with no modules to install. The tool uses the shared code in `..\Agent and App Usage\src`, so keep both folders side by side.

| Needed for | Role |
|---|---|
| Finding environments | Power Platform Administrator |
| Reading and writing assignments, assigning security roles | System Administrator in each environment |
| Looking up users and groups | Consent to the Graph scopes `User.Read.All` and `Directory.Read.All` |

Sign-in happens in your browser, the same way as the usage collection tool.

## Export assignments to a CSV

```powershell
# Prompt for environments (press Enter for all)
.\Invoke-AgentAssignment.ps1

# Every environment
.\Invoke-AgentAssignment.ps1 -AllEnvironments

# Specific environments, by display name or ID
.\Invoke-AgentAssignment.ps1 -Environments 'HR Prod', 'HR Test'
```

The file is saved as `Output\<date>\AgentAssignments.csv`. Exporting never changes anything.

## Write assignments from a CSV

```powershell
# Preview: shows what would change, and changes nothing
.\Invoke-AgentAssignment.ps1 -Import .\assignments.csv

# Make the changes (only adds access)
.\Invoke-AgentAssignment.ps1 -Import .\assignments.csv -Apply

# Make each agent match the CSV exactly (also removes access)
.\Invoke-AgentAssignment.ps1 -Import .\assignments.csv -Mirror -Apply

# Write everything to another environment, matching agents by name
.\Invoke-AgentAssignment.ps1 -Import .\assignments.csv -TargetEnvironment 'HR Test' -Apply
```

| Switch | What it does |
|---|---|
| `-Apply` | Makes the changes. You're asked to type `YES` first. Without it, the import is only a preview. |
| `-Mirror` | Also removes anyone who isn't in the CSV, and can restrict an agent that's open to everyone. A blank cell means nobody in that role. |
| `-TargetEnvironment` | Ignores the CSV's `Environment` and `AgentId` columns. |
| `-SkipSecurityRoles` | Doesn't assign security roles. People who aren't in the environment are blocked, and people without a role get a warning. |
| `-Force` | Skips the `YES` prompt. |

Every run saves `AssignmentChanges.csv`, which lists each change with its result. With `-Apply`, the tool also saves `BeforeChange.csv` first, so you can undo a run:

```powershell
.\Invoke-AgentAssignment.ps1 -Import .\Output\<date>\BeforeChange.csv -Mirror -Apply
```

## CSV format

```csv
Environment,AgentName,Makers,Users
HR Prod,HR Helper,ana@contoso.com;bob@contoso.com,HR Staff;sam@contoso.com
HR Prod,IT Desk,lee@contoso.com,Everyone
```

| Column | Required | Content |
|---|---|---|
| `Environment` | Yes, unless you use `-TargetEnvironment` | Environment display name or ID |
| `AgentName` | Yes | The agent's name |
| `Makers` | Makers, Users, or both | Individual users who can edit the agent. Groups aren't allowed here. |
| `Users` | Makers, Users, or both | Users and security groups who can chat, or `Everyone` |
| `AgentId` | No | Only needed when two agents in an environment have the same name. The export always includes it. |

- Separate entries with semicolons.
- List users by UPN, and groups by name or object ID. If two groups share a name, use the object ID.
- If you leave out the `Makers` or `Users` column entirely, that role isn't touched, even with `-Mirror`.
- Someone listed in both columns is treated as a maker, because makers can always chat.

## How assignments are stored

| In the CSV | In Dataverse | Written with |
|---|---|---|
| Maker | Bot owner, or a member of the agent's own team | `AddMembersTeam`, `RemoveMembersTeam` |
| User (person) | Read access on the `bot` row | `GrantAccess`, `RevokeAccess` |
| User (group), agent uses **Group membership** | `authorizedsecuritygroupids` on the agent (20 groups at most) | `PATCH` on the bot |
| User (group), any other agent | Read access for the group's Dataverse team, which is created if needed | `GrantAccess`, `RevokeAccess` |
| `Everyone` | `accesscontrolpolicy` set to Any | `PATCH` on the bot |

Makers are added to the agent's team because Copilot Studio shares the agent **and** its topics with that team. Sharing only the agent row wouldn't give access to the topics.

## Security roles

Copilot Studio needs people to have a suitable security role before an agent is shared with them. This tool does the same:

- A person with none of System Administrator, System Customizer, Environment Maker or Bot Author is given **Environment Maker**. It's listed as `AddRole` in the preview.
- A person who isn't in the environment yet is added by that same step.
- A custom role that includes the `ChatBotReaders` privilege isn't recognized, so that person also shows `AddRole`. Use `-SkipSecurityRoles` if you manage roles yourself.
- Security roles are never removed, including with `-Mirror`.
- **Groups aren't given a role.** Giving a group Environment Maker would make every member a maker in that environment. Members need a role from another source, such as a role on the group's Dataverse team.

## What's protected

- **Owners** are never removed.
- **Platform accounts** (application and non-interactive users) are left out of the CSV and never removed.
- **Names that can't be found:** with `-Mirror`, nothing is removed from that agent, so a typo can't take someone's access away.
- **Order:** access is added before anything is restricted or removed.
- **Access through other teams** is listed in the CSV but can't be removed by this tool. It's reported instead.

An agent with **no authentication** can't restrict who chats, so its users aren't changed.

## Before you rely on it

Microsoft documents each API this tool calls, but not exactly how the Copilot Studio **Share** screen uses them. Some mappings above are based on the docs and Dataverse behavior, and haven't been confirmed on a live agent. This check takes a few minutes:

1. In a developer environment, share a test agent from Copilot Studio with one co-author, one chat user and one security group.
2. Run an export and confirm all three appear in the right columns.
3. Remove them in Copilot Studio, import the same CSV with `-Apply`, then open the **Share** screen. All three should be back.
4. Sign in as each person and confirm the co-author can edit topics and the chat user can chat.

Check these in particular:

| Check | Why |
|---|---|
| A new agent that was never shared doesn't export as `Everyone` | `Everyone` comes from the agent's access policy |
| A group added by this tool can chat | Sharing through the group's team isn't documented for agents |
| A change to `Everyone` or to groups takes effect | Access policy changes might need the agent to be published. This tool never publishes, because that would also publish draft edits. |

## Known limits

- Changes go directly to Dataverse, so Copilot Studio's own share checks **don't run**. That includes Managed Environment sharing limits, the license check, and the block on agents with embedded maker credentials. Check your policies before bulk changes.
- No email invitations are sent.
- Sharing an agent doesn't share its flows or connections.
- Only Copilot Studio agents are covered, not M365 Copilot agents.
- If several teams have edit access to an agent and none is named after it, makers can't be added, and the row is blocked.
- An agent shared with a business unit's default team is logged but not listed, because that team includes everyone in the business unit.
