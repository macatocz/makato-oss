<!-- markdownlint-disable MD013 -->
# `sync-lifecycle` — 5-step flow

Pre-flight checks 1–4 from SKILL.md run first. This file picks up after they pass and the slug has been resolved (argv positional or most-recently-modified `specs/*/project-sync.json`).

## Pre-flight (same 4 checks as v1)

See SKILL.md Step 0. All four checks run before any file read or network call. On failure: exit 1, HALT `PREFLIGHT_FAILED`.

## Step 1 — Read and validate config

Identical to `sync-process.md` Step 1. Read `.claude/config.json`, validate the `github_project` block, assert required keys and ID-format prefixes. Additionally, read the optional `include_draft_prs` key:

```python
include_draft_prs = gp.get("include_draft_prs", True)   # default True (D6)
```

`include_draft_prs` is optional; its absence is NOT a `MALFORMED_CONFIG`. Missing → default `True`.

## Step 2 — Read input (`project-sync.json`)

`sync-lifecycle` reads the prior `project-sync.json` (the v1/v1.1/v1.2/v2 artifact), not `created-issues.json`.

```python
import json, pathlib, sys

input_path = pathlib.Path(f"specs/{slug}/project-sync.json")
if not input_path.exists():
    sys.exit(
        f"issue-to-project sync-lifecycle: no project-sync.json found at specs/{slug}/. "
        f"Run 'issue-to-project {slug}' first.\nHALT: MISSING_INPUT"
    )

prior = json.loads(input_path.read_text())
```

**Schema version validation:** `schema_version` must be one of `"1"`, `"1.1"`, `"1.2"`, or `"2"`. Any other value → exit 1, HALT `MALFORMED_INPUT`: `"issue-to-project sync-lifecycle: project-sync.json has unrecognized schema_version '<value>'. This reader supports versions 1, 1.1, 1.2, and 2."`.

```python
SUPPORTED = {"1", "1.1", "1.2", "2"}
if prior.get("schema_version") not in SUPPORTED:
    sys.exit(
        f"issue-to-project sync-lifecycle: project-sync.json has unrecognized "
        f"schema_version '{prior.get('schema_version')}'. "
        f"This reader supports versions 1, 1.1, 1.2, and 2.\nHALT: MALFORMED_INPUT"
    )

input_results = prior.get("results", [])
```

Note: if `schema_version` is already `"2"` (the artifact was already upgraded by a prior `sync-lifecycle` run), proceed normally — no special handling needed.

## Step 3 — Snapshot the board

Identical to `sync-process.md` Step 3. Run `gh project item-list` to build `snapshot` dict keyed by issue URL with `{"projectItemId": ..., "currentStatusName": ...}`.

```bash
SNAPSHOT_RAW="$(GH_HOST=github.com timeout "${ITP_GH_TIMEOUT_SECONDS:-30}" \
  gh project item-list "$NUMBER" --owner "$OWNER" --format json --limit 9999 2>&1)" || {
    echo "issue-to-project: item-list failed/timed-out: $SNAPSHOT_RAW" >&2
    echo "HALT: SNAPSHOT_FAILED"
    exit 1
}
```

Build snapshot dict from response. Guard against draft items with no `content` block (same as `sync-process.md`).

## Step 4 — Determine target Status and (conditionally) write

For each entry in `input_results`:

### 4.1 — Look up the issue in the board snapshot

```python
issue_url = row["url"]
snapshot_entry = snapshot.get(issue_url)
```

If `issue_url` is not in the snapshot: the issue was never added to the board (or was deleted). Record `outcome: "lifecycle_lookup_failed"`, `error: "issue not found in board snapshot"`, no write. Continue.

### 4.2 — Apply the precedence rule (D5)

```python
current_board_status = snapshot_entry["currentStatusName"]
last_written_status  = row.get("final_status")   # may be None for add_failed rows
```

If `current_board_status != last_written_status`:
- The item was externally touched since the last skill-written state.
- Record `outcome: "lifecycle_skipped_externally_set"`.
- Emit: `[issue-to-project:auto] issue #<N>: Status externally set to '<current_board_status>' — skipping lifecycle transition`
- No write. Continue.

**Edge case — `last_written_status` is `null`** (e.g. `add_failed` rows): treat as externally owned from the start. Record `outcome: "lifecycle_skipped_externally_set"`.

**Edge case — issue in board snapshot but not in `project-sync.json`:** treat `last_written_status` as `null` → `outcome: "lifecycle_skipped_externally_set"`.

