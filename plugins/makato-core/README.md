# makato-core

**Goal**: Provide the shared foundation that makes the suite work as a coherent system.

## What Belongs Here

- Contract schemas defining artifact plans for inter-toolkit data exchange
- Setup/initialization skills
- Mandatory MCP server declarations
- Guide/help skills for suite users
- Diagnostics and validation utilities

## What Does NOT Belong Here

- Workflow logic (belongs in a toolkit)
- Domain-specific skills (belongs in a toolkit)
- Anything serving one toolkit's goal rather than the suite

## Prerequisites / MCP Servers

This plugin declares MCP servers via `.mcp.json` at the plugin root. They are automatically configured when the plugin is installed:

| Server | Purpose | Environment |
|--------|---------|-------------|
| `jira` | Jira issue access (jira.tools.sap) | `JIRA_DOMAIN=jira.tools.sap` |
| `dcp-mcp-wiki` | Confluence wiki access | `WIKI_BASE_URL=https://wiki.one.int.sap`, `WIKI_SPACES=DCPL` |

See [MCP Server Convention](../../docs/contributing/MCP-SERVERS.md) for details on declaring MCP servers in plugins.

## Skills

| Skill | Description | Version |
|-------|-------------|---------|
| [makato-guide](skills/makato-guide/) | Discover plugins, list skills, find the right tool | 1.0.0 |
| [create-issue](skills/create-issue/) | File a structured issue against the makato repo with the correct template, title prefix, and labels | 1.0.0 |

## Contracts

Contract schemas will be added when the first toolkit needs to exchange data with another.

## Installation

```bash
claude --plugin-dir ./plugins/makato-core
```

## Version

0.1.0
