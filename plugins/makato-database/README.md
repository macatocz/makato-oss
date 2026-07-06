# makato-database

**Goal:** Provide Postgres-focused skills for performance optimization, query writing, schema
design, and database administration — with scope to expand to additional database technologies.

**How:** Delivers self-contained reference skills built from Postgres ecosystem best practices.
Each skill draws on a curated library of rule files organized by impact category. Sibling skills
(manage-mysql, manage-sqlite) may be added following the same pattern.

**Why:** Users working with database technologies need expert-level guidance for schema design,
query writing, and performance analysis to production standards. General-purpose advice is rarely
enough; a focused, rule-backed skill closes the gap.

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

## Workflow

This is a reference plugin. The single skill is invoked directly whenever database work is in
scope — there is no sequential pipeline.

```
Caller (user / makato-build / makato-change)
        |
        |  SQL queries, schema specs, or DB config context
        v
┌──────────────────────────────┐
│       manage-postgres         │
│  (35 rule reference files)    │
└──────────────────────────────┘
        |
        |  Optimized queries, schema recommendations,
        |  index strategies, connection pooling guidance,
        |  RLS patterns
        v
     Caller
```

**manage-postgres**
Input: SQL queries, schema specs, or database configuration context requiring review or
optimization.
Output: Optimized SQL, schema recommendations, index strategies, connection pooling guidance, and
RLS patterns drawn from 35 reference rule files across 8 impact-prioritized categories.

## Skills

| Skill | Description | Input | Output | Version |
|-------|-------------|-------|--------|---------|
| [manage-postgres](skills/manage-postgres/SKILL.md) | Postgres performance optimization and best practices: query performance, connection management, security & RLS, schema design, concurrency, data access, monitoring, and advanced features across 8 rule categories prioritized by impact. (interactive) | SQL queries, schema specs, or database configuration context requiring review or optimization | Optimized SQL queries, schema recommendations, index strategies, connection pooling guidance, and RLS patterns drawn from 35 reference rule files | 1.1.1 |

## Notable Governance Files

| File | Purpose |
|------|---------|
| `plugins/makato-database/skills/manage-postgres/references/_sections.md` | Index of all 35 rule reference files organized by category |
| `plugins/makato-database/skills/manage-postgres/references/_contributing.md` | Authoring guide for adding new rule files to the references directory |
| `plugins/makato-database/skills/manage-postgres/references/_template.md` | Template for new rule files, defining the standard structure (why, incorrect example, correct example, metrics) |
| `plugins/makato-database/AGENTS.md` | Contributor routing, What Belongs/Does Not Belong, PR checklist, and file structure contract for the plugin |
| `plugins/makato-database/.claude-plugin/plugin.json` | Plugin manifest declaring name, description, and author |

## Plugin Connections

| Direction | Plugin | What flows |
|-----------|--------|-----------|
| Complements | makato-build | Use manage-postgres alongside build-refine when a story involves schema changes or query optimization |
| Complements | makato-observability | Postgres query performance profiling belongs in makato-database; OTel span instrumentation for DB calls belongs in makato-observability |

## Prerequisites / MCP Servers

None — pure reference skills, no MCP servers required.

## Installation

```bash
claude --plugin-dir ./plugins/makato-database
```

## Version

0.1.0
