# makato Naming Conventions

> **Scope**: Plugin directories, skill directories, agent markdown files, SKILL.md frontmatter, JSONL audit log fields, spec folder slugs, and conventional commit prefixes across the entire makato monorepo.

## Plugin Directory Names

Pattern: `makato-<domain>` (kebab-case, `makato-` prefix mandatory).

Examples from the repo:

```
makato-build
makato-change
makato-contribute
makato-core
makato-database
makato-doc
makato-fastapi
makato-langgraph
makato-observability
makato-orchestrate
makato-plan
makato-sagibeast
makato-temporal
makato-ux
```

## Skill Directory Names

Pattern: `<verb>-<noun>` (kebab-case verb-noun). Skills live under `plugins/<plugin>/skills/`.

Examples:

```
build-refine
build-implement-tdd
build-implement-goal
build-push-to-git
build-create-pr
build-address-pr-comments
seed-issue
kill-switch
resolve-pr-conflict
promote-ready
```

## SKILL.md Frontmatter Fields

Every skill's `SKILL.md` must include these frontmatter fields (YAML front matter fenced by `---`):

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Kebab-case skill identifier, matches the directory name |
| `description` | yes | Single-sentence description (≤ 120 chars recommended) |
| `version` | yes | Semantic version string, e.g. `"1.0.0"` |
| `model` | no | Override model (`opus`, `sonnet`). Omit to inherit from context. |
| `argument-hint` | no | CLI argument hint shown in help, e.g. `"[work-item-key] [--autonomous]"` |

Example:

```yaml
---
name: build-refine
description: >-
  Bridge a shaped Jira story, GitHub issue, or any work unit to an
  implementation plan.
version: "1.10.0"
model: opus
argument-hint: "[work-item-key] [--autonomous]"
---
```

## Agent Markdown Filenames

Pattern: `<noun>.md` or `<adjective>-<noun>.md` (kebab-case). Agent files live under `plugins/<plugin>/agents/`.

Examples: `coder.md`, `diff-reviewer.md`, `gate-scout.md`, `knowledge-scout.md`, `plan-analyst.md`, `sensor-fixer.md`.

## R1 `agent` Field

The R1 envelope's `"agent"` field must exactly equal the agent's frontmatter `name:` value. There is no transformation.

Example: agent frontmatter `name: coder` → R1 field `"agent": "coder"`.

## JSONL Audit Log Field Names

Every entry in `build.jsonl` (emitted via `shared/build-log.sh`) uses these canonical field names:

| Field | Type | Description |
|-------|------|-------------|
| `ts` | ISO 8601 string | Timestamp, e.g. `"2026-07-14T19:21:45.608Z"` |
| `skill` | string | Skill or script that emitted the entry, e.g. `"build-implement-tdd"` |
| `story` | string | Work-item key (spec folder basename), e.g. `"348-makato-orchestrate-emit-a-durable-needs"` |
| `step` | string | Phase or action name, e.g. `"session"`, `"baseline"`, `"build"`, `"r1"` |
| `status` | string | `"start"`, `"ok"`, `"warn"`, `"error"`, `"decision"` |
| `task` | int | (optional) 1-based task index when the entry is task-scoped |
| `data` | object | (optional) Step-specific payload |
| `error` | string | (optional) Error message when `status == "error"` |

`issue` (int) may appear in place of `story` for orchestrate-level events emitted by `po-agent` / `progress-comment`.

## Spec Folder Slug Pattern

Pattern: `<ISSUE_NUMBER>-<normalized-title>` where `<normalized-title>` is the issue title lowercased, non-alphanumeric characters replaced with `-`, truncated to 40 characters, no trailing `-`.

Examples:

```
348-makato-orchestrate-emit-a-durable-needs
591-repo-wide-feat-add-context-makato
131-repo-wide-feat-f5-domain-tagged-skill
```

The spec folder lives under `specs/` (gitignored except `specs/**/build.jsonl`).

## Conventional Commit Prefix Format

Pattern: `type(plugin-name): description` where:

- `type` is one of: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `perf`, `ci`
- `plugin-name` is the bare plugin folder name without the `makato-` prefix: `build`, `change`, `orchestrate`, `plan`, `core`, `observability`, etc.
- `description` is a lowercase, imperative-mood summary (no period at end)

Examples:

```
feat(makato-orchestrate): shared-epic folder guard in reaper
fix(makato-sagibeast): document sagibeast-testbox runner label contract
chore: release v0.110.0
```

`chore` commits with repo-wide scope may omit the plugin qualifier.
