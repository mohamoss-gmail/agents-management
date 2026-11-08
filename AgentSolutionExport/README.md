# Agent Solution Export tool

Packages every **Copilot Studio** agent in an environment into its own unmanaged solution, with everything the agent uses, and downloads each solution as a zip.

Use it to back up agents or to move them to another environment one at a time.

> **Not yet run on a live tenant.** It has only been tested against a simulated Dataverse. Try it on one agent first with `-AgentName`, then import that zip into a test environment.

## Requirements

Windows PowerShell 5.1 or PowerShell 7, with no modules to install. This folder is self-contained, so you can copy or share it by itself.

If you received it as a download or by email, Windows may block the scripts. Run this once from inside the folder:

```powershell
Get-ChildItem -Recurse -File | Unblock-File
```

| Needed for | Role |
|---|---|
| Finding the environment | Power Platform Administrator |
| Creating and exporting solutions | System Customizer or System Administrator in that environment |

You sign in once in your browser.

## Running it

```powershell
# Every agent in the environment, by display name or ID
.\Invoke-AgentSolutionExport.ps1 -Environment 'HR Prod'

# Only some agents (a good way to try it first)
.\Invoke-AgentSolutionExport.ps1 -Environment 'HR Prod' -AgentName 'HR Helper', 'IT Desk'

# Create the solutions under your own publisher
.\Invoke-AgentSolutionExport.ps1 -Environment 'HR Prod' -PublisherUniqueName contoso
```

Other options: `-ExportTimeoutMinutes` (how long to wait for each export; default 30), `-OutputPath`, `-TenantId`.

## Output

```
Output\HR Prod_2026-11-08_1430\
    ExportSummary.csv                 one row per agent: status, counts, zip path, error
    ExportLog.csv                     everything that happened during the run
    HR Helper\
        Agent_cr6b1_hrHelper_1a2b3c4d_1_0_0_0.zip
        Dependencies.csv              what the agent uses, and whether it's in the solution
    IT Desk\
        ...
```

| `ExportSummary.csv` status | Meaning |
|---|---|
| `Exported` | The zip is saved and everything found is in the solution. |
| `Exported with warnings` | The zip is saved, but something the agent references couldn't be added or found. Check `InSolution = No` rows in `Dependencies.csv`. |
| `Failed` | No zip for this agent. The `Error` column says why. Other agents still run. |

## What goes in each solution

The tool adds the agent with **required components** turned on, the same as **Add required objects** in Copilot Studio. It then looks for anything that step missed:

| Source | Finds |
|---|---|
| The agent's own components | Topics, knowledge, tools, triggers, settings, file attachments |
| Relationships on the agent and its components | Component collections, flows, connection references, environment variables, AI prompts, Dataverse search, AI plugin operations |
| References inside topic YAML | Flows, connection references, AI prompts, environment variables, connected agents |
| Dataverse required components | Whatever those items need, such as custom connectors and child flows |

**Connected agents** are included, along with what they use, so a parent agent's zip can be imported by itself.

`Dependencies.csv` lists how each item was found. Rows marked `Required but not in the solution` are usually system or managed components, which must already exist in the environment you import into.

## What the tool changes

- It creates one solution per agent, named `Agent_<schema name>_<id>` and displayed as `Agent - <agent name>`. **The solutions stay in the environment.**
- Later runs reuse the same solutions and add anything new. Components an agent no longer uses aren't removed from its solution.
- A solution only references components, so the agents, flows and topics themselves aren't changed.
- It uses the environment's default publisher unless you set `-PublisherUniqueName`. Microsoft recommends a custom publisher if you'll manage these solutions long-term.

## Importing a zip

- Import custom connectors first if the agent uses them. Microsoft requires them to be in place before the connection references.
- Connections aren't part of a solution. You map each connection reference during import.
- Set up [user authentication](https://learn.microsoft.com/microsoft-copilot-studio/configuration-end-user-authentication) again, then publish the imported agent before sharing it.
- Who the agent is shared with isn't part of the solution, so share it again after importing.

## Known limits

- Microsoft doesn't support exporting an agent that has a period (`.`) in a topic name. That agent will show as `Failed`.
- Some agent properties don't transfer, including topic comments, and the icon and channel details may be empty after import.
- Environment variable current values can travel with the solution. Review them before sharing a zip outside your team.
- The tool doesn't publish customizations first, so unpublished table or form changes aren't in the zip.
- Agents installed by a managed solution are exported too and flagged in the `IsManagedAgent` column. Check those zips before relying on them.
- Only Copilot Studio agents are covered, not M365 Copilot agents built in Agent Builder.
