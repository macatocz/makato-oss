---
name: seed-issue
description: >-
  Prepare a hand-filed GitHub issue for autonomous dispatch by the loop skill.
  Reads the issue, classifies it as new-work or change, stamps the to-issues
  provenance footer so _derive_key_for_issue can derive the KEY, adds the
  status:ready-for-dev label, moves the board card to Status=Ready, and
  (for new-work issues) creates a minimal specs/<N>-<slug>/ folder.
  Use for any issue that was filed manually — bypassing to-issues — and
  needs to enter the autonomous loop queue.
version: "1.1.0"
argument-hint: "<ISSUE_NUMBER> [--repo <owner/name>] [--type new-work|change]"
hooks:
  - "seed issue"
  - "prepare issue for loop"
  - "stamp provenance"
  - "hand-filed issue"
  - "manual issue to queue"
  - "bypass to-issues"
  - "seed-issue"
  - "make issue ready for dev"
  - "prime issue for autonomous dispatch"
---

<!-- markdownlint-disable MD013 -->

# seed-issue

> **Mission**: Stamp a hand-filed GitHub issue with the metadata the autonomous
> `loop` skill requires and move it to `Status=Ready` on the project board.
> Issues filed via `to-issues` already carry all of this; `seed-issue` does it
> for manual bypasses.

## When to Use

Use `seed-issue` when you have filed (or received) an issue directly on GitHub
without going through `to-issues`, and you want the `loop` skill to pick it up
for autonomous dispatch. Specifically:

- Issues filed from a template, Jira import, Slack-to-GitHub bridge, or any
  other path that bypasses the `to-issues` workflow.
- Issues where the loop logged `WARN — could not derive KEY for issue #N (no
  to-issues provenance in body)` and you want to fix that without re-filing.
- Issues where you want to manually trigger autonomous mode for a single item
  without running a full `to-issues` batch.

Do **not** use for issues that already have the `*Feature slug: ...` provenance
footer — they are ready; just move the board card to `Ready` via the GitHub UI
or `issue-to-project`.

## Prerequisites

- `gh` CLI authenticated for the target repo's host.
- `.claude/config.json` → `github_project` populated (run
  `/makato-plan:issue-to-project --init` once per repo). `seed-issue` reads
  `owner`, `number`, `host`, `project_node_id`, `status_field_id`, and the
  `options.ready` option ID from this block. If the block is absent the board
  step is skipped with a WARN and the skill still completes the label + body
  stamps.
- For `--type new-work`: the `specs/` directory must exist at repo root.

## Invocation

```bash
# Classify automatically (keyword matching), default repo
/makato-orchestrate:seed-issue 123

# Force type
/makato-orchestrate:seed-issue 123 --type new-work
/makato-orchestrate:seed-issue 123 --type change

# Explicit repo (when config.json has no repo or you're targeting a fork)
/makato-orchestrate:seed-issue 123 --repo macatocz/makato

# Skip board move (no project config)
/makato-orchestrate:seed-issue 123 --type change
```

## Process

### Step 0 — Parse arguments

Accept `<ISSUE_NUMBER> [--repo <owner/name>] [--type new-work|change]`.

- `ISSUE_NUMBER`: required, positive integer.
- `--repo <owner/name>`: optional. When absent, derive the repo from
  `gh repo view --json nameWithOwner --jq '.nameWithOwner'` at the repo root.
  If that also fails, exit with `HALT: MISSING_REPO`.
- `--type new-work|change`: optional. When absent, classify in Step 2.

### Step 1 — Fetch the issue

```bash
gh issue view "$ISSUE_NUMBER" \
  --repo "$REPO" \
  --json number,title,body,labels \
  --jq '{number: .number, title: .title, body: .body, labels: [.labels[].name]}'
```

Exit with `HALT: ISSUE_NOT_FOUND` if the `gh` call returns non-zero or the
response is empty.

Store: `ISSUE_NUMBER`, `ISSUE_TITLE`, `ISSUE_BODY`, `ISSUE_LABELS[]`.

### Step 2 — Classify type (when `--type` not given)

