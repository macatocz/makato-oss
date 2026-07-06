# makato-core

**Goal**: Provide the shared foundation that makes the suite work as a coherent system — contract
schemas, guide and help skills, and cross-cutting utilities that every other plugin depends on.

**How**: Ships cross-cutting developer utilities — codebase navigation, documentation authoring,
GitHub issue filing, and library reference lookup — as self-contained skills with no runtime
dependency on other plugins. Contracts in `contracts/` define inter-plugin artifact shapes as
design-time references only.

**Why**: Active plugin contributors and suite users need consistent, well-documented helpers that
don't belong to any single workflow domain. Centralising them in core prevents duplication and
ensures every plugin benefits from the same quality bar.

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
┌──────────────────────────────────────────────────────────────┐
│                        suite consumer                        │
└──────┬───────────┬──────────────┬──────────────┬────────────┘
       │           │              │              │
       ▼           ▼              ▼              ▼
 ┌──────────┐ ┌──────────┐ ┌──────────────┐ ┌───────────────┐
 │  context7│ │  makato- │ │   create-    │ │   markdown /  │
 │          │ │  guide   │ │   issue      │ │   zoom-out /  │
 │ lib docs │ │ discover │ │ gh issue     │ │   writing /   │
 │ snippets │ │ plugins  │ │ filed        │ │   readmes     │
 └──────────┘ └──────────┘ └──────────────┘ └───────────────┘
```

Invocation order (typical session):

1. `makato-guide` — discover what is installed and find the right skill.
2. `context7` — look up library documentation before writing code.
3. domain skill (in another plugin) — do the work.
4. `crafting-effective-readmes` / `markdown` / `writing-clearly-and-concisely` — document the result.
5. `create-issue` — file follow-up bugs or features against the makato repo.
6. `zoom-out` — when orientation is needed in an unfamiliar codebase area.

## Skills

| Skill | Description | Input | Output | Version |
|-------|-------------|-------|--------|---------|
| [`context7`](skills/context7/SKILL.md) | Retrieve up-to-date documentation for software libraries, frameworks, and components via the Context7 API. Use instead of training data for API syntax, code examples, or version-specific behaviour. | Library name and a specific query (e.g. `react / useState hook usage`); requires Context7 MCP server. | Current documentation snippets and code examples fetched from Context7 API, returned as inline text. | 1.0.0 |
| [`crafting-effective-readmes`](skills/crafting-effective-readmes/SKILL.md) | Guide for creating, updating, or reviewing README files for any project type (OSS, internal, personal, config). Applies template selection, style guide, and section-checklist workflow. (interactive) | Path to existing README or `new`; project type is inferred or asked. Loads internal templates and style guide from skill directory. | Written or updated `README.md` file on disk. | 1.4.1 |
| [`create-issue`](skills/create-issue/SKILL.md) | File a structured GitHub issue against the makato repo with the correct template, `[plugin-name]` title prefix, and labels. (autonomous) | Issue type (bug/feature/docs), plugin scope, title subject, and body details. Reads `.github/ISSUE_TEMPLATE/issue.md` and `.claude/config.json` automatically. | GitHub issue created via `gh` CLI; issue URL printed to stdout. | 1.1.0 |
| [`makato-guide`](skills/makato-guide/SKILL.md) | Discover installed makato plugins, list available skills, and help users find the right tool for any task. Scans `plugins/` directory and reads each `plugin.json` and `SKILL.md`. (interactive) | User question about suite capabilities or a specific task need; no file inputs required. | Structured text listing installed plugins, their skills with one-line descriptions, and a suggested next step. | 1.1.0 |
| [`markdown`](skills/markdown/SKILL.md) | Author and lint `.md` files, fix markdownlint errors, and set up markdown tooling. Runs prettier then markdownlint in fixed order; loads `lint-rules.md` reference for violation diagnosis. (interactive) | File or directory path to format/validate; requires prettier and markdownlint-cli to be installed. | Formatted `.md` files on disk with lint violations fixed; suppression annotations added where warranted. | 1.3.1 |
| [`writing-clearly-and-concisely`](skills/writing-clearly-and-concisely/SKILL.md) | Edit prose for clarity using Strunk's rules, avoiding common AI writing patterns (passive voice, sentence-length convergence, puffery). Covers commit messages, error messages, and documentation. (interactive) | Text inline or a file path to edit. Loads `elements-of-style/` sections on demand. | Edited prose returned inline or written to file via Edit tool. | 1.4.0 |
| [`zoom-out`](skills/zoom-out/SKILL.md) | Map module dependencies and build a higher-level view of unfamiliar code areas. Two-phase: call hierarchy up (who calls this) and down (what this calls) to 2 hops, then ranked reading recommendations. (interactive) | Optional module or file name; codebase must be readable. Uses LSP, Grep, Glob, and Read tools. | Structured dependency map: module responsibility, callers, callees, architecture placement, and 2–3 ranked files to read next. | 1.4.0 |

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
| Produces for | `makato-plan` | `context7` for library documentation lookups; `create-issue` for filing issues |
| Produces for | `makato-build` | `context7` for library documentation lookups; `create-issue`; `contracts/spec-folder.md` and `contracts/build-jsonl.md` as design-time schemas consumed by makato-build skills |
| Produces for | `makato-orchestrate` | `makato-guide` for skill discovery; `create-issue` for filing issues |
| Produces for | `makato-change` | `makato-guide` for skill discovery; `create-issue` for filing issues |
| Produces for | `makato-ux` | `makato-guide` for skill discovery; `create-issue` for filing issues |
| Produces for | `makato-langgraph` | `context7` for library documentation lookups; `create-issue` for filing issues |
| Produces for | `makato-database` | `makato-guide` for skill discovery; `create-issue` for filing issues |
| Produces for | `makato-sagibeast` | `makato-guide` for skill discovery; `create-issue` for filing issues |
| Produces for | `makato-observability` | `context7` for library documentation lookups; `create-issue` for filing issues |

## Prerequisites / MCP Servers

No MCP servers are bundled with makato-core itself. The `context7` skill requires the Context7
MCP server to be configured separately.

External prerequisites:

- `gh` CLI — required by `create-issue` for GitHub API operations
- `prettier` (`npm install -g prettier`) — required by `markdown` skill
- `markdownlint-cli` (`npm install -g markdownlint-cli`) — required by `markdown` skill
- Context7 MCP server (`plugin:context7`) — required by `context7` skill

## Installation

```bash
claude --plugin-dir ./plugins/makato-core
```

## Version

Managed by release-please at repo level; per-skill versions live in SKILL.md frontmatter.
