# makato-core — Contributor Guide

## Hard Constraints

- **Only suite-wide utilities belong here.** Skills serving a single toolkit go in that toolkit. If it solves a concern for only one plugin, it is in the wrong place.
- **Contracts are design-time definitions, not runtime imports.** Consuming skills use local templates; they must not import from core at runtime.
- **No `bypassPermissions` agents in this plugin.** Core utilities run at the default permission level.
- **`create-issue` must use canonical templates and the 10-dimension label taxonomy**, and must check for duplicates before filing.
- **`makato-guide` and `map-codebase-context` are read-only.** They must never write or modify files.
- **`skill-judge` is advisory only.** Its scores never block a PR — they inform the author and are not a merge gate.
- **Hooks defined here are shared infrastructure.** Breaking changes to `pre-push.md` or `post-implement.md` require a CHANGELOG entry and a migration note.
- **The post-push verify hook is advisory only.** Validation authority belongs to `build-sensors`, `build-verify`, and GitHub Actions.
- **Never hard-code repository URLs, project IDs, or GitHub token values** in skills; read them from `.claude/config.json` or environment variables.

## Goal

Provide the shared developer utilities and suite infrastructure every makato plugin depends on — codebase navigation, GitHub issue filing, and plugin discovery.

> **Documentation authoring** (library reference lookup, README crafting, markdown, prose editing) lives in the sibling **`makato-doc`** plugin — see `plugins/makato-doc/AGENTS.md`.

## What Belongs Here

- Contract schemas (defining artifact shapes for inter-toolkit data exchange)
- Setup/initialization skills
- Mandatory MCP server declarations
- Guide/help skills for suite users
- Diagnostics and validation utilities
- Hooks shared across consumer repos (post-push verify advisory, post-implement continuation)

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
├── hooks/
│   ├── pre-push.md            # Stop: advise when a push lacks current verify evidence
│   └── post-implement.md      # Stop: auto-continue to /build-simplify after implement session
├── skills/
│   ├── create-issue/                  # File a structured issue against the makato repo
│   ├── makato-guide/                  # Discover installed plugins and their skills
│   ├── map-codebase-context/          # Map dependencies / higher-level codebase view
│   └── skill-judge/                   # Review and score a SKILL.md for quality and pattern compliance
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
