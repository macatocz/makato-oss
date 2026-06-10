# README.md Template

Generate the following, filling all sections from interview data:

```markdown
# <plugin-name>

**Goal**: <goal-statement>

**How**: <how-sentence from interview>

**Why**: <why-sentence from interview>

## What Belongs Here

<2-5 bullet points from interview>

## What Does NOT Belong Here

<2-5 bullet points from interview>

## Skills

| Skill | Description | Version |
|-------|-------------|---------|

None yet — add skills using `makato-skill-creator`.

## Prerequisites

(Only include this section if .mcp.json exists)

### MCP Servers

This plugin declares the following MCP servers:

| Server | Purpose |
|--------|---------|
| `<server-name>` | <purpose> |

## Installation

\```bash
claude --plugin-dir ./plugins/<plugin-name>
\```

## Version

0.1.0
```

Required sections:
- Goal (bold, with How and Why)
- What Belongs Here
- What Does NOT Belong Here
- Skills (table, empty for new plugins)
- Prerequisites (only if MCP servers declared)
- Installation
- Version