Check whether `status:ready-for-dev` already appears in `ISSUE_LABELS`. If it
does, and `--type` was not supplied, the issue may already be seeded. Continue
anyway — all subsequent steps are idempotent.

Keyword match against `ISSUE_TITLE` and the first 200 characters of
`ISSUE_BODY` (lowercased, combined):

**`type:change` keywords:** `fix`, `bug`, `patch`, `hotfix`, `regression`,
`defect`, `repair`, `correct`, `revert`, `tweak`, `update`, `adjust`,
`refactor`, `improve`, `enhance`, `cleanup`, `clean up`, `address`, `resolve`.

**`type:feature` (new-work) keywords:** `feat`, `feature`, `add`, `new`,
`implement`, `build`, `create`, `introduce`, `support`, `enable`, `migrate`,
`integrate`.

**Inference rules (in order):**

1. If only `type:change` keywords match → `INFERRED_TYPE=change`.
2. If only `type:feature` keywords match → `INFERRED_TYPE=new-work`.
3. If both or neither keyword set matches → type is ambiguous.

When type is **ambiguous** and the skill is running interactively, ask:

```
seed-issue: Could not classify issue #N — "{ISSUE_TITLE}" as new-work or change.
Which type applies?
  1) new-work  (new feature, capability, or milestone)
  2) change    (bug fix, refactor, enhancement to existing code)
Enter 1 or 2:
```

When running **autonomously** (`$MAKATO_HEADLESS=1` or `$AGENT_ID` is set) and
type is ambiguous, default to `new-work` and log:
`[seed-issue:auto] type ambiguous — defaulted to new-work`.

Set `ISSUE_TYPE` to the resolved value (`new-work` or `change`).

### Step 3 — Write the type label

Apply `type:feature` for `new-work`, `type:change` for `change`:

```bash
# new-work
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "type:feature"

# change
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "type:change"
```

If the label does not exist in the repo, create it first (idempotent):

```bash
# type:feature — blue
gh label create "type:feature" \
  --repo "$REPO" \
  --color "0075CA" \
  --description "New feature or capability" 2>/dev/null || true

# type:change — yellow
gh label create "type:change" \
  --repo "$REPO" \
  --color "FBCA04" \
  --description "Bug fix, refactor, or enhancement" 2>/dev/null || true
```

Log `[seed-issue] labeled #N with type:<label>`.

### Step 4 — Derive slug

```
SLUG = <ISSUE_NUMBER>-<normalized-title>
```

Where `<normalized-title>` is:

1. `ISSUE_TITLE` lowercased.
2. All non-alphanumeric characters replaced with `-`.
3. Runs of multiple `-` collapsed to a single `-`.
4. Leading and trailing `-` stripped.
5. Truncated at **40 characters** (whole words where possible — back off to the
   last `-` boundary within 40 chars; if no boundary exists within 40 chars,
   hard-truncate at 40 and strip any trailing `-`).

Example: `"Fix: loop dispatch fails on empty KEY"` →
`fix-loop-dispatch-fails-on-empty-key` → prefixed: `123-fix-loop-dispatch-fails-on-empty` (truncated at 40).

Store as `SLUG`.

### Step 5 — Stamp the to-issues provenance footer

The `loop` skill's `_derive_key_for_issue` function looks for:

```
*Feature slug: `<slug>` — produced by to-issues v3.x.*
```

as a footer line in the issue body. `seed-issue` writes the same format so the
loop can derive `KEY = SLUG` without modification.

**Check for existing provenance first.** Grep `ISSUE_BODY` for the pattern
`Feature slug:`. If found, log:
`[seed-issue] provenance footer already present — skipping body update`
and skip the body write.

**If absent**, append the provenance footer to the issue body:

```bash
NEW_BODY="$(printf '%s\n\n---\n\n*Feature slug: `%s` — produced by to-issues v3.x (seeded by seed-issue v1.1.0).*' \
  "$ISSUE_BODY" "$SLUG")"

gh issue edit "$ISSUE_NUMBER" \
  --repo "$REPO" \
  --body "$NEW_BODY"
```

Log `[seed-issue] stamped provenance footer on #N (slug: $SLUG)`.

### Step 6 — Add `status:ready-for-dev` label