### 4.3 — Query GitHub for linked PRs (GraphQL)

```python
import re

# Extract issue number from URL (e.g. "https://github.com/owner/repo/issues/47" → 47)
match = re.search(r"/issues/(\d+)$", issue_url)
issue_number = int(match.group(1))

# Extract owner and repo from URL
parts = issue_url.rstrip("/").split("/")
# parts[-4] = owner, parts[-3] = repo
gh_owner = parts[-4]
gh_repo  = parts[-3]
```

GraphQL query (one call per issue, sequential — D8):

```graphql
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      closingPullRequests(first: 20) {
        nodes {
          url
          state
          isDraft
          mergedAt
        }
      }
    }
  }
}
```

```bash
GQL_RESULT="$(GH_HOST=github.com timeout "${ITP_GH_TIMEOUT_SECONDS:-30}" \
  gh api graphql \
    -f query='query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        issue(number: $number) {
          closingPullRequests(first: 20) {
            nodes { url state isDraft mergedAt }
          }
        }
      }
    }' \
    -F owner="$GH_OWNER" \
    -F repo="$GH_REPO" \
    -F number="$ISSUE_NUMBER" 2>&1)"
```

If the call fails (non-zero exit or error JSON):
- Log: `[issue-to-project] WARN: issue #<N>: PR lookup failed: <error>`
- Record `outcome: "lifecycle_lookup_failed"`, `linked_pr_url: null`, `linked_pr_state: null`, `error: "<error>"`.
- Continue to next issue.

Parse `pr_nodes` from `.data.repository.issue.closingPullRequests.nodes`. If parsing fails, treat as lookup failure (soft-warn, same as above).

### 4.4 — Apply PR selection rule (D3)

```python
def select_governing_pr(pr_nodes, include_draft_prs):
    """Return (governing_pr, target_status) or (None, None) if no actionable PR."""
    merged = [pr for pr in pr_nodes if pr["state"] == "MERGED"]
    if merged:
        # Pick most recently merged
        governing = max(merged, key=lambda pr: pr["mergedAt"] or "")
        return governing, "Done"

    open_prs = [
        pr for pr in pr_nodes
        if pr["state"] == "OPEN" and (include_draft_prs or not pr["isDraft"])
    ]
    if open_prs:
        # Pick most recently updated (use url as stable tiebreaker when mergedAt absent)
        governing = open_prs[0]   # gh returns in updated_at desc order by default
        return governing, "In Progress"

    # All are CLOSED (unmerged) or all are drafts with include_draft_prs=False
    closed = [pr for pr in pr_nodes if pr["state"] == "CLOSED"]
    if closed or pr_nodes:
        return pr_nodes[0] if pr_nodes else None, "pr_closed_no_change"

    return None, None
```

**Multiple-PR logging (D3):**

When more than one PR is returned, emit one line at `[issue-to-project:auto]` level:
```
[issue-to-project:auto] issue #<N>: <M> linked PRs found; governing PR: <url> (state: <state>)
```

**`include_draft_prs` check (D6):**
- If `include_draft_prs == False` and the only open PR is a draft: treat as "no open PR" — fall through to closed/no-change path.
- If `include_draft_prs == True` (default): draft PRs count as open (`In Progress`).

### 4.5 — Determine outcome and (conditionally) write

| Condition | `outcome` | `linked_pr_state` | Write? |
|---|---|---|---|
| No PRs returned (empty `pr_nodes`) | `pr_closed_no_change` | `"null"` (string) | No |
| Governing PR is `MERGED` | `pr_merged_set_done` | `"merged"` | Yes, if `target_status ≠ current_board_status` |
| Governing PR is `OPEN` (non-draft, or draft + `include_draft_prs: true`) | `pr_opened_set_in_progress` | `"open"` | Yes, if `target_status ≠ current_board_status` |
| All PRs `CLOSED` (unmerged) | `pr_closed_no_change` | `"closed"` | No |
| Lookup failed | `lifecycle_lookup_failed` | `null` | No |
| Externally set (precedence rule) | `lifecycle_skipped_externally_set` | _(from prior row if available, else null)_ | No |

**Write (item-edit):**

```bash
GH_HOST=github.com timeout "${ITP_GH_TIMEOUT_SECONDS:-30}" \
  gh project item-edit \
    --id "$PROJECT_ITEM_ID" \
    --project-id "$PROJECT_NODE_ID" \
    --field-id "$STATUS_FIELD_ID" \
    --single-select-option-id "$TARGET_OPTION_ID" 2>&1
```

