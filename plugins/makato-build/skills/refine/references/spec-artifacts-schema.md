# Spec Artifacts Schema

Spec artifacts are produced by makato-plan and consumed by makato-build skills.
All live in `spec/<work-item-key>/`.

## stories.json

Array of story objects. Find the entry where `key` matches the work item key.

**Required fields per entry:**

| Field | Type | Description |
|-------|------|-------------|
| `key` | string | Work item identifier (e.g. "DCP-1234", "gh-123") |
| `title` | string | Short story title |
| `description` | string | Functional description of what the story does |
| `acceptance_criteria` | array | List of AC strings — treat as AC-1, AC-2, … by index |
| `phase` | string | Implementation phase label |

**Optional fields:**

| Field | Type | Description |
|-------|------|-------------|
| `story_type` | string | "feature", "bug", "chore", etc. |
| `dependencies` | array | Keys of work items that must be merged first |
| `notes` | string | Contributor notes or constraints |

## prd.md

Markdown document. Look for H2 headings matching these sections:

| Section | What to extract |
|---------|-----------------|
| Goal / Objective | User-facing purpose of the feature |
| Scope | Explicit in-scope and out-of-scope items |
| Functional Requirements | Numbered list of requirements |
| Non-Functional Requirements | Performance, security, accessibility constraints |
| Success Metrics | How success will be measured |

Not all sections are guaranteed. Extract what is present; do not fail if a section is absent.

## design.md

Markdown document. Look for H2 headings matching these sections:

| Section | What to extract |
|---------|-----------------|
| System Context | How this feature fits in the broader system |
| Component Design | Which components are created or modified |
| API Design | Endpoint definitions, request/response plans |
| Data Model | Entity definitions, schema changes |
| Technical Decisions | Key choices made and why |
| Test Strategy | Prescribed approach to testing this feature |

## decisions.md

Each decision record contains:
- **Decision**: what was decided
- **Context**: why this decision was needed
- **Rationale**: why this option was chosen over alternatives
- **Consequences**: what this decision constrains going forward

Treat every entry as a fixed constraint. Do not re-open or revise decisions here.

## prototype.html (optional)

Interactive HTML prototype of the UI. If present, flag the story as having a UI
reference and note its path. The `implement-goal` skill uses this as a visual target.
