<!-- markdownlint-disable MD013 -->
# `--retry-blocked-edits` flow — 3 steps

Pre-flight checks 1–4 from SKILL.md run first. This file picks up after they pass and dispatch (SKILL.md Step 1) has identified the run as `--retry-blocked-edits`. The retry verb never invokes `references/sync-process.md` — it does NOT snapshot the board, NOT call `item-add`, and NOT touch `created-issues.json`. The prior `project-sync.json` is the only input.

## Step 1 — Read and validate config

Same as normal-run Step 1 in `sync-process.md`. The retry verb writes against `gp["project_node_id"]`, `gp["status_field_id"]`, and `gp["options"]["blocked"]` — the same three IDs `sync-process.md` uses for the v1 `item-edit` to Blocked.

```python
import json, pathlib, sys
config = json.loads(pathlib.Path(".claude/config.json").read_text())
gp = config.get("github_project")
if not gp:
    sys.exit("issue-to-project: 'github_project' block missing in .claude/config.json. "
             "Run 'issue-to-project --init' to set up project board sync.\nHALT: MISSING_CONFIG")

required = ["owner", "owner_type", "number", "url", "project_node_id",
            "status_field_id", "status_field_name", "options",
            "init_timestamp", "init_skill_version"]
for k in required:
    if k not in gp or gp[k] in ("", None):
        sys.exit(f"issue-to-project: 'github_project.{k}' missing or empty. Re-run --init.\nHALT: MALFORMED_CONFIG")

if not gp["project_node_id"].startswith("PVT_"):
    sys.exit("issue-to-project: project_node_id must start with 'PVT_'. Re-run --init.\nHALT: MALFORMED_CONFIG")
if not gp["status_field_id"].startswith("PVTSSF_"):
    sys.exit("issue-to-project: status_field_id must start with 'PVTSSF_'. Re-run --init.\nHALT: MALFORMED_CONFIG")
for k in ("todo", "in_progress", "done", "blocked"):
    if not gp["options"].get(k):
        sys.exit(f"issue-to-project: options.{k} missing or empty. Re-run --init.\nHALT: MALFORMED_CONFIG")
```

`init_skill_version` is not gated — stale config carrying `"1.0.0"` is fully compatible with the retry verb (the IDs the retry verb uses for `status:blocked` were already cached by v1.0.0 `--init`; the IDs for `status:in-progress` and `status:done` retries, introduced in v1.2, were also cached by v1.0.0 `--init`).

## Step 2 — Resolve the prior artifact

Three resolution modes, in order of precedence:

1. **`--from <path>`** — explicit path; use verbatim. Mutually exclusive with a positional slug (rejected at argv parse time).
2. **Positional slug** — `specs/<slug>/project-sync.json`.
3. **Auto-resolve** — glob `specs/*/project-sync.json`, pick the most recently modified. If two paths share identical mtime (within 1 ms), exit 1 with HALT `AMBIGUOUS_SLUG`: `"issue-to-project: multiple specs/*/project-sync.json files share the latest mtime — pass an explicit slug or --from path."`

```python
import argparse, glob, json, pathlib, sys
import jsonschema

# argparse setup (illustrative; the real argparse block lives in SKILL.md):
#   group = parser.add_mutually_exclusive_group()
#   group.add_argument("--init", action="store_true")
#   group.add_argument("--retry-blocked-edits", action="store_true", dest="retry")
#   parser.add_argument("--from", dest="from_path", default=None)
#   parser.add_argument("slug", nargs="?", default=None)

if args.from_path and args.slug:
    sys.exit("issue-to-project: --from and a positional slug are mutually exclusive — "
             "use one to identify the prior artifact.")
if args.from_path and not args.retry:
    sys.exit("issue-to-project: --from requires --retry-blocked-edits.")

if args.from_path:
    prior_path = pathlib.Path(args.from_path)
elif args.slug:
    prior_path = pathlib.Path(f"specs/{args.slug}/project-sync.json")
else:
    candidates = sorted(
        glob.glob("specs/*/project-sync.json"),
        key=lambda p: pathlib.Path(p).stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        sys.exit("issue-to-project: no specs/*/project-sync.json found. "
                 "Run 'issue-to-project <slug>' first to generate an artifact.\n"
                 "HALT: RETRY_SOURCE_MISSING")
    # Ambiguity check (D2 from the v1.1.0 spec)
    if len(candidates) >= 2:
        m0 = pathlib.Path(candidates[0]).stat().st_mtime
        m1 = pathlib.Path(candidates[1]).stat().st_mtime
        if abs(m0 - m1) < 0.001:
            sys.exit("issue-to-project: multiple specs/*/project-sync.json files share the "
                     "latest mtime — pass an explicit slug or --from path.\nHALT: AMBIGUOUS_SLUG")
    prior_path = pathlib.Path(candidates[0])

if not prior_path.exists():
    sys.exit(f"issue-to-project: no project-sync.json found at {prior_path}. "
             f"Run 'issue-to-project <slug>' first to generate an artifact.\n"
             f"HALT: RETRY_SOURCE_MISSING")
```

