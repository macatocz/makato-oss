# makato-database

**Goal**: Provide the set of technology skills for database creation, SQL creation,
schema designs, database configuration, SQL queries, and SQL performance.

**How**: It uses the best practices from the database field.

**Why**: Users will have developed and managed database-related technologies and
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

## Skills

| Skill | Description | Version |
|-------|-------------|---------|
| `manage-postgres` | Postgres performance optimization and best practices: query performance, connection management, security & RLS, schema design, concurrency, data access, monitoring, advanced features | `1.1.1` |

## Prerequisites

None — current skills are pure reference. Future skills that need a live
database may declare an MCP server via a local `.mcp.json` (gitignored;
machine-specific).

## Installation

```bash
claude --plugin-dir ./plugins/makato-database
```

## Version

0.1.0
