# makato-database — Contributor Guide

## Goal

Provide Postgres-focused skills for performance optimization, query writing, schema design, and database administration — with scope to expand to additional database technologies.

**How:** It uses the best practices from the Postgres ecosystem today, with room for sibling skills (`manage-mysql`, `manage-sqlite`, …) to be added per the plugin's "What Belongs Here" inclusions.

**Why:** Users will have developed and managed database-related technologies and
languages to the best standards.

## What Belongs Here

- Skills that design relational schemas following normalization rules
- Skills that generate SQL DDL from a spec
- Skills that analyze slow queries and recommend indexes
- Skills that analyze performance of SQL queries
- Skills that write SQL queries
- Skills that do database administration

## What Does NOT Belong Here

- Application-layer ORM code
- Data migration tooling

## Decision Test

"Does this skill help the user design, write, optimize, or administer database
technologies and SQL to production standards?"

- Yes → it belongs here
- No → it belongs elsewhere

## Skill Authoring

- Self-contained: all references/templates inside the skill directory
- No `../` paths in skill files. To share content across skills, add a `shared/`
  symlink at the skill root pointing to the plugin's `shared/` directory.
- References loaded at point of use, not front-loaded
- Frontmatter required: name, description, version

## File Structure

```text
makato-database/
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   └── manage-postgres/   # Postgres performance & best practices
├── shared/                # Cross-skill references (TBD)
├── AGENTS.md
├── CHANGELOG.md
├── CLAUDE.md
└── README.md
```

> `.mcp.json` is gitignored (machine-specific). Create one locally if a future
> skill needs an MCP server.

## Versioning

- No `version` in plugin.json (repo versioned via release-please + git tags)
- Skill versions: bumped in SKILL.md frontmatter per feature PR
- CHANGELOG.md: updated with each PR

## PR Checklist

- [ ] Serves the plugin goal
- [ ] Skills are self-contained
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-database): description`
