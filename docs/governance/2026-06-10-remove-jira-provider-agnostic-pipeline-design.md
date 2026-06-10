# Design: Remove Jira — Provider-Agnostic makato Pipeline

**Date:** 2026-06-10
**Status:** Approved
**Scope:** All 9 skills in `plugins/makato-plan/skills/`

---

## Goal

Make the makato planning pipeline fully self-contained and provider-independent.
Jira is removed entirely — no variant, no legacy reference, no field names, no comments.
GitHub.com is the only optional external provider, activated only via `makato.config.yml`.
The pipeline works without any config file.

---

## Core Principle

Local `specs/` files are the source of truth at every stage. External systems are optional sync targets. No provider configured → pipeline is fully self-contained.

---

## Feature Identity & Folder Naming

Replace `specs/{ITDB-KEY}-{slug}/` with `specs/{slug}/`.

The slug is the only identifier. Derived at `brainstorming` start from the feature summary — kebab-case, max 60 chars, stable once set.

```text
specs/
└── checkout-redesign/
    ├── brainstorm.md
    ├── decisions.md
    ├── prd.md
    ├── design.md
    ├── prototype.html
    ├── stories.json
    └── reviews/
```

---

## `brainstorming` Input Detection

When user runs `/brainstorming [arg]`, detect origin in this order:

1. **GitHub Issue** — URL (`https://github.com/owner/repo/issues/123`) or short form
   (`owner/repo#123`) → fetch via GitHub MCP, import title, body, attachments. Slug derived
   from issue title.
2. **Existing slug** — `specs/{arg}/` exists → resume prior session.
3. **Plain text** — any other arg → use as feature description, derive slug.
4. **No arg** — auto-detect most recently modified `specs/*/`; if none, prompt for one-line description.

Spec folder always created at `specs/{slug}/`. If origin was GitHub Issue, record
`source: "github:owner/repo#123"` in `stories.json`.

---

## `publish` Redesign

### Always runs (local)

1. Validate `stories.json` (status approved, required fields present)
2. Write `specs/{slug}/handoff.md` — epic objective, story list with SPs, phases, dependencies, DoD per story
3. Create story subfolders: `specs/{slug}/{sequence:02d}-{story-slug}/` with `.gitkeep`
4. Print publish summary to terminal

### Only if `makato.config.yml` has `provider: github`

1. Ask for target repo if not set in config
2. Create one GitHub milestone for the epic
3. Create one GitHub Issue per story (markdown body rendered from story fields)
4. Write returned issue numbers to `stories.json` as `stories[].githubIssue`

### `makato.config.yml` (repo root)

```yaml
provider: github        # omit for local-only
github:
  repo: owner/repo-name
```

File absent or `provider` omitted → local-only, no GitHub prompts.

---

## `stories.json` Schema v2.0

### Removed fields

| Field | Reason |
|-------|--------|
| `feature` | Replaced by `slug` |
| `epic.pi` | DCP/Jira-specific |
| `epic.labels: ["pi_planning"]` | DCP-specific label |
| `stories[].jiraKey` | Jira-specific |
| `stories[].subtaskKeys` | Jira-specific |
| `confluencePageId` | Confluence-specific |
| Jira field mapping table in schema doc | Jira-specific |

### Added / changed fields

| Field | Type | Notes |
|-------|------|-------|
| `version` | `"2.0"` | Schema bump |
| `slug` | string | Replaces `feature` |
| `source` | string (optional) | `"github:owner/repo#123"` if origin was GitHub Issue; omit otherwise |
| `epic.labels` | string[] | `["makato"]` only (no `pi_planning`) |
| `stories[].githubIssue` | int (optional) | Set by `publish` when provider is github |
| `stories[].teams` | string[] | Free text, user-defined (no DCP team list) |

### Top-level structure

```json
{
  "version": "2.0",
  "slug": "checkout-redesign",
  "source": "github:owner/repo#123",
  "created": "2026-06-10",
  "status": "draft",
  "epic": {
    "summary": "Epic title",
    "objective": "One-line objective statement",
    "labels": ["makato"]
  },
  "stories": [ ... ]
}
```

---

## Files to Change

### Skills with hard Jira coupling — full rework required

| File | What changes |
|------|-------------|
| `brainstorming/SKILL.md` | Remove ITDB hard gate; add 4-way input detection; remove Jira MCP calls; slug-only folder naming |
| `publish/SKILL.md` | Replace entirely: local handoff always; GitHub Issues only if configured |
| `publish/references/jira-field-mapping.md` | Delete |
| `publish/references/dcp-story-panels.md` | Delete (Jira wiki markup panels) |
| `publish/references/subtask-templates.md` | Delete |
| `publish/references/confluence-page-template.md` | Delete |

### Skills with ITDB folder path references — targeted edits

| File | What changes |
|------|-------------|
| `decompose/SKILL.md` | `specs/{ITDB-KEY}-*/` → `specs/*/`; remove Jira next-step references; `epic.objective` prompt removes "appears on Jira epic" |
| `decompose/references/stories-json-schema.md` | Schema v2.0: remove all Jira fields, add `slug`/`source`/`githubIssue` |
| `decompose/references/dcp-story-template.md` | Remove DCP/Jira rendering references |
| `decompose/references/team-repository-mapping.md` | Remove DCP team names; make generic |
| `create-prd/SKILL.md` | Folder path fix; remove "No Jira side-effects" (already correct, just update wording) |
| `create-architecture/SKILL.md` | Folder path fix only |
| `create-acceptance-tests/SKILL.md` | Folder path fix; remove "before publish creates Jira stories" |
| `create-prototype/SKILL.md` | Folder path fix only |
| `grill/SKILL.md` | No changes needed |
| `excalidraw/SKILL.md` | No changes needed |

### New file

| File | Contents |
|------|---------|
| `publish/references/github-issue-template.md` | Markdown template for GitHub Issue body rendered from story fields |

### Config file (repo root, new)

`makato.config.yml` — documented in publish skill; created by user, not by the pipeline.

---

## Skill Description Updates

All `description:` frontmatter fields that mention "Jira ITDB" or "ITDB feature" change to describe the skill in makato-native terms.

| Skill | Old description | New description |
|-------|----------------|-----------------|
| `brainstorming` | "Structured divergent-convergent ideation on a Jira ITDB feature" | "Structured divergent-convergent ideation on a feature — brainstorm, explore ideas, creative exploration." |
| `decompose` | "Decompose pland features into vertically-sliced stories... Use after PRD and architecture are approved." | unchanged (already generic enough) |
| `publish` | "Publish pland stories to Jira and Confluence" | "Publish pland stories — create handoff summary, story folders, and optionally GitHub Issues." |

---

## What Does NOT Change

- All core planning logic: Three Amigos simulation, convergence flow, Gherkin scenarios, vertical slicing rules
- HTML review generation in `brainstorming`, `decompose`
- `stories.json` story object shape (background, scope, featureToggle, successScenarios, definitionOfDone, etc.)
- `grill`, `excalidraw`, `create-prd`, `create-architecture`, `create-prototype`, `create-acceptance-tests` core logic
- Spec folder structure below `specs/{slug}/`

---

## Self-Review

- No TBDs or placeholders
- No internal contradictions: folder naming is consistent across all sections
- Scope is bounded: 9 skills, 1 new file, 4 deletions, 1 new config spec
- No Jira concepts remain in any section of this design