This label is the passive stamp that downstream tooling (loop, issue-to-project
v2.8+ autonomous path) can grep without reading the board.

**Note:** `issue-to-project` v2.8+ stamps this label automatically for issues
auto-promoted via `ready_queue_mode: "autonomous"`. `seed-issue` stamps it here
for the manual bypass path — the label means the same thing in both cases.

```bash
# Create if absent (idempotent)
gh label create "status:ready-for-dev" \
  --repo "$REPO" \
  --color "0075CA" \
  --description "Issue is ready for autonomous dispatch" 2>/dev/null || true

# Stamp
gh issue edit "$ISSUE_NUMBER" \
  --repo "$REPO" \
  --add-label "status:ready-for-dev"
```

Log `[seed-issue] stamped status:ready-for-dev on #N`.

### Step 7 — Move board card to Status=Ready

Read `.claude/config.json` from the repo root. Parse the `github_project` block.

**If the block is absent or `project_node_id` / `status_field_id` /
`options.ready` are missing**, log:
`[seed-issue] WARN: .claude/config.json has no github_project config — skipping board move. Run /makato-plan:issue-to-project --init to configure.`
and skip to Step 8.

**Otherwise:**

1. Find the board item ID for this issue:

   ```bash
   ITEM_ID="$(gh --hostname "$HOST" project item-list "$PROJECT_NUMBER" \
     --owner "$OWNER" \
     --format json \
     --limit 9999 \
     --jq ".items[] | select(.content.number == $ISSUE_NUMBER) | .id" 2>/dev/null \
     | head -1)"
   ```

   If `ITEM_ID` is empty, the issue is not yet on the board. Add it first:

   ```bash
   ISSUE_URL="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json url --jq '.url')"
   ITEM_ID="$(gh --hostname "$HOST" project item-add "$PROJECT_NUMBER" \
     --owner "$OWNER" \
     --url "$ISSUE_URL" \
     --format json \
     --jq '.id' 2>/dev/null)"
   ```

   If the add fails, log:
   `[seed-issue] WARN: could not add #N to board — skipping Status write`
   and skip the item-edit call.

2. Set Status=Ready:

   ```bash
   gh --hostname "$HOST" project item-edit \
     --project-id "$PROJECT_NODE_ID" \
     --id "$ITEM_ID" \
     --field-id "$STATUS_FIELD_ID" \
     --single-select-option-id "$READY_OPTION_ID"
   ```

   On failure, log:
   `[seed-issue] WARN: could not set Status=Ready on board item $ITEM_ID — check gh auth and project scope`
   and continue (the label stamp and provenance footer are already written;
   the issue can be manually moved on the board).

   On success, log: `[seed-issue] moved #N to Status=Ready on board`.

### Step 8 — Create spec folder (new-work only)

For `ISSUE_TYPE=change`, skip this step entirely — change issues do not need a
spec folder.

For `ISSUE_TYPE=new-work`:

Create `specs/$SLUG/` with two files:

**`specs/$SLUG/plan.md`** — minimal stub:

```markdown
# Plan: <ISSUE_TITLE>

> Auto-seeded by seed-issue v1.1.0 on <ISO_DATE>. Replace this stub with a
> full plan before the PO-agent starts.

## Issue

[#<ISSUE_NUMBER>](https://github.com/<REPO>/issues/<ISSUE_NUMBER>)

## Acceptance criteria

_To be filled in. The PO-agent will HALT with HALT-006 (MISSING_SPEC) if
this file contains only the stub text above._
```

**`specs/$SLUG/seed-manifest.json`** — machine-readable seed record:

```json
{
  "schema_version": "2",
  "seeded_at": "<ISO_DATETIME>",
  "seeded_by": "seed-issue",
  "skill_version": "1.1.0",
  "issue_number": <ISSUE_NUMBER>,
  "issue_title": "<ISSUE_TITLE>",
  "slug": "<SLUG>",
  "repo": "<REPO>",
  "type": "new-work"
}
```

