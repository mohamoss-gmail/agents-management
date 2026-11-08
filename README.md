# Agents Management

PowerShell tools for managing **Copilot Studio** agents in a Power Platform tenant. They need Windows PowerShell 5.1 or PowerShell 7 and no extra modules, and you sign in through your browser.

| Tool | What it does |
|---|---|
| [Agent and App Usage](Agent%20and%20App%20Usage/README.md) | Inventories Copilot Studio and Microsoft 365 Copilot agents: tools, connectors, knowledge, sharing and how often they're used. Produces CSV files and an HTML report. |
| [AgentAssignment](AgentAssignment/README.md) | Exports each agent's makers and users to a CSV, and writes assignments back from a CSV. |
| [AgentSolutionExport](AgentSolutionExport/README.md) | Packages every agent in an environment into its own unmanaged solution, with its dependencies, and downloads each zip. |

## Using them

Each folder has its own README with the roles it needs and how to run it.

- `AgentSolutionExport` is self-contained, so you can copy that folder by itself.
- `AgentAssignment` uses the shared code in `Agent and App Usage\src`, so keep those two folders side by side.

Run output goes to an `Output` folder inside each tool. It contains real tenant data, such as user names and environment IDs, so it's excluded from this repository.

## Status

`AgentAssignment` and `AgentSolutionExport` change things in your environment. Their write steps have only been tested against simulated Dataverse responses, so try them on a test agent first.
