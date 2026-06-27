# makato-core — Contributor Guide

## Goal

Provide the shared developer utilities and suite infrastructure every makato plugin depends on — codebase navigation, documentation authoring, GitHub issue filing, and library reference lookup.

## What Belongs Here

- Contract schemas (defining artifact shapes for inter-toolkit data exchange)
- Setup/initialization skills
- Mandatory MCP server declarations
- Guide/help skills for suite users
- Diagnostics and validation utilities

## What Does NOT Belong Here

- Workflow logic (belongs in a toolkit)
- Domain-specific skills (belongs in a toolkit)
- Anything that serves ONE toolkit's goal rather than the suite

## Decision Test

"Does this serve one toolkit's goal, or the entire suite?"
- If suite → it belongs in core
- If one toolkit → it belongs in that toolkit

## Contracts

Contracts define artifact shapes. They are design-time definitions, not runtime imports.
- Placed in `contracts/` with clear schema definitions
- Consuming skills use local templates (not imports from core at runtime)
- Other plugins reference contracts for compatibility, not as dependencies

## Skill Authoring

- Self-contained: all references/templates inside the skill directory
- No `../` paths outside skill dir (except `../shared/` within this plugin)
- `shared/` directory allowed for cross-cutting references within this plugin
- Frontmatter required: name, description, version

## File Structure

```
makato-core/
├── .claude-plugin/plugin.json
├── contracts/          # Shared schemas
├── skills/             # Foundation skills
├── shared/             # Cross-skill references (optional)
├── CLAUDE.md
├── AGENTS.md
├── CHANGELOG.md
└── README.md
```

## Versioning

- No `version` in plugin.json (repo versioned via release-please + git tags)
- Skill versions: bumped in SKILL.md frontmatter per feature PR
- Agent versions: bumped in agent frontmatter per feature PR
- CHANGELOG.md: updated with each PR

## PR Checklist

- [ ] Serves the suite goal, not a single toolkit
- [ ] Contract changes are backwards-compatible (or MAJOR bump)
- [ ] Skills are self-contained
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-core): description`
