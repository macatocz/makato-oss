# makato-core

**Goal**: Provide the shared foundation that makes the suite work as a coherent system.

## What Belongs Here

- Contract schemas defining artifact shapes for inter-toolkit data exchange
- Setup/initialization skills
- Mandatory MCP server declarations
- Guide/help skills for suite users
- Diagnostics and validation utilities

## What Does NOT Belong Here

- Workflow logic (belongs in a toolkit)
- Domain-specific skills (belongs in a toolkit)
- Anything serving one toolkit's goal rather than the suite

## Prerequisites / MCP Servers

makato-core does not declare any MCP servers. Skills use the `gh` CLI for GitHub operations.

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