Validate the prior artifact against `references/project-sync.schema.json`:

```python
try:
    prior = json.loads(prior_path.read_text())
except json.JSONDecodeError as e:
    sys.exit(f"issue-to-project: prior artifact {prior_path} is not valid JSON: {e}\n"
             f"HALT: RETRY_SOURCE_MALFORMED")

schema = json.loads(pathlib.Path(
    "plugins/makato-plan/skills/issue-to-project/references/project-sync.schema.json"
).read_text())
try:
    jsonschema.validate(prior, schema)
except jsonschema.ValidationError as e:
    sys.exit(f"issue-to-project: prior artifact {prior_path} failed schema validation: "
             f"{e.message}\nHALT: RETRY_SOURCE_MALFORMED")

if int(prior["schema_version"].split(".")[0]) < 1:
    sys.exit(f"issue-to-project: prior artifact schema_version "
             f"'{prior['schema_version']}' is not supported by this skill version.\n"
             f"HALT: RETRY_SOURCE_MALFORMED")
# Accepts all 1.x and 2.x values through '2.7' (e.g. "1", "1.1", "1.2", "2", "2.1", …, "2.7").
# The forward-stable major-version check above (`int(...split(".")[0]) >= 1`) avoids the
# pre-existing v2.1 regression that the previous set-based gate caused by rejecting every
# v2.0+ artifact.  Add new major versions (3.x, …) here if the contract ever breaks.

# Resolve the slug for this retry run (re-use the prior's slug)
slug = prior["slug"]
```

Filter rows needing retry:

```python
needs_retry = [r for r in prior["results"] if r.get("needs_status_retry") is True]
forwarded = [r for r in prior["results"] if r.get("needs_status_retry") is not True]
```

**Zero-retry early exit.** If `needs_retry` is empty, skip Step 3 entirely and jump to artifact write (Step 4-equivalent below) with `retried_count: 0`, status `"ok"`, exit 0. Emit a log line: `[issue-to-project] retry: prior artifact {prior_path} has no rows needing retry — nothing to do; writing forwarded artifact.`

```
[issue-to-project] retry: resolved prior artifact: specs/<slug>/project-sync.json (<N> rows need retry)
```

## Step 3 — Replay `item-edit` for each row

For each row in `needs_retry`, issue exactly one `gh project item-edit` call. No back-off, no internal retry loop — one attempt per invocation (D9 from the v1.1.0 spec).

### Resolve the target options key per row

A `needs_status_retry: true` row in a v1.0/v1.1 prior artifact is always `added_blocked_edit_failed` (the only retryable outcome v1.0/v1.1 produced). In a v1.2 prior artifact the row may also be `added_in_progress_edit_failed` or `added_done_edit_failed`. The retry target is fixed by the row's `outcome`:

```python
RETRY_TARGET = {
    # v1.2 outcomes
    "added_blocked_edit_failed":          ("blocked",     "Blocked"),
    "added_in_progress_edit_failed":      ("in_progress", "In Progress"),
    "added_done_edit_failed":             ("done",        "Done"),
    # v2.7 outcomes (new)
    "added_ready_edit_failed":            ("ready",       "Ready"),
    "added_in_review_edit_failed":        ("in_review",   "In review"),
    "auto_promoted_ready_edit_failed":    ("ready",       "Ready"),
    # NOTE: auto_promoted_ready_edit_failed maps to ("ready", "Ready") — the same target as
    # label-driven Ready retry.  The autonomous-vs-manual distinction is lost on retry because
    # retry replays only the cached (option_key, option_name), regardless of original cause.
}

def target_for(row):
    """Return (options_key, status_name) for a needs_status_retry row, or raise."""
    outcome = row["outcome"]
    if outcome in RETRY_TARGET:
        return RETRY_TARGET[outcome]
    # Defensive: a retry_failed row from a prior retry run also carries needs_status_retry: true.
    # We can't infer the original target from `retry_failed` alone — fall back to inspecting
    # the row's labels via the same priority order used in sync-process.md's resolve_status_label.
    PRIORITY = [
        ("status:blocked",     "blocked",     "Blocked"),
        ("status:done",        "done",        "Done"),
        ("status:in-review",   "in_review",   "In review"),
        ("status:in-progress", "in_progress", "In Progress"),
        ("status:ready",       "ready",       "Ready"),
    ]
    for lbl, opt, name in PRIORITY:
        if lbl in row["labels"]:
            return (opt, name)
    # No status:* label — should not happen for a needs_status_retry row; treat as malformed input.
    raise RuntimeError(
        f"issue-to-project: cannot determine retry target for issue #{row['issue_number']} "
        f"(outcome={outcome!r}, labels={row['labels']!r})"
    )
```

