# PR Description Guide

## PR Title

Format: `type(scope): description` — conventional commit style, ≤72 chars total.

- **type**: `feat` for new story implementation; `fix` if the story corrects a defect; `refactor` if no new behavior
- **scope**: the primary module, service, or component touched (e.g. `invoice`, `auth`, `deals-view`)
- **description**: imperative, no period — what the PR delivers, not what files changed

Derive from the selected `stories.json` entry's title or the current story's `plan.md` slice. If neither exists, synthesize from that story's commit messages.

## Spec Context Boundaries

Use the selected story entry and its plan/task slice only; never include sibling stories'
acceptance criteria, tasks, or implementation context. Read `prd.md` and `design.md`
only by explicit section references in the selected story or its plan, and extract only
those referenced sections (including their nested content). Do not load either
module-wide document in full. Filter `build.jsonl` to the selected story before using
its AC verdicts or gate/session evidence; keep all rows for that story available.

## Description of Changes — What Changed

One bullet per completed plan task in the selected story's plan slice. Each bullet: task title + one sentence on the specific change; never include sibling-story tasks.

**Good:** `- Add status field to Invoice entity — new `status` column in schema, mapped via JPA`
**Vague:** `- Updated Invoice` or `- Backend changes`

If no `plan.md` exists, derive from commit messages: one bullet per commit.

## Goal Alignment

Three lines:
1. Plugin name: `makato-<name>`
2. Goal: quote the plugin's goal statement from `AGENTS.md`
3. Alignment: one sentence explaining how this story advances that goal

## How to Test

One numbered step per acceptance criterion from the selected `stories.json` entry only.
Keep the complete criteria list in its original order. Each step must be concrete:
- Name the exact command to run or action to take
- State the input or precondition
- State the expected observable output

**Good:**
```
1. POST /api/invoices with status: "DRAFT" — response body includes "status": "DRAFT"
2. Attempt transition DRAFT → PAID — returns 200 with updated status
3. Attempt invalid transition PAID → DRAFT — returns 422 with error code INVALID_TRANSITION
```

**Vague:**
```
1. Test the invoice endpoint
2. Verify status transitions work
```

If no `stories.json` exists but `seed-manifest.json` has `spec_tier == "plan-only"`, source
one numbered step per non-empty acceptance item from `plan.md` `## Acceptance criteria` (the
lightweight planning lane's authoritative test source). Only when neither a `stories.json`
nor a populated plan-only `## Acceptance criteria` section exists, derive steps from the
changed code's public interface and the commit messages.

## Breaking Changes

Scan the diff for:
- Removed or renamed public methods, endpoints, or exports
- Changed method signatures (added required parameters, changed return type)
- Database schema changes that require migration (column drops, type changes, NOT NULL additions)
- Changed environment variable names or required config keys
- Modified shared DTO or contract types consumed by other services

If any found: check `Yes` and write a migration path (what callers must change, in what order).
If none found: check `No`. Do not write "None detected" — just check the box.

## Links Section

| Situation                                                  | What to write                                                                                                                |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| GitHub issue reference provided (`GH#42`)                  | `Closes #42` or `Fixes #42` (embed in PR body before creating)                                                               |
| `specs/<slug>/created-issues.json` present and schema-valid | One `Closes #N` per artifact entry in artifact order; dedupe against any user-supplied `GH#N` (artifact wins ties)            |
| Artifact malformed or schema-invalid                       | Skip injection; log `[build-create-pr] WARNING: ... — continuing without Closes injection`; never block PR creation          |
| No reference                                               | `N/A`                                                                                                                        |

## AI-Assisted Checklist

Always pre-check these three for makato-build sessions:
- [x] Code implementation
- [x] Commit messages
- [x] PR description

## PR Checklist — Pre-checkable Items

Check these if verifiably true:
- [x] PR title follows conventional commits — always true if you wrote the title
- [x] Skills are self-contained — always true if validation passed
- [x] CHANGELOG updated — check `CHANGELOG.md` diff to confirm
- [x] Version bumped — check if `SKILL.md` frontmatter version was incremented
- [x] Tested on local environment — only check if the implementing agent actually ran the gates in `/verify`

Leave unchecked if not verified. Do not pre-check items you cannot confirm.

## Cross-Plugin Contract — `created-issues.json`

The handoff artifact this skill reads is produced by `/makato-plan:to-issues` (v3.0.0+). Its shape is defined by `plugins/makato-plan/skills/to-issues/references/created-issues.schema.json` — when changing this skill's parsing logic, validate against that schema rather than duck-typing the file.
