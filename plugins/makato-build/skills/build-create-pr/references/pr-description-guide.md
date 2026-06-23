# PR Description Guide

## PR Title

Format: `type(scope): description` — conventional commit style, ≤72 chars total.

- **type**: `feat` for new story implementation; `fix` if the story corrects a defect; `refactor` if no new behavior
- **scope**: the primary module, service, or component touched (e.g. `invoice`, `auth`, `deals-view`)
- **description**: imperative, no period — what the PR delivers, not what files changed

Derive from `stories.json` story title or the first line of `plan.md`. If neither exists, synthesize from the commit messages.

## Description of Changes — What Changed

One bullet per completed plan task. Each bullet: task title + one sentence on the specific change.

**Good:** `- Add status field to Invoice entity — new `status` column in schema, mapped via JPA`
**Vague:** `- Updated Invoice` or `- Backend changes`

If no `plan.md` exists, derive from commit messages: one bullet per commit.

## Goal Alignment

Three lines:
1. Plugin name: `daff-<name>`
2. Goal: quote the plugin's goal statement from `AGENTS.md`
3. Alignment: one sentence explaining how this story advances that goal

## How to Test

One numbered step per acceptance criterion from `stories.json`. Each step must be concrete:
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

If no `stories.json` exists, derive steps from the changed code's public interface and the commit messages.

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

Always pre-check these three for daff-build sessions:
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
