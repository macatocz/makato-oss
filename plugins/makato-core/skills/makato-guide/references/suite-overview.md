# makato Suite Overview

## What makato Is

makato is a curated suite of Claude Code plugins for AI-native software development. Each plugin (toolkit) owns a specific transformation — from feature discovery through development through verification — and works independently or chains with others through shared contracts on disk.

The design principle: end-to-end coverage is a property of the system, not a requirement on any single plugin. Each toolkit is a complete system with its own planning, execution, and verification.

## Architecture

### Plugin Types

- **makato-core** (foundation): Shared contracts, suite-level skills, MCP server declarations, guide/help utilities. Everything here serves the entire suite, not one toolkit.
- **makato-\<name\>** (toolkits): Goal-driven, independent plugins. Each has a single goal statement that gates what it admits. Toolkits never invoke each other at runtime.

### How Plugins Communicate

- Toolkits communicate via disk contracts (artifact schemas defined in makato-core)
- No skill-to-skill invocation across plugins
- Core defines artifact plans; toolkits produce and consume them
- Contracts are design-time definitions, not runtime imports

### Key Principles

- **Goal as Gatekeeper**: Every plugin has a single goal statement. Content must serve that goal.
- **Self-Contained Skills**: Each skill is a standalone directory with everything it needs.
- **No Experimental Tier**: Content is either ready (PR to dev) or stays on a fork.

## How to Install Plugins

Install from a local clone:

```bash
claude --plugin-dir ./plugins/makato-<name>
```

Multiple plugins can be installed simultaneously. Each plugin's `.mcp.json` (if present) will configure required MCP servers automatically.

## Contributing

- Use `makato-contribute`'s **scaffold-plugin** skill to create new plugins
- Use `makato-contribute`'s **makato-skill-creator** skill to add skills to existing plugins
- Run `./scripts/validate-all.sh` before pushing