`TARGET_OPTION_ID` is `gp["options"]["in_progress"]` for `In Progress` and `gp["options"]["done"]` for `Done`.

If `item-edit` fails:
- Log: `[issue-to-project] WARN: issue #<N>: lifecycle status edit to '<Status>' failed: <error>`
- Record the governing-transition `outcome` (e.g. `pr_opened_set_in_progress`) with `error` populated.
- Do NOT set `needs_status_retry: true` (that flag is reserved for v1 Blocked-edit failures).
- Continue to next issue.

If `item-edit` times out: treat as edit failure (soft-warn, record error, continue).

**Dry-run (DRY_RUN=1 or `--dry-run` flag; flag takes precedence):**

Skip all `item-edit` calls. Record `outcome: "dry_run"` for every row that would have received a lifecycle write. `cli_command` is populated with the literal `item-edit` command for inspection. Step 5 still writes the artifact; exit 0.

When both `DRY_RUN=1` (env) and `--dry-run` (flag) are present, `--dry-run` wins. When only `DRY_RUN=1` is set (env), honor it. No `--dry-run` flag without `sync-lifecycle` subcommand; the flag is not recognized on normal-run or retry paths.

**Batch-wide GraphQL abort (D10):**

After processing all issues: if EVERY issue resulted in `outcome: "lifecycle_lookup_failed"` (no successful GraphQL call in the entire batch), write the artifact with all `lifecycle_lookup_failed` outcomes, then exit 1 with HALT `LIFECYCLE_LOOKUP_FAILED`:
```
issue-to-project sync-lifecycle: GraphQL PR-lookup failed for every issue. Check gh auth and network, then retry.
HALT: LIFECYCLE_LOOKUP_FAILED
```

If at least one issue was successfully processed (even if its outcome was `pr_closed_no_change` or `lifecycle_skipped_externally_set`), the batch-wide HALT does NOT fire. The partial-failure case is `status: "partial"` (exit 0).

## Step 5 — Write artifact (schema_version: 2, with `.bak`)

### 5.1 — Write `.bak` (soft-warn on failure)

Before overwriting `project-sync.json`, copy the current file to `project-sync.v1.bak.json` (one generation only — subsequent v2 runs overwrite the `.bak` file):

```python
import shutil

bak_path = pathlib.Path(f"specs/{slug}/project-sync.v1.bak.json")
try:
    shutil.copy2(input_path, bak_path)
    print(f"[issue-to-project] Backed up prior artifact to {bak_path}")
except OSError as e:
    print(f"[issue-to-project] WARN: could not write project-sync.v1.bak.json: {e}")
    # Continue — the .bak is a convenience, not required
```

### 5.2 — Build and validate the v2 artifact

```python
import datetime, jsonschema, json, os, pathlib

LIFECYCLE_OUTCOMES = {
    "pr_opened_set_in_progress",
    "pr_merged_set_done",
}
LOOKUP_FAILED_OUTCOMES = {"lifecycle_lookup_failed"}
SKIPPED_OUTCOMES = {"lifecycle_skipped_externally_set"}

def count_outcome(results, outcome_set):
    return sum(1 for r in results if r["outcome"] in outcome_set)

artifact = {
    "schema_version": "2",
    "slug": slug,
    "run_timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "skill_version": "2.0.0",
    "retry_source": None,
    "project": {
        "owner": gp["owner"], "number": gp["number"], "url": gp["url"],
    },
    "summary": {
        # v1 keys (preserved, 0 for add/edit counts not applicable in sync-lifecycle)
        "issues_in_input":            len(input_results),
        "already_on_board":           len(input_results),   # all input rows are assumed on board
        "added":                      0,
        "set_todo":                   0,
        "set_in_progress":            count_outcome(results, {"pr_opened_set_in_progress"}),
        "set_blocked":                0,
        "set_done":                   count_outcome(results, {"pr_merged_set_done"}),
        "left_default":               0,
        "add_failed":                 0,
        "edit_failed":                0,
        "dry_run":                    count_outcome(results, {"dry_run"}),
        "skipped_after_total_failure":0,
        "retry_attempted":            0,
        "retry_succeeded":            0,
        "retry_failed":               0,
        "retry_item_gone":            0,
        # v2 keys (new)
        "set_in_progress":            count_outcome(results, {"pr_opened_set_in_progress"}),
        "set_done":                   count_outcome(results, {"pr_merged_set_done"}),
        "lifecycle_lookup_failed":    count_outcome(results, LOOKUP_FAILED_OUTCOMES),
        "lifecycle_skipped":          count_outcome(results, SKIPPED_OUTCOMES),
    },
    "results": results,
}
```

