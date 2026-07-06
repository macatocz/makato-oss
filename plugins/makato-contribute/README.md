# makato-contribute

**Goal:** Help contributors participate in makato suite development — scaffolding new plugins and
skills to convention, resolving PR review feedback, and syncing content from upstream repos — all
pre-validated against the framework's guardrails.

**How:** A set of interactive skills that create new plugins, skills, agents, and hooks; triage and
fix post-PR review comments; and migrate content from upstream sources — each step validated against
suite conventions before writing files.

**Why:** Active participation in the framework should be easy and encouraged, but every contribution
must fit together coherently. These tools encode the guardrails so contributors do not have to
memorize them.

## What Belongs Here

- Skills that create or scaffold plugins, skills, agents, or hooks
- Validation helpers for contributors
- Tools that teach or enforce makato conventions
- PR review triage and resolution workflows
- Upstream content migration with naming remaps and convention validation

## What Does NOT Belong Here

- End-user workflow skills (those belong in toolkits)
- Foundation/contract definitions (those belong in makato-core)
- Anything not directly helping contributors create correct plugins

## Workflow

All four skills are independent entry points invoked directly by a contributor. They do not form a
sequential pipeline — each addresses a distinct contributor task.

```
Contributor Intent
       │
       ├──► makato-plugin-creator ──► New plugin directory + marketplace.json update
       │         Interview → Plan → Present → Build
       │
       ├──► makato-skill-creator ──► New skill directory + plugin.json update
       │         Interview → Plan → Present → Build
       │
       ├──► manage-pr ──────────────► Fixed commits pushed + review threads resolved
       │         Fetch → Triage → Approve → Fix → Reply
       │
       └──► sync-from-upstream ─────► Migrated files written to makato plugin dirs
                 Delta → Remap → Plan → Write
```

| Phase | Input | Output |
|-------|-------|--------|
| makato-plugin-creator | Plugin name, goal, governance boundaries | Complete plugin directory; `marketplace.json` updated |
| makato-skill-creator | Target plugin name, skill intent | Skill directory; `plugin.json` skills list updated |
| manage-pr | Open PR number or URL | Fixed code pushed; review threads resolved |
| sync-from-upstream | Path to upstream repo; optional scope | Migrated files written with naming remaps applied |

## Skills

| Skill | Description | Input | Output | Version |
|-------|-------------|-------|--------|---------|
| [makato-plugin-creator](skills/makato-plugin-creator/SKILL.md) | Create a complete, working makato plugin with governance files populated from an interview process. Conducts a structured Plan → Present → Build workflow: interviews for plugin identity and governance, performs suite alignment check, generates an interactive HTML review plan, then builds all governance files. (interactive) | Contributor intent description — plugin name, goal statement, how/why, author, governance boundaries, and optional MCP server declarations. | Complete plugin directory under `plugins/<name>/` with `plugin.json`, `CLAUDE.md`, `AGENTS.md`, `README.md`, `CHANGELOG.md`, and optional `.mcp.json`; `marketplace.json` updated. | 2.2.1 |
| [makato-skill-creator](skills/makato-skill-creator/SKILL.md) | Create a complete, working skill inside an existing makato plugin with full guardrails and validation. Follows Plan → Present → Build: interviews for skill purpose, validates goal alignment against parent plugin, designs the workflow, plans reference and template files, presents an HTML review plan, then builds all skill files. (interactive) | Target plugin name and skill intent — what to accomplish, inputs, outputs, and skill name (kebab-case). | New skill directory under `plugins/<plugin>/skills/<name>/` with `SKILL.md`, `references/`, and optional `templates/`; `plugin.json` skills list updated. | 1.1.2 |
| [manage-pr](skills/manage-pr/SKILL.md) | Triage and resolve PR review-bot comments after opening a PR. Validates each finding against the actual code, rates validity and severity, presents a report for approval, applies approved fixes, posts `gh` CLI replies, and resolves review threads via GraphQL. (interactive) | Open PR number or URL (or infers from current branch); the PR must already exist with bot review comments. | Fixed code committed and pushed; `gh` CLI reply posted to each addressed comment thread; review threads resolved via GitHub GraphQL API. | 1.1.0 |
| [sync-from-upstream](skills/sync-from-upstream/SKILL.md) | Migrate skills, agents, and plugin files from an upstream impact-market repo into makato. Computes a sync delta, applies naming remaps and tooling substitutions, strips impact-market-specific references, produces a change plan for review, then writes migrated files validated against makato conventions. (interactive) | Path to the upstream impact-market repository (default: `../impact-market` relative to makato root) and optional scope selection from the computed delta. | Migrated files written to the appropriate makato plugin directories with all naming remaps applied; change plan presented before any writes. | 1.0.0 |

## Plugin Connections

| Direction | Plugin | What flows |
|-----------|--------|------------|
| Produces for | all plugins | Scaffolded plugin and skill directory structures following suite conventions — produces the foundational files that every other plugin is built from |
| Complements | makato-core | Uses makato-core `create-issue` skill to file discovered gaps, and `makato-guide` for convention reference during scaffolding |

## Prerequisites / MCP Servers

None — no MCP servers required.

External prerequisites:

- `gh` CLI — required for `manage-pr` to fetch review comments, post replies, and resolve threads
  via GitHub REST and GraphQL APIs.

## Installation

```bash
claude --plugin-dir ./plugins/makato-contribute
```

## Notable Governance Files

| File | Purpose |
|------|---------|
| `plugins/makato-contribute/AGENTS.md` | Governance contract: goal, how, why, what belongs/does not belong, skill authoring rules, file structure, versioning, PR checklist |
| `plugins/makato-contribute/.claude-plugin/plugin.json` | Plugin metadata: name, description, author — no version field (repo-level versioning via release-please) |
| `plugins/makato-contribute/CHANGELOG.md` | Per-PR changelog tracking skill version bumps and feature additions |
| `plugins/makato-contribute/skills/makato-plugin-creator/references/` | Reference files for plugin creator: `naming-conventions.md`, `plugin-architecture-rules.md`, `plan-template.html` |
| `plugins/makato-contribute/skills/makato-skill-creator/references/` | Reference files for skill creator: `naming-conventions.md`, `decision-test-pattern.md`, `skill-authoring-rules.md`, `self-containment-rules.md`, `plan-template.html` |
| `plugins/makato-contribute/skills/manage-pr/references/` | Reference files for manage-pr: `gh-cli-github.md`, `comment-validation-rubric.md`, `severity-rating-rubric.md`, `reply-templates.md` |
| `plugins/makato-contribute/skills/sync-from-upstream/references/` | Reference files for sync-from-upstream: `plugin-map.md`, `naming-map.md`, `deliberate-divergences.md` |
| `plugins/makato-contribute/skills/sync-from-upstream/templates/` | Output templates used by sync-from-upstream when producing migrated file content |

## Version

0.3.0