### Edit invocation

```bash
EDIT_RAW="$(GH_HOST=github.com timeout "${ITP_GH_TIMEOUT_SECONDS:-30}" \
  gh project item-edit \
    --id "$PROJECT_ITEM_ID" \
    --project-id "$PROJECT_NODE_ID" \
    --field-id "$STATUS_FIELD_ID" \
    --single-select-option-id "$TARGET_OPTION_ID" 2>&1)"
EDIT_RC=$?
```

`$PROJECT_ITEM_ID` is the row's `project_item_id` from the prior artifact (guaranteed `PVTI_…` by schema validation). `$PROJECT_NODE_ID` and `$STATUS_FIELD_ID` come from the freshly-read `gp` config. `$TARGET_OPTION_ID` is `gp["options"][options_key]` for the `options_key` returned by `target_for(row)`.

**Outcome routing:**

| `gh` result | `outcome` | `needs_status_retry` | `final_status` | `error` |
|---|---|---|---|---|
| 200 ok (`EDIT_RC` == 0) | `retry_succeeded` | `false` | resolved status name (`"Blocked"` / `"In Progress"` / `"Done"`) | `null` |
| 404 not found¹ | `retry_item_gone` | `false` | row's prior `final_status` (item is gone — no authoritative new state) | `null` |
| any other failure (`EDIT_RC` != 0) | `retry_failed` | `true` | row's prior `final_status` (unchanged on board) | first line of stderr |
| timeout | `retry_failed` | `true` | row's prior `final_status` | `"timeout after Ns"` |

¹ 404 detection: stderr contains the literal `not found` (case-insensitive), or `Could not resolve to a ProjectV2Item with the id`, or `EDIT_RC` ≠ 0 with HTTP 404 markers from `gh`. The exact phrasing varies by `gh` version; pattern-match permissively. When uncertain, fall through to `retry_failed` (operator can re-run).

**Soft-warn log messages (exact text):**

```
[issue-to-project] retry: issue #<N>: item-edit ok → retry_succeeded (<Status Name>)
[issue-to-project] WARN: issue #<N>: project item <PVTI_…> not found — may have been deleted. Recording retry_item_gone.
[issue-to-project] WARN: issue #<N>: retry of status edit to '<Status Name>' failed: <first stderr line> → retry_failed
[issue-to-project] WARN: issue #<N>: retry of status edit to '<Status Name>' timed out after <N>s → retry_failed
```

`<Status Name>` is the resolved name from `target_for(row)` — `"Blocked"`, `"In Progress"`, `"Done"`,
`"Ready"`, or `"In review"`.

`--retry-blocked-edits` is the canonical recovery path for **all seven** edit-failed outcomes: the
v1.2 set (`added_blocked_edit_failed`, `added_in_progress_edit_failed`, `added_done_edit_failed`)
plus the v2.7 additions (`added_ready_edit_failed`, `added_in_review_edit_failed`,
`auto_promoted_ready_edit_failed`), and the legacy `added_default_edit_failed` if present in older
artifacts.

The skill trusts `gh`'s 200 response — no read-back via `item-list` to verify the board state (matches v1.0.0's `added_blocked` convention).

**DRY_RUN=1 behavior.** If `DRY_RUN=1` is in env, skip the actual `gh` invocation. For each `needs_retry` row, record `outcome: "dry_run"`, populate `cli_command` with the literal `gh project item-edit ...` line that would have run, leave `needs_status_retry` unchanged (`true`), set `final_status` to the row's prior value, set `error` to `null`. Forwarded rows are written verbatim. Exit 0.

```python
import os
DRY_RUN = os.environ.get("DRY_RUN") == "1"
```

Build the row-replacement list:

