---
name: archive-spec
description: >-
  Archive completed or obsolete specs after a PR is merged. Extracts requirements
  into the master spec, moves the spec folder to specs/archive/ or specs/obsolete/,
  and closes the linked GitHub Issue. Use when: PR merged, feature complete, spec
  superseded, or spec abandoned. Triggers: "archive spec", "archive feature",
  "spec done", "close feature", "mark obsolete", "merge to master spec".
version: 1.2.1
argument-hint: '<spec-folder-name or issue-number>'
allowed-tools: [Bash]
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

## Before You Start — Resolving the Spec Folder

When the caller provides only an issue number (no folder name), derive the spec folder before
proceeding. Attempt in order — stop at the first hit:

```bash
ISSUE=<issue-number>

# 1. PO-agent workflow-state (most reliable when the loop has run)
grep -o '"spec_folder":\s*"[^"]*"' \
  "$(git rev-parse --show-toplevel)/.claude/state/workflow-state.json" 2>/dev/null

# 2. to-issues provenance footer in the issue body
gh issue view $ISSUE --json body \
  | grep -oP 'specs/[^\s/)>]+' | head -1

# 3. Issue-number prefix on the folder name (seed-issue stamps <N>-<slug>)
ls "$(git rev-parse --show-toplevel)/specs/" \
  | grep -E "^${ISSUE}-"

# 4. stories.json githubIssue field (to-issues emits this)
grep -rl "\"github_issue\"" "$(git rev-parse --show-toplevel)/specs/" \
  | xargs grep -l "\"${ISSUE}\"" 2>/dev/null | head -1
```

If none of the four lookups resolve the folder, ask the operator for the exact path before
continuing — do NOT guess or construct a folder name from the issue title alone (title-slug
derivation diverges from `_derive_key_for_issue`'s hard-cut logic and will produce the wrong
path).

---

## ARCHIVE Path

### Step 0 — Retrospective Spec Check

Before archiving, verify the spec reflects what was actually built. Specs drift during
implementation — the original plan rarely matches the shipped code exactly.

**Stale-threshold decision framework — use this to decide what to update before archiving:**

| Drift Condition | Action |
|-----------------|--------|
| >30% of `plan.md` tasks cannot be matched to merged commits | Rewrite `plan.md` tasks to reflect what landed; annotate dropped tasks as `skipped:` with a reason |
| `prd.md` missing entirely | Synthesize a stub from the PR description (title + merged diff summary); mark frontmatter `source: synthesized`; do NOT skip archiving |
| Architectural decisions were made (schema changed, API contract changed) but `design.md` absent | Write a stub capturing the decisions; note `retroactively documented` in Evolution Log |
| Scope shrank (features dropped mid-PR) | Mark dropped user stories as REMOVED in Evolution Log; do NOT add them to Current Requirements |
| Scope expanded (undocumented additions) | Add them as new capabilities in Current Requirements; note `scope drift: expanded` in Evolution Log rationale |
| Minor drift (1-2 tasks swapped, wording updates) | Annotate inline with `<!-- as-shipped: ... -->`; no full rewrite needed |

The bar is: *archive is always better than not-archive even with drift*. The goal is capturing
what actually shipped, not preserving the original plan. Only refuse to archive when the PR is
still open or in review (see NEVER).

Checklist:

- [ ] `prd.md` exists and reflects actual scope (not the original idea)
- [ ] `design.md` or `architecture.md` captures decisions made during implementation
- [ ] `plan.md` tasks match the commits that landed (not the original task list)
- [ ] `domain` is set in `spec.md` or `plan.md` frontmatter for master spec routing (the makato-plan pipeline does not write this field — add it manually before archiving; omitting it routes the spec to the `general` master spec, which is a safe fallback but loses topic-specific grouping)

Archive is the last moment to capture this knowledge before the feature context is lost.

### Step 1 — Validate Completion

```bash
# Confirm the PR is merged
gh pr list --state merged --search "closes #<issue-number>" --json number,title,mergedAt

# Confirm the issue is still open (not already archived by a previous run)
gh issue view <issue-number> --json state,title,labels
```

If the issue is already closed, skip to Step 4 (folder may already be moved — check first).

### Step 2 — Extract Delta to Master Spec

MANDATORY: Load @references/master-spec-format.md now — needed for merge rules, domain
resolution fallback (keyword routing table), and conflict handling. Do NOT load before this step.

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
MANDATORY when creating a new master spec: the template is at @templates/master-spec.md —
load it at this point only. Do NOT load for updates to existing master specs.

