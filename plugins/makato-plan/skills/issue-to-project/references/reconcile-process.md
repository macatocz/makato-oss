<!-- markdownlint-disable MD013 -->
# `reconcile` — 6-step flow

Pre-flight checks 1–4 from SKILL.md run first. This file picks up after they pass. The `reconcile` subcommand (or its `--reconcile` alias) is dispatched from SKILL.md Step 1.

## Overview

`reconcile` diffs the live board snapshot against expected state derived from `specs/*/created-issues.json` and reports drift without mutating by default. Two opt-in repair modes let operators apply safe or aggressive fixes. It writes `reconcile-report.json` exclusively — `project-sync.json` is never touched by this path.

```
issue-to-project reconcile [<slug>]
  │
  ├─ Step 0: Pre-flight (same 4 checks as v1)
  ├─ Step 1: Read config (same rules as v1 normal-run)
  ├─ Step 2: Resolve input scope (slug or union all created-issues.json)
  ├─ Step 3: Paged board snapshot (replaces single item-list call)
  ├─ Step 4: Drift detection (classify each issue into drift cases)
  ├─ Step 5: Repair (conditional on --repair-* flag; default: skip)
  └─ Step 6: Write reconcile-report.json + emit R1 sentinel
```

---

## Step 0 — Pre-flight checks

Same 4 checks as normal-run (see SKILL.md Step 0). Any failure exits `1` with HALT `PREFLIGHT_FAILED`.

Additionally, validate flag mutual exclusivity before any file I/O:

- If both `--repair-additive` and `--repair-aggressive` are present: exit `1` with `"issue-to-project: --repair-additive and --repair-aggressive are mutually exclusive."` No HALT code emitted (not a pre-flight failure — a user error).
- If `reconcile` and `--init` are both present: exit `1` with `"issue-to-project: reconcile and --init are mutually exclusive."`.

---

## Step 1 — Read and validate config

Identical to `sync-process.md` Step 1. Read `.claude/config.json`, validate the `github_project` block, assert required keys and ID-format prefixes (`PVT_` for `project_node_id`, `PVTSSF_` for `status_field_id`, all four `options.*` IDs present).

```python
import json, pathlib, sys
config = json.loads(pathlib.Path(".claude/config.json").read_text())
gp = config.get("github_project")
if not gp:
    sys.exit("issue-to-project: 'github_project' block missing in .claude/config.json. "
             "Run 'issue-to-project --init' to set up project board sync.\nHALT: MISSING_CONFIG")
```

Read env vars:

```python
import os
PAGE_SIZE   = int(os.environ.get("ITP_RECONCILE_PAGE_SIZE", "100"))
GH_TIMEOUT  = int(os.environ.get("ITP_GH_TIMEOUT_SECONDS", "30"))
DRY_RUN     = os.environ.get("DRY_RUN", "0") == "1"
```

---

## Step 2 — Resolve input scope

### Slug-scoped (explicit slug)

```python
input_path = pathlib.Path(f"specs/{slug}/created-issues.json")
if not input_path.exists():
    sys.exit(f"issue-to-project: no created-issues.json found at specs/{slug}/. "
             f"Run 'to-issues {slug}' first.\nHALT: MISSING_INPUT")

data = json.loads(input_path.read_text())
issues = data["issues"]
if not issues:
    sys.exit("issue-to-project: created-issues.json contains zero issues.\nHALT: EMPTY_INPUT")

slug_scope = slug
artifact_out = pathlib.Path(f"specs/{slug}/reconcile-report.json")
```

Validate `created-issues.json` against the `created-issues.schema.json` schema (same as normal-run). Any validation error → exit `1`, HALT `MALFORMED_INPUT`.

### Slug-less (union all)

When no positional slug is given, union all `specs/*/created-issues.json`:

```python
import glob as _glob

all_paths = sorted(_glob.glob("specs/*/created-issues.json"))
if not all_paths:
    sys.exit("issue-to-project: no created-issues.json files found under specs/. "
             "Run 'to-issues' first.\nHALT: MISSING_INPUT")

seen_urls = {}   # url -> first slug
issues = []
for path in all_paths:
    slug_dir = pathlib.Path(path).parent.name
    data = json.loads(pathlib.Path(path).read_text())
    for it in data.get("issues", []):
        if it["url"] in seen_urls:
            print(f"[issue-to-project] WARN: duplicate URL {it['url']} in {slug_dir}/ "
                  f"(first seen in {seen_urls[it['url']]}/) — first-occurrence wins")
            continue
        seen_urls[it["url"]] = slug_dir
        issues.append(it)

if not issues:
    sys.exit("issue-to-project: all created-issues.json files contain zero issues.\nHALT: EMPTY_INPUT")

slug_scope = "*"
artifact_out = pathlib.Path("specs/.reconcile-report.json")
```

