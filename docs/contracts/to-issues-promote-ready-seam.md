# Contract: to-issues → promote-ready.sh file-format seam

> **Seam** from the suite feature audit
> (`docs/makato-feature-audit.md` → Cross-plugin integration seams).
>
> This document is the authoritative reference for the boundary between
> `plugins/makato-plan/skills/to-issues` (producer) and
> `plugins/makato-orchestrate/scripts/promote-ready.sh` (consumer).
> It contains no code duplication — all implementation details reference the
> single source of truth in each component. (issue #718)

---

## 1 — Shared file format: `created-issues.json`

**Schema:** `plugins/makato-plan/skills/to-issues/references/created-issues.schema.json`

The file is written by `to-issues` into `specs/<slug>/created-issues.json`.
`promote-ready.sh` reads it via `_collect_graph_files` + `_compute_plan`.

### Top-level shape

| Field            | Type     | Required | Description                                         |
|------------------|----------|----------|-----------------------------------------------------|
| `schema_version` | `"1"`    | yes      | Schema version; bump on breaking changes            |
| `slug`           | string   | yes      | Kebab-case feature slug (spec folder suffix)        |
| `target_repo`    | string   | no       | `owner/repo` when cross-repo; absent for same-repo  |
| `issues`         | array    | yes      | One entry per created GitHub issue                  |

### Issue entry shape (items in `issues[]`)

| Field          | Type          | Required | Description                                                  |
|----------------|---------------|----------|--------------------------------------------------------------|
| `issue_number` | integer ≥ 1  | yes      | GitHub issue number                                          |
| `url`          | string (URI)  | yes      | Full `https://github.com/…/issues/<N>` URL                   |
| `title`        | string        | yes      | Issue title as created on GitHub                             |
| `labels`       | string[]      | yes      | Flat `dimension:value` label list                            |
| `blocked_by`   | integer[]     | yes      | Issue numbers of upstream blockers (empty `[]` = no blockers) |
| `milestone`    | object\|null  | no       | GitHub milestone object `{title, due_on}`; absent = no milestone |

---

## 2 — Producer: `to-issues`

**Skill:** `plugins/makato-plan/skills/to-issues/SKILL.md`

`to-issues` creates or updates GitHub issues from a shaped `stories.json`
and writes `created-issues.json` as a machine-readable handoff.

### Fields that cross the seam boundary

These fields are read back by `promote-ready.sh` and must not be changed
without updating both the producer and consumer:

| Field                       | Purpose in consumer                                         |
|-----------------------------|-------------------------------------------------------------|
| `issues[].issue_number`     | Node identity in the dependency graph; matched against board items |
| `issues[].blocked_by[]`     | Directed edge list — entry N blocks the issue that lists it |
| `issues[].url`              | Used by `_promote_one` to add an off-board issue via `gh project item-add` |

### `blocked_by[]` type contract

Every entry in `blocked_by[]` must be a **positive integer** (real GitHub
issue number). `to-issues` derives these from the upstream story's
`dependencies.blockedBy` sequence numbers by translating each sequence to
the `githubIssue` number assigned when the story was filed.

The JSON Schema enforces `items: { type: integer, minimum: 1 }`. Entries that
do not match this shape are silently dropped by `promote-ready.sh`'s
`load_created` parser (`isinstance(b, int)` filter), causing the dependent
issue to appear unblocked when it should remain blocked. See §5 (Known gaps).

---

## 3 — Consumer: `promote-ready.sh`

**Script:** `plugins/makato-orchestrate/scripts/promote-ready.sh`

### Reading the seam file

`_collect_graph_files [SLUG]` (lines 135–167):
- Prefers `specs/<slug>/created-issues.json` over `stories.json`.
- Accepts an exact folder name or a slug suffix.

`load_created` (inside `_compute_plan`, lines 234–252):
- Loads `issues[]` entries where `issue_number` is an integer.
- Builds `blocked_by` as a set of integers (filters non-integers).
- Non-integer `issue_number` entries are skipped entirely (not counted in graph size).

### Board status lookup

Board status is read from `MAKATO_PROMOTE_GH_OVERRIDE` (tests) or
`gh project item-list --format json` (live). The `status` field is
normalized to lowercase for comparison.

Statuses that block promotion (forward-only guard):

| Status (normalized) | Behaviour |
|---------------------|-----------|
| `done`              | Predecessor counts as resolved; does NOT block downstream |
| `ready`             | Issue is already promoted; skipped |
| `in progress`       | Issue is already progressing; skipped |
| `in review`         | Issue is already progressing; skipped |
| `todo` or `blocked` | Eligible for promotion if all predecessors are Done |
| `""` (off-board)    | Eligible for promotion if all predecessors are Done |

### Dependency resolution (conservative contract)

An issue in `blocked_by[]` is considered resolved **only if its board status
is `"done"`**. Off-board or unknown predecessors count as NOT done and keep
the dependent issue blocked. This is the conservative contract:

> Unknown predecessors still block.

This rule applies to both `created-issues.json` (resolved via `blocked_by[]`
integers) and `stories.json` (translated via `sequence → githubIssue` — see
`load_stories`). An unresolved story blocker (no `githubIssue`) is recorded
in `node.unresolved[]` and keeps the dependent issue blocked even though no
integer is in `blocked_by`.

---

## 4 — Test hooks (offline testing)

All seam tests must be fully offline. The following environment variables
eliminate network calls:

| Variable                         | Purpose                                                                |
|----------------------------------|------------------------------------------------------------------------|
| `MAKATO_PROMOTE_SPECS_DIR`       | Override `specs/` directory root                                       |
| `MAKATO_PROMOTE_GH_OVERRIDE`     | Path to a JSON file holding the canned board payload; `gh` not invoked |
| `MAKATO_PROMOTE_EDIT_TEST_FILE`  | Append each intended promotion to this file instead of calling `gh`    |
| `MAKATO_PROMOTE_CONFIG`          | Override `.claude/config.json` path                                    |

**Board JSON shape** (mirrors `gh project item-list --format json`):

```json
{
  "items": [
    {
      "id": "PVTI_<node-id>",
      "content": { "type": "Issue", "number": 42 },
      "status": "Done"
    }
  ]
}
```

`content.type` must be `"Issue"` for the item to be counted.
`content.number` must be an integer for the item to be matched to a graph node.

---

## 5 — Known gaps (regression guards)

### Gap A — Non-integer `blocked_by` entries are silently dropped

**Severity:** high (silent wrong-promotion risk)

When a `blocked_by[]` entry is not an integer (e.g. a string like `"abc"`
from a malformed `to-issues` run or a manual edit), `promote-ready.sh`'s
`load_created` parser drops the entry silently. The dependent issue then has
an empty effective `blocked_by` set and is promoted as if it has no blockers.

**Current behavior (locked in by regression test `test_non_integer_blocked_by_is_not_silently_promoted`):**
- Non-integer entry → dropped → issue appears in `ready[]` as unblocked.

**Fix direction:** Add schema validation in `load_created` that appends a
`warnings[]` entry for any non-integer `blocked_by` element and records it as
an unresolved blocker (same as `load_stories` does for unfiled story blockers).
When the fix lands, update the regression test to assert the issue appears in
`blocked[]` or `warnings[]` instead.

### Gap B — `blocked_by` referencing a missing issue is conservatively blocking

**Severity:** low (correct behavior, documented here for clarity)

When `blocked_by` references an issue number that does not appear in the
loaded graph (e.g. a cross-epic dependency not listed in this `created-issues.json`),
`is_done(pred)` returns `False` (off-graph predecessors are not Done by default).
The dependent issue stays in `blocked[]` with the missing number in
`pending_blockers`. This is the correct conservative contract.

**Regression test:** `test_missing_issue_reference_in_blocked_by_keeps_issue_blocked`

---

## 6 — Integration test location

Seam contract tests live at:

```
tests/test_to_issues_promote_ready_seam.py
```

They use `pytest` with `tmp_path` fixtures, subprocess invocation of
`promote-ready.sh plan --json`, and the offline environment variables from §4.
No network access, no `gh` invocations, no board mutations.