**Capability extraction rule**: for each PRD user story of the form
`As a {persona}, I want to {action}` → produce capability `{Persona} can {action}`.
MANDATORY when the PRD contains "As a / I want to" stories: load
@references/capability-extraction.md for edge cases (no-PRD, duplicate, truncation).
Do NOT load unless extraction is underway.

**Conflict handling**: if an incoming requirement overlaps an existing one in `${master}`,
show both to the user with a diff and offer three options — supersede (replace), merge
(combine), or skip — then record the decision in the Evolution Log rationale column.
Full conflict-resolution rules are in @references/master-spec-format.md § Conflict Handling.

**Partial-step recovery**: if Step 2 fails mid-merge (e.g. editor crash), check
`${master}` for a partially written Evolution Log row before re-running — duplicate rows
will silently corrupt the audit trail.

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

`archive-spec` runs automatically via GitHub Actions on every PR merge to the default
branch — but the runner path is a **deterministic bash port**, not this LLM skill.
`scripts/archive-spec.sh` performs the mechanical ARCHIVE steps (derive slug → move
folder → append an Evolution Log row → close the issue) with no Claude CLI on the
runner, consistent with the D5 "no LLM in the runner" constraint (#221). Copy
`workflows/archive-spec.yml` from this plugin into `.github/workflows/` in your consumer
repo and vendor `scripts/archive-spec.sh` alongside it — no API-key secret required.

This SKILL remains the source of truth for the **interactive / model-driven** path:
the full retrospective spec check, semantic requirement extraction (ADDED / MODIFIED /
REMOVED), the OBSOLETE path, and conflict handling — judgement the bash port
intentionally does not attempt. Invoke it directly (`/makato-orchestrate:archive-spec`)
when you want that richer merge into the master spec, or for obsolete specs.

MANDATORY only when wiring up GHA automation: load @references/archive-spec-workflow.md
for the full YAML and issue-resolution edge cases. Do NOT load during interactive
archival runs — it is CI infrastructure, not interactive process guidance.

---

## NEVER

- NEVER move to `specs/archive/` without merging to the master spec first — WHY: once the folder moves, requirements are indexed only by the archive folder name; future work in the same domain starts from a stale master spec with no automated alert that a merge was skipped. The master spec is the only living index of domain capability.
- NEVER close a parent issue before all child issues are closed — WHY: GitHub has no built-in cascade; a closed parent misleads `promote-ready` (which reads live child Status on the board, not the parent state) and leaves the board showing a Done epic with open child work that the loop will silently skip on next poll.
- NEVER use `--reason completed` for abandoned or superseded specs — WHY: `promote-ready` reads closure reason when computing dependency waves and distinguishing implemented from abandoned predecessors; wrong reason causes incorrect dependency resolution in the unblocking graph.
- NEVER skip the retrospective spec check (Step 0) — WHY: archive is the last moment the implementer's context is live and the branch still exists; spec drift (tasks that didn't land, scope that changed mid-PR) becomes permanently invisible in the Evolution Log once the branch is deleted.
- NEVER archive a spec whose linked PR is still open or in review — WHY: the PR may be rejected, rebased away, or the `Closes #N` link removed; archiving before merge creates a phantom capability entry in the master spec for code that may never ship, silently corrupting the domain baseline.
- NEVER re-run Step 2 (master spec merge) after a crash without first checking `${master}` for a partially written Evolution Log row — WHY: Evolution Log rows are only semi-unique (same date + folder combination can appear twice); a blind rerun appends a duplicate row that corrupts the audit trail with no automated detection, because the merge rules append without deduplicating.

## Composes With

- `makato-orchestrate:workflow-state` — read `current_phase` to confirm the issue is done before archiving
- `makato-orchestrate:documentation-agent` — post-merge trigger (Option B automation path)
- `makato-plan:to-issues` — issues created by `to-issues` carry the spec folder name; use it to resolve the folder

## References

- @references/master-spec-format.md — master spec file structure, domain resolution fallback (keyword routing table), and merge/conflict rules. Load at Step 2 only.
- @references/capability-extraction.md — PRD user story → capability extraction rules and edge cases. Load at Step 2 when "As a / I want to" stories are present.
- @templates/master-spec.md — blank master spec template (used when `${master}` does not exist). Load at Step 2 only when creating a new master spec.
- @references/archive-spec-workflow.md — GHA YAML template and script wiring. Load only when setting up automation; never during interactive runs.