Note: `set_in_progress` and `set_done` appear in both the v1 key block and the explicit v2 assignment above; the last assignment wins in Python dict literals — this is intentional to make both the v1 and v2 meanings clear for readers of this doc.

Validate with `project-sync.schema.json` (same as `sync-process.md`). If validation fails: exit 1, HALT `AUDIT_SCHEMA_FAILED`.

### 5.3 — Atomic overwrite

```python
out = pathlib.Path(f"specs/{slug}/project-sync.json")
out.parent.mkdir(parents=True, exist_ok=True)
tmp = out.with_suffix(".json.tmp")
try:
    tmp.write_text(json.dumps(artifact, indent=2) + "\n")
    os.replace(tmp, out)
except OSError as e:
    print(f"issue-to-project: project-sync.json write failed ({e}).", file=sys.stderr)
    print("HALT: AUDIT_WRITE_FAILED")
    sys.exit(1)
```

## Step 6 — Emit return format and handoff line

```python
lifecycle_lookup_failed_count = artifact["summary"]["lifecycle_lookup_failed"]
result = {
    "status": (
        "failed" if exit_code == 1 else
        "partial" if lifecycle_lookup_failed_count > 0 else
        "ok"
    ),
    "slug": slug,
    "artifact_path": f"specs/{slug}/project-sync.json",
    "issues_in_input":            artifact["summary"]["issues_in_input"],
    "already_on_board":           artifact["summary"]["already_on_board"],
    "added":                      0,
    "set_blocked":                0,
    "left_default":               0,
    "add_failed":                 0,
    "edit_failed":                0,
    "skipped_after_total_failure":0,
    "dry_run":                    artifact["summary"]["dry_run"],
    "set_in_progress":            artifact["summary"]["set_in_progress"],
    "set_done":                   artifact["summary"]["set_done"],
    "lifecycle_lookup_failed":    lifecycle_lookup_failed_count,
    "lifecycle_skipped":          artifact["summary"]["lifecycle_skipped"],
}
print(f"RESULT: {json.dumps(result, separators=(',', ':'))}")
print(f"Next: review specs/{slug}/project-sync.json; "
      "items with outcome lifecycle_skipped_externally_set were manually pinned and were not touched.")
```

If exiting non-zero, also print `HALT: <code>` as the final line (after the `Next:` line).

## Outcome values

| Value | When |
|---|---|
| `pr_opened_set_in_progress` | Governing PR is open (or draft if `include_draft_prs: true`); Status flipped to `In Progress` this run |
| `pr_merged_set_done` | Governing PR is merged; Status flipped to `Done` this run |
| `pr_closed_no_change` | Governing PR closed unmerged (or no PRs linked); Status unchanged (D4) |
| `lifecycle_skipped_externally_set` | Current Status ≠ last-written Status → item was externally touched; no write (D5) |
| `lifecycle_lookup_failed` | GraphQL call failed for this issue (per-item soft failure); Status unchanged |

## Error routing summary

| Failure mode | Severity | Action |
|---|---|---|
| `project-sync.json` missing for slug | **Abort** | HALT `MISSING_INPUT`, exit 1 |
| `project-sync.json` unsupported `schema_version` | **Abort** | HALT `MALFORMED_INPUT`, exit 1 |
| GraphQL fails for ALL issues (batch-wide) | **Abort** | Write artifact (all `lifecycle_lookup_failed`), HALT `LIFECYCLE_LOOKUP_FAILED`, exit 1 |
| GraphQL fails for a single issue (per-item) | **Soft-warn** | Log WARN, record `lifecycle_lookup_failed`, continue |
| `item-edit` fails after successful lookup | **Soft-warn** | Log WARN, record governing-transition outcome + `error`, continue |
| `item-edit` times out | **Soft-warn** | Treat as edit failure; record error, continue |
| `.bak` write fails | **Soft-warn** | Log WARN (`could not write project-sync.v1.bak.json: <errno>`), continue with main write |
| Schema validation fails on write | **Abort** | HALT `AUDIT_SCHEMA_FAILED`, exit 1 |
| All items `lifecycle_skipped_externally_set` | **Exit 0** | Normal success; all items pinned by humans |