Deduplication uses first-occurrence-wins on `url`. One `WARN` logged per duplicate. `slug_scope` is `"*"` in the R1 sentinel and artifact.

---

## Step 3 — Paged board snapshot

The reconcile path uses a paged snapshot strategy instead of the single `--limit 9999` call used in normal-run. This supports boards larger than 9999 items and provides progress logging.

### Step 3a — Get total count

```bash
VIEW_RAW="$(GH_HOST=github.com timeout "$GH_TIMEOUT" \
  gh project view "$NUMBER" --owner "$OWNER" --format json 2>&1)"
```

Parse `total_board_items = json.loads(VIEW_RAW)["items"]["totalCount"]`.

If this call fails, fall back to a `total` of `None` (unknown) and proceed without a progress estimate — the loop will still terminate when `offset >= len(batch)`.

### Step 3b — Paged loop

```python
snapshot = {}   # url -> {"projectItemId": str, "currentStatusName": str|None}
offset = 0
page = 1

while True:
    batch_raw = run_gh(
        f"GH_HOST=github.com timeout {GH_TIMEOUT} "
        f"gh project item-list {NUMBER} --owner {OWNER!r} "
        f"--format json --limit {PAGE_SIZE} --skip {offset}"
    )
    if batch_raw is None:  # error
        if page == 1:
            sys.exit(f"issue-to-project: item-list failed/timed-out\nHALT: SNAPSHOT_FAILED")
        else:
            sys.exit(
                f"issue-to-project: paged board snapshot failed at page {page} "
                f"(offset {offset}). Partial snapshot discarded — re-run to retry.\n"
                f"HALT: PAGED_SNAPSHOT_FAILED"
            )

    batch = json.loads(batch_raw)
    items = batch.get("items", [])

    if total_board_items is not None:
        print(f"[issue-to-project] INFO: paged snapshot: page {page} ({len(items)} items)")

    for item in items:
        if item.get("content") and item["content"].get("url"):
            snapshot[item["content"]["url"]] = {
                "projectItemId": item["id"],
                "currentStatusName": (item.get("status") or {}).get("name"),
            }

    offset += len(items)
    if len(items) < PAGE_SIZE:
        # Last page (partial or empty)
        break
    page += 1

if total_board_items is not None:
    print(f"[issue-to-project] INFO: paged snapshot complete: {len(snapshot)} items (totalCount={total_board_items})")
```

**Key invariants:**
- Page 1 failure → HALT `SNAPSHOT_FAILED` (consistent with v1 single-call failure).
- Page ≥ 2 failure → HALT `PAGED_SNAPSHOT_FAILED` (new in v2.2.0) — partial snapshot discarded, no artifact written.
- `ITP_GH_TIMEOUT_SECONDS` applies per-call inside the paged loop.
- Draft project items (no `content` block) are silently skipped — same as normal-run snapshot logic.

---

## Step 4 — Drift detection

Build a lookup of input issues by URL:

```python
input_by_url = {it["url"]: it for it in issues}
```

Classify every issue in `input_by_url` and every orphan in `snapshot` into one of six drift cases plus the clean state.

### Drift case reference

| Case | Trigger | Default severity | Repairable in `--repair-additive` | Repairable in `--repair-aggressive` |
|---|---|---|---|---|
| `clean` | URL in input and on board; Status matches label signal (or no label conflict) | — (not in drift[]) | n/a | n/a |
| `orphan` | URL in snapshot but NOT in any input `created-issues.json` for this scope | `warn` | No | No (D3) |
| `sync_gap` | URL in input but NOT in snapshot (not yet added to board) | `warn` | Yes (add it) | Yes (add it) |
| `label_blocked_board_not` | Issue has `status:blocked` in input labels; board Status is not `Blocked` | `warn` | No | Yes (set Blocked) |
| `board_blocked_label_not` | Board Status is `Blocked`; issue does NOT have `status:blocked` in input labels | `warn` | No | Yes (clear Blocked → Todo) |
| `pr_merged_not_done` (case 5) | Board Status not `Done` and a linked PR has merged (feature not yet shipped) | `error` → reported as `pending_future_feature` / `info` | No | No (D6) |
| `field_disagrees` (case 6) | A tracked custom field on the board disagrees with a source signal (feature not yet shipped) | `error` → reported as `pending_future_feature` / `info` | No | No (D6) |