**`seed-manifest.json` schema (v2):**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | string | yes | `"2"` for manifests written by seed-issue v1.1.0+; `"1"` for legacy manifests without `spec_tier` |
| `seeded_at` | string (ISO-8601) | yes | Timestamp the manifest was written |
| `seeded_by` | string | yes | Always `"seed-issue"` |
| `skill_version` | string | yes | seed-issue version that wrote the manifest |
| `issue_number` | integer | yes | GitHub issue number |
| `issue_title` | string | yes | Issue title at seed time |
| `slug` | string | yes | `<ISSUE_NUMBER>-<normalized-title>` |
| `repo` | string | yes | `owner/name` of the target repo |
| `type` | string | yes | `"new-work"` or `"change"` |
| `spec_tier` | string | **optional** | `"plan-only"` marks the item for the lightweight planning lane — `build-refine` sources acceptance criteria from `plan.md` `## Acceptance criteria` instead of `stories.json`. **Absent → legacy behavior, byte-for-byte** (build-refine routes by KEY prefix only). Written only by the `plan-tier:light` path (light-planner integration, tracked separately); the default `new-work` path in this step leaves it absent. |

**Schema evolution — v1 → v2:** v2 adds the single optional `spec_tier` field. The change
is fully backwards-compatible: a v1 manifest (no `spec_tier`) and a v2 manifest with
`spec_tier` absent are treated identically by every consumer (`build-refine` reads
`.spec_tier // ""` and falls back to legacy KEY-prefix routing). Bump `schema_version` to
`"2"` whenever the manifest is written by a version of seed-issue that understands the
`spec_tier` field, regardless of whether the field is actually set.

Log: `[seed-issue] created specs/$SLUG/ with plan.md stub and seed-manifest.json (schema_version 2)`.

If `specs/$SLUG/` already exists, skip creation and log:
`[seed-issue] specs/$SLUG/ already exists — skipping folder creation`.

### Step 9 — Print confirmation summary

```
[seed-issue] Done — issue #N is ready for autonomous dispatch.

  Issue   : #N — <ISSUE_TITLE>
  Repo    : <REPO>
  Type    : <ISSUE_TYPE>
  Slug    : <SLUG>
  Labels  : type:<label>, status:ready-for-dev (stamped)
  Footer  : provenance footer stamped (or already present)
  Board   : Status=Ready (or WARN if board move skipped)
  Spec    : specs/<SLUG>/ created (new-work) / not needed (change)

Next: start the loop or run 'loop dispatch <N>' to dispatch immediately.
```

## HALT codes

| Code | Condition | Exit |
|------|-----------|------|
| `MISSING_ISSUE_NUMBER` | No issue number provided as first argument | 1 |
| `ISSUE_NOT_FOUND` | `gh issue view` returned non-zero or empty body | 1 |
| `MISSING_REPO` | `--repo` not given and `gh repo view` fails | 1 |
| `INVALID_TYPE` | `--type` supplied with a value other than `new-work` or `change` | 1 |

Every nonzero exit prints `HALT: <CODE>` as the final stdout line.

## Idempotency

All steps are idempotent:

- `gh label create` is wrapped with `|| true` — no-op when the label exists.
- `gh issue edit --add-label` is a no-op at the GitHub API level when the
  label is already on the issue.
- Provenance footer stamp is skipped when the footer is already present.
- Board `item-edit` to `Ready` is safe to repeat — GitHub Projects accepts
  re-writing the same option value.
- Spec folder creation is guarded with an existence check.

Running `seed-issue` twice on the same issue produces the same final state.

## Relationship to `issue-to-project` autonomous path

`issue-to-project` v2.8+ stamps `status:ready-for-dev` automatically when
`ready_queue_mode: "autonomous"` is set and it auto-promotes a `Todo` item to
`Ready`. That is the primary production path for issues filed via `to-issues`.

`seed-issue` covers the manual bypass path — issues filed directly on GitHub
that need the same stamps applied by hand. The label has the same meaning in
both cases: the issue has been reviewed, a slug has been assigned, and the loop
may dispatch it.

## Tracking

This skill is part of the fix/loop-po-agent-contract improvement, addressing
the gap where hand-filed issues caused `loop` to log a KEY derivation WARN and
dispatch with an empty KEY, causing the PO-agent to fail input validation
immediately.
