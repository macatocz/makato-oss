---
name: archive-spec
description: 'Archive completed or obsolete specs after a PR is merged. Extracts requirements into the master spec, moves the spec folder to specs/archive/ or specs/obsolete/, and closes the linked GitHub Issue. Use when: PR merged, feature complete, spec superseded, or spec abandoned. Triggers: "archive spec", "archive feature", "spec done", "close feature", "mark obsolete", "merge to master spec".'
version: 1.0.0
---

# archive-spec

Archive completed or abandoned specs, keeping domain knowledge alive in master specs and closing
the linked GitHub Issue so the board reflects reality.

## Two Paths

| Path | When | Destination | Master Merge? | GitHub Issue |
| ---- | ---- | ----------- | ------------- | ------------ |
| **Archive** | PR merged, feature done | `specs/archive/` | YES | Close as completed |
| **Obsolete** | Never implemented, superseded, abandoned | `specs/obsolete/` | NO | Close as not-planned |

### Decision Tree

```text
Was the spec implemented?
├── YES (PR merged, code exists) → ARCHIVE path
│   ├── Retrospective spec check
│   ├── Extract requirements to master spec
│   ├── Move to specs/archive/{date}-{folder}
│   └── Close GitHub Issue
│
└── NO (never built, superseded) → OBSOLETE path
    ├── Add obsolete metadata to spec
    ├── Move to specs/obsolete/{date}-{folder}
    └── Close GitHub Issue as not-planned
```

---

## ARCHIVE Path

### Step 0 — Retrospective Spec Check

Before archiving, verify the spec reflects what was actually built. Specs drift during
implementation — the original plan rarely matches the shipped code exactly.

Checklist:

- [ ] `prd.md` exists and reflects actual scope (not the original idea)
- [ ] `design.md` or `architecture.md` captures decisions made during implementation
- [ ] `plan.md` tasks match the commits that landed (not the original task list)
- [ ] `domain` is set in `spec.md` or `plan.md` frontmatter for master spec routing

If artifacts are missing or badly stale, update them now. Archive is the last moment
to capture this knowledge before the feature context is lost.

### Step 1 — Validate Completion

```bash
# Confirm the PR is merged
gh pr list --state merged --search "closes #<issue-number>" --json number,title,mergedAt

# Confirm the issue is still open (not already archived by a previous run)
gh issue view <issue-number> --json state,title,labels
```

If the issue is already closed, skip to Step 4 (folder may already be moved — check first).

### Step 2 — Extract Delta to Master Spec

Load @references/master-spec-format.md for the target file structure.

```bash
# Determine domain from spec frontmatter
domain=$(grep -m1 "^domain:" specs/<folder>/plan.md | awk '{print $2}')
domain=${domain:-general}

master="specs/master/${domain}.md"
```

From the spec's `prd.md` and `plan.md`, extract:

- **ADDED** — new requirements / capabilities that landed
- **MODIFIED** — existing requirements that changed
- **REMOVED** — requirements explicitly dropped

Append ADDED to the `## Current Requirements` section of `${master}`. Move REMOVED to
`## Superseded Requirements`. Add an entry to `## Evolution Log` with date, feature
folder, change type, and a one-line rationale.

If `${master}` does not exist, create it from @templates/master-spec.md.

**Capability extraction rule**: for each PRD user story of the form
`As a {persona}, I want to {action}` → produce capability `{Persona} can {action}`.
See @references/capability-extraction.md for the full extraction rules.

### Step 3 — Move Folder

```bash
date_prefix=$(date +%Y-%m-%d)
mv specs/<folder> specs/archive/${date_prefix}-<folder>
```

### Step 4 — Close GitHub Issue

```bash
gh issue close <issue-number> \
  --comment "Archived: specs moved to specs/archive/${date_prefix}-<folder>. Requirements merged to specs/master/${domain}.md." \
  --reason "completed"
```

If the issue has a parent (epic/feature) label, check if all child issues are now closed:

```bash
gh issue list --label "feature:<parent-key>" --state open --json number,title
```

If all children are closed, close the parent too.

### Step 5 — Update specs/archive/README.md

Append a row to the archive index:

```markdown
| {date} | [{folder}](specs/archive/{date}-{folder}/) | {one-line description} | {issue-number} |
```

---

## OBSOLETE Path

### Step 1 — Add Obsolete Metadata

Edit the spec's main file (`spec.md` or `plan.md`) and prepend:

```markdown
> **Status**: Obsolete
> **Obsolete-Date**: {today}
> **Obsolete-Reason**: {why — e.g. "superseded by #42", "approach changed", "no longer needed"}
> **Superseded-By**: {spec folder or issue number, if applicable}
```

### Step 2 — Move Folder

```bash
date_prefix=$(date +%Y-%m-%d)
mv specs/<folder> specs/obsolete/${date_prefix}-<folder>
```

### Step 3 — Close GitHub Issue

```bash
gh issue close <issue-number> \
  --comment "Marked obsolete: {reason}. Spec moved to specs/obsolete/${date_prefix}-<folder>." \
  --reason "not planned"
```

### Step 4 — Update specs/obsolete/README.md

Append a row:

```markdown
| {date} | [{folder}](specs/obsolete/{date}-{folder}/) | {reason} | {issue-number} |
```

---

## Automation

`archive-spec` is triggered automatically via GitHub Actions on every PR merge to the default
branch. Copy `workflows/archive-spec.yml` from this plugin into `.github/workflows/` in your
consumer repo — no code changes required.

See @references/archive-spec-workflow.md for the full workflow file and wiring notes.

---

## NEVER

- NEVER move to `specs/archive/` without merging to the master spec first — requirements are lost
- NEVER close a parent issue before all child issues are closed
- NEVER use `--reason completed` for abandoned specs — use `--reason "not planned"`
- NEVER skip the retrospective spec check — emergent requirements disappear into the archive

## Composes With

- `makato-orchestrate:workflow-state` — read `current_phase` to confirm the issue is done before archiving
- `makato-orchestrate:documentation-agent` — post-merge trigger (Option B automation path)
- `makato-plan:to-issues` — issues created by `to-issues` carry the spec folder name; use it to resolve the folder

## References

- @references/master-spec-format.md — master spec file structure and merge rules
- @references/capability-extraction.md — PRD user story → capability extraction rules
- @templates/master-spec.md — blank master spec template