**Cases 5 and 6** are classified as `pending_future_feature` with `severity: info` because the repair features (O1, O2 in spec) are not yet shipped. Detection runs; repair is a no-op; the rows are included in the artifact so downstream tooling can consume them when the features ship.

### Classification pseudocode

```python
drift_rows = []
clean_count = 0

# Orphan detection: board items not in input
for url, board_item in snapshot.items():
    if url not in input_by_url:
        drift_rows.append({
            "case": "orphan",
            "severity": "warn",
            "url": url,
            "project_item_id": board_item["projectItemId"],
            "board_status": board_item["currentStatusName"],
            "input_labels": None,
            "note": "On board but not in any created-issues.json for this scope",
            "repaired": False,
            "repair_action": None,
        })
        print(f"[issue-to-project] WARN: orphan on board (not in any created-issues.json): "
              f"{url} — listed in reconcile-report.json for human review")

# Input issue classification
for url, issue in input_by_url.items():
    labels = issue.get("labels", [])
    board_item = snapshot.get(url)

    if board_item is None:
        # sync_gap: not on board yet
        drift_rows.append({
            "case": "sync_gap",
            "severity": "warn",
            "url": url,
            "project_item_id": None,
            "board_status": None,
            "input_labels": labels,
            "note": "In created-issues.json but not found on board — v1 normal-run would fix this",
            "repaired": False,
            "repair_action": None,
        })
        continue

    board_status = board_item["currentStatusName"]
    has_blocked_label = "status:blocked" in labels

    if has_blocked_label and board_status != "Blocked":
        drift_rows.append({
            "case": "label_blocked_board_not",
            "severity": "warn",
            "url": url,
            "project_item_id": board_item["projectItemId"],
            "board_status": board_status,
            "input_labels": labels,
            "note": f"labels say status:blocked but board Status is {board_status!r} — likely externally changed",
            "repaired": False,
            "repair_action": None,
        })
        print(f"[issue-to-project] WARN: drift detected: label_blocked_board_not on issue {url}")

    elif not has_blocked_label and board_status == "Blocked":
        drift_rows.append({
            "case": "board_blocked_label_not",
            "severity": "warn",
            "url": url,
            "project_item_id": board_item["projectItemId"],
            "board_status": board_status,
            "input_labels": labels,
            "note": "board Status is Blocked but labels do not contain status:blocked",
            "repaired": False,
            "repair_action": None,
        })
        print(f"[issue-to-project] WARN: drift detected: board_blocked_label_not on issue {url}")

    else:
        # Cases 5 and 6 detection (pending_future_feature placeholder)
        # When O1/O5 ship, replace this block with real classifiers.
        # For now: no detection logic for these cases — they are out of scope (D6).
        clean_count += 1
```

**Summary counters:**

```python
by_case = {
    "orphan":                   sum(1 for r in drift_rows if r["case"] == "orphan"),
    "sync_gap":                 sum(1 for r in drift_rows if r["case"] == "sync_gap"),
    "label_blocked_board_not":  sum(1 for r in drift_rows if r["case"] == "label_blocked_board_not"),
    "board_blocked_label_not":  sum(1 for r in drift_rows if r["case"] == "board_blocked_label_not"),
    "pr_merged_not_done":       sum(1 for r in drift_rows if r["case"] == "pr_merged_not_done"),
    "field_disagrees":          sum(1 for r in drift_rows if r["case"] == "field_disagrees"),
    "pending_future_feature":   sum(1 for r in drift_rows if r["case"] == "pending_future_feature"),
}
drift_total = sum(by_case.values())
```

---

## Step 5 — Repair (conditional)

Repair runs only if `--repair-additive` or `--repair-aggressive` is present. In read-only mode (no flag), skip this step entirely.

### Pre-repair check for `--repair-aggressive`

Before any mutation, check TTY:

```python
import sys as _sys
if repair_aggressive:
    if not yes_i_know and not _sys.stdin.isatty():
        _sys.exit(
            "issue-to-project: --repair-aggressive requires interactive confirmation "
            "or --yes-i-know on non-TTY.\nHALT: RECONCILE_NEEDS_CONFIRM"
        )
    if _sys.stdin.isatty() and not yes_i_know:
        print(f"\nAbout to apply aggressive repairs to {drift_total} drift rows "
              f"(orphans will NOT be touched). Labels win over board Status. Proceed? [yes/N]: ",
              end="", flush=True)
        answer = input().strip().lower()
        if answer != "yes":
            print("Cancelled.")
            _sys.exit(2)
```

### Repair modes

| Mode | Cases repaired | Status logic |
|---|---|---|
| `--repair-additive` | `sync_gap` only | Calls `item-add` (and conditional `item-edit` for `status:blocked`) — identical to v1 normal-run step 4 logic for the affected issue |
| `--repair-aggressive` | `sync_gap`, `label_blocked_board_not`, `board_blocked_label_not` | `sync_gap`: same as additive. `label_blocked_board_not`: call `item-edit` to set Status=Blocked. `board_blocked_label_not`: call `item-edit` to set Status=Todo (labels win, D4) |
| Both modes | `orphan` | Never repaired (D3) |
| Both modes | `pending_future_feature` | Never repaired (D6) |

**`DRY_RUN=1` behavior in repair modes:** classify drift as normal; build the `repair_action` string for each repairable row; set `repaired: false` (no actual `gh` call). Populate `repair_action` with the literal `gh` command that would have been issued.

### Per-item repair pseudocode

```python
repaired_count = 0
repair_skipped_count = 0
repair_all_failed = True  # True until one mutation succeeds

for row in drift_rows:
    if row["case"] == "orphan":
        row["repair_action"] = None   # D3: never delete
        repair_skipped_count += 1
        continue

    if row["case"] == "pending_future_feature":
        row["repair_action"] = None   # D6: deferred
        repair_skipped_count += 1
        continue

    if row["case"] == "sync_gap" and (repair_additive or repair_aggressive):
        if DRY_RUN:
            row["repair_action"] = (
                f"GH_HOST=github.com gh project item-add {NUMBER} "
                f"--owner {OWNER!r} --url {row['url']!r} --format json"
            )
            repair_skipped_count += 1
            continue
        # Real repair: item-add (and item-edit if status:blocked)
        add_result = gh_project_item_add(NUMBER, OWNER, row["url"])
        if add_result:
            row["repaired"] = True
            row["repair_action"] = "item-add"
            if "status:blocked" in (row.get("input_labels") or []):
                edit_ok = gh_project_item_edit(add_result["id"], gp["project_node_id"],
                                               gp["status_field_id"], gp["options"]["blocked"])
                row["repair_action"] = "item-add + item-edit (Blocked)"
                if not edit_ok:
                    row["repair_action"] = "item-add (item-edit Blocked failed)"
            repaired_count += 1
            repair_all_failed = False
        else:
            print(f"[issue-to-project] WARN: repair failed for {row['url']}: item-add error")
            repair_skipped_count += 1

    elif row["case"] == "label_blocked_board_not" and repair_aggressive:
        if DRY_RUN:
            row["repair_action"] = (
                f"GH_HOST=github.com gh project item-edit --id {row['project_item_id']} "
                f"--project-id {gp['project_node_id']} --field-id {gp['status_field_id']} "
                f"--single-select-option-id {gp['options']['blocked']}"
            )
            repair_skipped_count += 1
            continue
        edit_ok = gh_project_item_edit(row["project_item_id"], gp["project_node_id"],
                                       gp["status_field_id"], gp["options"]["blocked"])
        if edit_ok:
            row["repaired"] = True
            row["repair_action"] = "item-edit (set Blocked)"
            print(f"[issue-to-project] INFO: --repair-aggressive: overriding board Status for "
                  f"issue {row['url']} (label wins)")
            repaired_count += 1
            repair_all_failed = False
        else:
            print(f"[issue-to-project] WARN: repair failed for {row['url']}: item-edit error")
            repair_skipped_count += 1

    elif row["case"] == "board_blocked_label_not" and repair_aggressive:
        if DRY_RUN:
            row["repair_action"] = (
                f"GH_HOST=github.com gh project item-edit --id {row['project_item_id']} "
                f"--project-id {gp['project_node_id']} --field-id {gp['status_field_id']} "
                f"--single-select-option-id {gp['options']['todo']}"
            )
            repair_skipped_count += 1
            continue
        edit_ok = gh_project_item_edit(row["project_item_id"], gp["project_node_id"],
                                       gp["status_field_id"], gp["options"]["todo"])
        if edit_ok:
            row["repaired"] = True
            row["repair_action"] = "item-edit (set Todo)"
            print(f"[issue-to-project] INFO: --repair-aggressive: overriding board Status for "
                  f"issue {row['url']} to Todo (no status:blocked label)")
            repaired_count += 1
            repair_all_failed = False
        else:
            print(f"[issue-to-project] WARN: repair failed for {row['url']}: item-edit error")
            repair_skipped_count += 1

    else:
        repair_skipped_count += 1   # Drift case not repairable in this mode

# After batch: check for all-failed
repair_ran = repair_additive or repair_aggressive
repairable_rows = [r for r in drift_rows
                   if r["case"] not in ("orphan", "pending_future_feature")]
if repair_ran and repairable_rows and repair_all_failed and repaired_count == 0:
    # All repair mutations failed — will exit 1 after artifact write
    total_sync_failed = True
```