```python
retried_rows = []
for row in needs_retry:
    options_key, status_name = target_for(row)
    target_option_id = gp["options"][options_key]
    cmd = (f"GH_HOST=github.com gh project item-edit "
           f"--id {row['project_item_id']} "
           f"--project-id {gp['project_node_id']} "
           f"--field-id {gp['status_field_id']} "
           f"--single-select-option-id {target_option_id}")
    if DRY_RUN:
        retried_rows.append({**row, "outcome": "dry_run", "cli_command": cmd, "error": None})
        continue
    # invoke gh; classify; build the replacement row preserving issue_number/url/labels.
    # On 200 ok, final_status becomes status_name; otherwise see the outcome-routing table above.
    result = invoke_gh_edit(row, target_option_id, status_name)
    retried_rows.append(result)
```

## Step 4 — Write the forwarded audit artifact

The new artifact replaces the prior `project-sync.json` atomically. Carry forward EVERY row from the prior artifact — retried rows with their new outcome, non-retried rows verbatim.

```python
import datetime, os
results = forwarded + retried_rows
# Stable ordering: preserve prior artifact's order
url_to_new = {r["url"]: r for r in retried_rows}
results = [url_to_new.get(r["url"], r) for r in prior["results"]]

attempted = len(needs_retry)
succeeded = sum(1 for r in retried_rows if r["outcome"] == "retry_succeeded")
failed    = sum(1 for r in retried_rows if r["outcome"] == "retry_failed")
gone      = sum(1 for r in retried_rows if r["outcome"] == "retry_item_gone")
dry       = sum(1 for r in retried_rows if r["outcome"] == "dry_run")

# Summary: re-derive structural counts from the forwarded `results` (forwarded rows
# keep their prior outcome; retried rows carry the new outcome). retry counters
# reflect THIS invocation. For set_* counters, a retry_succeeded row contributes to
# the bucket matching its final_status — that's why we recompute from results, not
# carry forward the prior summary verbatim.
def count(outcomes): return sum(1 for r in results if r["outcome"] in outcomes)
def count_status(name): return sum(1 for r in results if r.get("final_status") == name and r["outcome"] == "retry_succeeded")

ADDED = {"added_default","added_todo_explicit",
         "added_in_progress","added_in_progress_edit_failed",
         "added_blocked","added_blocked_edit_failed",
         "added_done","added_done_edit_failed",
         "added_ready","added_ready_edit_failed",
         "added_in_review","added_in_review_edit_failed",
         "auto_promoted_ready","auto_promoted_ready_edit_failed"}
LEFT_DEFAULT = {"added_default",
                "added_in_progress_edit_failed",
                "added_blocked_edit_failed",
                "added_done_edit_failed",
                "added_ready_edit_failed",
                "added_in_review_edit_failed",
                "auto_promoted_ready_edit_failed"}
EDIT_FAILED  = {"added_in_progress_edit_failed",
                "added_blocked_edit_failed",
                "added_done_edit_failed",
                "added_ready_edit_failed",
                "added_in_review_edit_failed",
                "auto_promoted_ready_edit_failed"}

summary = {
    "issues_in_input":            prior["summary"]["issues_in_input"],
    "already_on_board":           count({"already_on_board"}),
    "added":                      count(ADDED),
    "set_todo":                   count({"added_todo_explicit"}),
    "set_in_progress":            count({"added_in_progress"}) + count_status("In Progress"),
    "set_blocked":                count({"added_blocked"})     + count_status("Blocked"),
    "set_done":                   count({"added_done"})        + count_status("Done"),
    "set_ready":                  count({"added_ready", "auto_promoted_ready"}) + count_status("Ready"),
    "set_in_review":              count({"added_in_review"})   + count_status("In review"),
    # left_default subtracts retry_succeeded rows whose prior outcome was edit-failed
    # (those rows had been counted in left_default by the prior run and are no longer
    # at Todo on the board). The simplest correct expression: re-count from current
    # forwarded results, where retry_succeeded rows are no longer "edit-failed".
    "left_default":               count(LEFT_DEFAULT),
    "add_failed":                 count({"add_failed"}),
    "edit_failed":                count(EDIT_FAILED),
    "dry_run":                    count({"dry_run"}),
    "skipped_after_total_failure":count({"skipped_after_total_failure"}),
    "retry_attempted":            attempted,
    "retry_succeeded":            succeeded,
    "retry_failed":               failed,
    "retry_item_gone":            gone,
}
```

The summary recomputation honors three invariants:

1. A `retry_succeeded` row was previously `added_*_edit_failed`. After retry, it no longer counts in `edit_failed` or `left_default`. The recomputation drops it naturally because `count(EDIT_FAILED)` walks the *current* `results`, where the row's outcome is now `retry_succeeded`.
2. A `retry_failed` row's outcome changes from `added_*_edit_failed` → `retry_failed`. It also drops out of `edit_failed` / `left_default` — but `needs_status_retry: true` is preserved, so a future retry run can still find it. (`edit_failed` is a strict count of `added_*_edit_failed` outcomes; ongoing retry-failures are surfaced via `retry_failed` instead.)
3. A `retry_item_gone` row is terminal — the item is off the board, so it counts in neither `set_*` nor `left_default` nor `edit_failed`. The summary's `retry_item_gone` is the only place it appears.

artifact = {
    "schema_version": "2.7",
    "slug": slug,
    "run_timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "skill_version": "2.7.0",
    "retry_source": {
        "slug": prior["slug"],
        "run_timestamp": prior["run_timestamp"],
        "skill_version": prior["skill_version"],
        "prior_artifact_path": str(prior_path),
    },
    "project": prior["project"],
    "summary": summary,
    "results": results,
}

# Validate against the schema BEFORE writing
schema = json.loads(pathlib.Path(
    "plugins/makato-plan/skills/issue-to-project/references/project-sync.schema.json"
).read_text())
try:
    jsonschema.validate(artifact, schema)
except jsonschema.ValidationError as e:
    sys.exit(f"issue-to-project: project-sync.json failed schema validation: {e.message}\n"
             f"HALT: AUDIT_SCHEMA_FAILED")

out = pathlib.Path(f"specs/{slug}/project-sync.json")
out.parent.mkdir(parents=True, exist_ok=True)
tmp = out.with_suffix(".json.tmp")
try:
    tmp.write_text(json.dumps(artifact, indent=2) + "\n")
    os.replace(tmp, out)
except OSError as e:
    print(f"issue-to-project: project-sync.json write failed ({e}). "
          f"Retry edits DID happen (or were dry-run) — see GitHub Project board for actual state.",
          file=sys.stderr)
    print("HALT: AUDIT_WRITE_FAILED")
    sys.exit(1)
```

**Ordering rule:** the write happens even when every retried row failed. The exit-code evaluation (TOTAL_SYNC_FAILED) happens AFTER the write, so callers catching exit 1 still get an artifact.

**TOTAL_SYNC_FAILED for retry:** if `attempted > 0` AND `succeeded == 0` AND `gone == 0` AND `dry == 0`, exit 1 with HALT `TOTAL_SYNC_FAILED`: `"issue-to-project: --retry-blocked-edits: all <attempted> retry attempts failed. Artifact written. Check 'error' fields in specs/<slug>/project-sync.json."` This mirrors normal-run's zero-success exit semantics.

## Step 5 — Emit return format and handoff line

```python
result = {
    "status": (
        "failed" if exit_code == 1 else
        "partial" if failed > 0 else
        "ok"
    ),
    "slug": slug,
    "artifact_path": f"specs/{slug}/project-sync.json",
    "retried_count": attempted,
    "retry_succeeded": succeeded,
    "retry_failed": failed,
    "retry_item_gone": gone,
}
print(f"RESULT: {json.dumps(result, separators=(',', ':'))}")
print(f"Next: review specs/{slug}/project-sync.json; if needs_status_retry rows remain, "
      "run --retry-blocked-edits again or set Status=Blocked manually in the GitHub Project UI.")
```

On non-zero exit, also print `HALT: <code>` as the final line (after `Next: …`).

## Boundary cases

- **Prior artifact is itself a retry artifact** (`schema_version: "2.7"`, `retry_source` not null). Fully supported — the new `retry_source` chain points one hop back; the prior's `retry_source` is not preserved in the new artifact (`retry_source` always reflects the immediate parent only). Operators wanting full provenance read the prior file directly.
- **A `needs_retry` row's `project_item_id` is null** in the prior artifact. Cannot happen given schema constraints (`added_blocked_edit_failed` ⇒ `project_item_id` is a `PVTI_…` string). If a malformed v1 artifact slips through, the row fails schema validation at Step 2 and the run aborts with `RETRY_SOURCE_MALFORMED`.
- **The prior artifact has `add_failed` rows.** Those rows are forwarded verbatim — they have no `project_item_id` and are out of scope for this verb (see Spec O1). To retry them, run normal-run `issue-to-project <slug>`; the next snapshot won't contain them, and Step 4 will re-attempt the full add+edit pair.
- **`option_id` mismatch on `item-edit`.** If `gh` rejects the option ID with a graphql error (rare — would mean the operator deleted the Blocked option since `--init`), the row gets `retry_failed` with the stderr as `error`. Operator action: re-run `--init` to refresh the cache, then re-run `--retry-blocked-edits`.
