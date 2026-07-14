# makato-core

**Goal**: Provide the shared foundation that makes the suite work as a coherent system — contract
schemas, guide and help skills, and cross-cutting utilities that every other plugin depends on.

**How**: Ships cross-cutting developer utilities — codebase navigation, GitHub issue filing, and
plugin discovery — as self-contained skills with no runtime dependency on other plugins. Contracts
in `contracts/` define inter-plugin artifact shapes as design-time references only.

**Why**: Active plugin contributors and suite users need consistent, well-documented helpers that
don't belong to any single workflow domain. Centralising them in core prevents duplication and
ensures every plugin benefits from the same quality bar.

> **Documentation authoring** (library reference lookup, README crafting, markdown, prose editing)
> now lives in the sibling **[`makato-doc`](../makato-doc/README.md)** plugin.

## What Belongs Here

- Contract schemas defining artifact shapes for inter-toolkit data exchange
- Setup and initialization skills
- Mandatory MCP server declarations
- Guide and help skills for suite users
- Diagnostics and validation utilities
- Cross-cutting utilities that serve the entire suite

## What Does NOT Belong Here

- Workflow logic (belongs in a toolkit plugin)
- Domain-specific skills (belongs in the relevant toolkit)
- Anything that serves one toolkit's goal rather than the entire suite

## Workflow

makato-core is a reference and utility plugin — it does not define a sequential build pipeline.
Skills are invoked independently on demand by users or by other plugins.

```
┌──────────────────────────────────────────────┐
│                 suite consumer                 │
└──────┬───────────────┬──────────────┬─────────┘
       │               │              │
       ▼               ▼              ▼
 ┌──────────┐  ┌──────────────┐  ┌──────────────┐
 │  makato- │  │   create-    │  │   map-codebase-context   │
 │  guide   │  │   issue      │  │              │
 │ discover │  │ gh issue     │  │ dependency   │
 │ plugins  │  │ filed        │  │ map          │
 └──────────┘  └──────────────┘  └──────────────┘
```

Invocation order (typical session):

1. `makato-guide` — discover what is installed and find the right skill.
2. `map-codebase-context` — when orientation is needed in an unfamiliar codebase area.
3. domain skill (in another plugin) — do the work.
4. `create-issue` — file follow-up bugs or features against the makato repo.

> For documentation authoring (`context7` before writing code, `crafting-effective-readmes`,
> `markdown`, `writing-clearly-and-concisely`), see the **[`makato-doc`](../makato-doc/README.md)** plugin.

## Skills

| Skill | Description | Input | Output | Version |
|-------|-------------|-------|--------|---------|
| [`create-issue`](skills/create-issue/SKILL.md) | File a structured GitHub issue against the makato repo with the correct template, `[plugin-name]` title prefix, and labels. (autonomous) | Issue type (bug/feature/docs), plugin scope, title subject, and body details. Reads `.github/ISSUE_TEMPLATE/issue.md` and `.claude/config.json` automatically. | GitHub issue created via `gh` CLI; issue URL printed to stdout. | 1.1.0 |
| [`makato-guide`](skills/makato-guide/SKILL.md) | Discover installed makato plugins, list available skills, and help users find the right tool for any task. Scans `plugins/` directory and reads each `plugin.json` and `SKILL.md`. (interactive) | User question about suite capabilities or a specific task need; no file inputs required. | Structured text listing installed plugins, their skills with one-line descriptions, and a suggested next step. | 1.1.0 |
| [`map-codebase-context`](skills/map-codebase-context/SKILL.md) | Map module dependencies and build a higher-level view of unfamiliar code areas. Two-phase: call hierarchy up (who calls this) and down (what this calls) to 2 hops, then ranked reading recommendations. (interactive) | Optional module or file name; codebase must be readable. Uses LSP, Grep, Glob, and Read tools. | Structured dependency map: module responsibility, callers, callees, architecture placement, and 2–3 ranked files to read next. | 1.4.0 |

## Shared Resources

| File | Purpose |
|------|---------|
| `plugins/makato-core/shared/design-system/DESIGN.md` | Design system reference used by plan/UX skills within the suite. |
| `plugins/makato-core/shared/design-system/impacto-design-system.html` | Impacto design system HTML component reference. |
| `plugins/makato-core/shared/design-system/plan-template-reference.html` | Plan template HTML reference used when generating plan documents. |

## Notable Governance Files

| File | Purpose |
|------|---------|
| `plugins/makato-core/contracts/build-jsonl.md` | Contract schema for the append-only `build.jsonl` JSONL event log written by all makato-build skills — defines required fields, step values, and invariants. |
| `plugins/makato-core/contracts/spec-folder.md` | Contract schema for the `specs/<story-key>/` artifact directory — defines all files, their producers, and their consumers across makato-plan and makato-build. |
| `plugins/makato-core/AGENTS.md` | Contributor routing guide: Goal, What Belongs / Does Not Belong, file structure, skill authoring rules, versioning policy, and PR checklist. |
| `plugins/makato-core/.claude-plugin/plugin.json` | Plugin manifest with name, description, and author — no version field (repo versioned via release-please). |

## Plugin Connections

| Direction | Plugin | What flows |
|-----------|--------|-----------|
| Produces for | `makato-contribute` | `makato-guide` for skill discovery; `create-issue` for filing bugs and features |
| Produces for | `makato-plan` | `create-issue` for filing issues; `map-codebase-context` for codebase orientation |
| Produces for | `makato-build` | `create-issue`; `contracts/spec-folder.md` and `contracts/build-jsonl.md` as design-time schemas consumed by makato-build skills |
| Produces for | `makato-orchestrate` | `makato-guide` for skill discovery; `create-issue` for filing issues |
| Produces for | `makato-change` | `makato-guide` for skill discovery; `create-issue` for filing issues |
| Produces for | `makato-ux` | `makato-guide` for skill discovery; `create-issue` for filing issues |
| Produces for | `makato-langgraph` | `create-issue` for filing issues; `map-codebase-context` for orientation |
| Produces for | `makato-database` | `makato-guide` for skill discovery; `create-issue` for filing issues |
| Produces for | `makato-sagibeast` | `makato-guide` for skill discovery; `create-issue` for filing issues |
| Produces for | `makato-observability` | `create-issue` for filing issues; `map-codebase-context` for orientation |
| Sibling of | `makato-doc` | documentation-authoring skills (`context7`, `crafting-effective-readmes`, `markdown`, `writing-clearly-and-concisely`) extracted from core |

## Prerequisites / MCP Servers

No MCP servers are bundled with makato-core. External prerequisites:

- `gh` CLI — required by `create-issue` for GitHub API operations

Documentation skills (`context7`, `markdown`, …) and their prerequisites (Context7 MCP server,
prettier, markdownlint-cli) now live in the **[`makato-doc`](../makato-doc/README.md)** plugin.

## Installation

```bash
claude --plugin-dir ./plugins/makato-core
```

## Version

Managed by release-please at repo level; per-skill versions live in SKILL.md frontmatter.