**Per-item soft-warn on mutation failure:** log `[issue-to-project] WARN: repair failed for <url>: <error>`. Record `repaired: false` in the artifact. Continue the batch.

**All-failed exit:** after step 6 writes the artifact, if `total_sync_failed`, exit `1` with HALT `TOTAL_SYNC_FAILED` (reuses v1 code).

---

## Step 6 — Write `reconcile-report.json` and emit R1 sentinel

### Determine mode string

```python
if repair_aggressive:
    mode = "repair_aggressive"
elif repair_additive:
    mode = "repair_additive"
else:
    mode = "read_only"
```

### Build and validate artifact

```python
import datetime, jsonschema

artifact = {
    "schema_version": "1",
    "reconcile_timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "skill_version": "2.2.0",
    "mode": mode,
    "slug_scope": slug_scope,
    "project": {
        "owner": gp["owner"],
        "number": gp["number"],
        "url": gp["url"],
        "total_board_items": len(snapshot),
    },
    "summary": {
        "issues_in_input": len(issues),
        "board_items_inspected": len(snapshot),
        "clean": clean_count,
        "drift_total": drift_total,
        "by_case": by_case,
        "repaired": repaired_count,
        "repair_skipped": repair_skipped_count,
    },
    "drift": drift_rows,
    "orphans_for_review": [r["url"] for r in drift_rows if r["case"] == "orphan"],
}

schema_path = pathlib.Path(
    "plugins/makato-plan/skills/issue-to-project/references/reconcile-report.schema.json"
)
rr_schema = json.loads(schema_path.read_text())
try:
    jsonschema.validate(artifact, rr_schema)
except jsonschema.ValidationError as e:
    sys.exit(f"issue-to-project: reconcile-report.json failed schema validation: {e.message}\n"
             f"HALT: AUDIT_SCHEMA_FAILED")
```

### Write artifact (atomic rename)

```python
artifact_out.parent.mkdir(parents=True, exist_ok=True)
tmp = artifact_out.with_suffix(".json.tmp")
try:
    tmp.write_text(json.dumps(artifact, indent=2) + "\n")
    os.replace(tmp, artifact_out)
except OSError as e:
    print(f"issue-to-project: reconcile-report.json write failed ({e}). "
          f"Drift was detected — re-run to capture artifact.")
    print("HALT: AUDIT_WRITE_FAILED")
    sys.exit(1)
```

### Human summary (stdout)

After a successful write, print a human-readable summary:

```
[issue-to-project] reconcile complete (mode: read_only, scope: my-feature)
  Board items inspected : 312
  Input issues          : 20
  Clean                 : 17
  Drift total           : 3
    orphan              : 1
    sync_gap            : 0
    label_blocked_board_not : 1
    board_blocked_label_not : 0
    pending_future_feature  : 1
  Repaired              : 0
  Repair skipped        : 3

Orphans for manual review (not in any created-issues.json):
  https://github.com/zstary/sagibeast/issues/55
```

The orphan list is always printed even in repair modes (D3 — orphans are never auto-repaired).

### R1 RESULT sentinel

Emit as the second-to-last stdout line:

```python
result = {
    "status": ("failed" if total_sync_failed else
               "partial" if repair_ran and repaired_count < len([r for r in drift_rows if r["case"] not in ("orphan","pending_future_feature")]) else
               "ok"),
    "mode": mode,
    "slug_scope": slug_scope,
    "artifact_path": str(artifact_out),
    "drift_total": drift_total,
    "repaired": repaired_count,
    "orphans": by_case["orphan"],
    "sync_gap": by_case["sync_gap"],
    "label_blocked_board_not": by_case["label_blocked_board_not"],
    "board_blocked_label_not": by_case["board_blocked_label_not"],
}
print(f"RESULT: {json.dumps(result, separators=(',', ':'))}")
print(f"Next: review {artifact_out}; orphans listed in orphans_for_review[] require manual board action.")
```

If exiting non-zero, print `HALT: <code>` as the final line after the `Next:` line.

---

## Error handling quick-reference

| Failure | Step | HALT code | Exit |
|---|---|---|---|
| Both `--repair-additive` and `--repair-aggressive` | Step 0 | _(user error message, no HALT code)_ | 1 |
| `reconcile` + `--init` together | Step 0 | _(user error message, no HALT code)_ | 1 |
| Missing `github_project` config | Step 1 | `MISSING_CONFIG` | 1 |
| Malformed config | Step 1 | `MALFORMED_CONFIG` | 1 |
| No `created-issues.json` found | Step 2 | `MISSING_INPUT` | 1 |
| Invalid `created-issues.json` schema | Step 2 | `MALFORMED_INPUT` | 1 |
| Zero issues in all inputs | Step 2 | `EMPTY_INPUT` | 1 |
| Paged snapshot: page 1 fails | Step 3 | `SNAPSHOT_FAILED` | 1 |
| Paged snapshot: page ≥ 2 fails | Step 3 | `PAGED_SNAPSHOT_FAILED` | 1 |
| `--repair-aggressive` on non-TTY without `--yes-i-know` | Step 5 | `RECONCILE_NEEDS_CONFIRM` | 1 |
| `--repair-aggressive` interactive cancel | Step 5 | _(none)_ | 2 |
| All repair mutations failed | After step 6 | `TOTAL_SYNC_FAILED` | 1 |
| `reconcile-report.json` write fails (I/O) | Step 6 | `AUDIT_WRITE_FAILED` | 1 |
| `reconcile-report.json` fails schema validation | Step 6 | `AUDIT_SCHEMA_FAILED` | 1 |
| Per-item repair mutation fails | Step 5 | Soft-warn; continue | — |

---

## Logging conventions

Log prefix rules unchanged from v1. `[issue-to-project]` for progress and warnings:

```
[issue-to-project] INFO: paged snapshot: page 1/4 (100 items)
[issue-to-project] INFO: paged snapshot: page 4/4 (12 items) — 312 total
[issue-to-project] WARN: drift detected: label_blocked_board_not on issue #47
[issue-to-project] WARN: orphan on board (not in any created-issues.json): #55 — listed in reconcile-report.json for human review
[issue-to-project] INFO: --repair-aggressive: overriding board Status for issue #47 (label wins)
[issue-to-project] WARN: duplicate URL https://… in feature-b/ (first seen in feature-a/) — first-occurrence wins
```

`[issue-to-project:auto]` is reserved and not used in this path.

---

## Idempotency

Read-only mode: trivially idempotent (no mutations).

`--repair-additive`: idempotent. Same contract as v1 normal-run add-only path. Running twice against the same `sync_gap` row: first run adds the item; second run finds the item in the snapshot and classifies it `clean` — no duplicate add.

`--repair-aggressive`: idempotent per-item. After a successful repair run, a second reconcile run classifies previously-repaired items as `clean` (no regression). Items where repair failed remain as drift and can be retried. The aggressive override of externally-set Status is explicit and intentional — operators must confirm per run.

---

## Out of scope (deferred)

| Case | Deferred reason |
|---|---|
| Case 5 repair (`pr_merged_not_done`) | Depends on PR-merge lifecycle (v1 O1); separate design cycle |
| Case 6 repair (`field_disagrees`) | Depends on multi-field sync (v1 O5); separate design cycle |
| Orphan deletion | Hard rule (D3); never auto-deleted |
| Cross-board reconcile in one run | One board per run |
| Auto-scheduling | Operator picks cadence |
| Notification routing | Feed `reconcile-report.json` to existing observability |
