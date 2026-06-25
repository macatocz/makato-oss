<!-- markdownlint-disable MD013 -->
# Auto-Re-init Sub-path — v2.5.0

Triggered between the stale-config detection point (step 4 of `sync-process.md`) and the existing `STALE_CONFIG` halt when `--auto-reinit` is passed. The entire sub-path uses `gh` + `python3` glue identical to the v1 `--init` wizard — no subagent fan-out, no interactive prompts.

## When This File Is Loaded

Load this file when:
- `--auto-reinit` is in argv AND the stale-config trigger (2 consecutive item-add failures matching the stale-id pattern) has just fired in step 4, OR
- `--auto-reinit` is in argv at normal-run start (to read title-migration rules before step 1 config validation).

Do NOT load for `--init`, `--retry-blocked-edits`, `sync-lifecycle`, `reconcile`, `--board-audit`, or `--fields-only` runs.

## Prerequisites

All pre-flight checks 1–5 have passed. Config has been read and validated (step 1). The stale-config trigger has fired. `github_project.owner`, `github_project.owner_type`, `github_project.number`, and `github_project.title` (or the migration result) are available.

---

## Phase 0 — Title Migration (one-time, runs at step 1 if `title` is absent)

Before step 1 completes, detect whether `title` is absent from the `github_project` block:

```python
gp = config["github_project"]
if "title" not in gp or not gp["title"]:
    # One-time migration: fetch title from live project
    import subprocess, json as _json

    cmd = (
        f"GH_HOST=github.com timeout {os.environ.get('ITP_GH_TIMEOUT_SECONDS', '30')} "
        f"gh project view {gp['number']} --owner {gp['owner']} --format json"
    )
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        # Soft-warn: migration failed, auto-reinit unavailable this run only
        print(
            f"[issue-to-project] WARN: title migration failed "
            f"({result.stdout.strip() or result.stderr.strip()}) — "
            f"auto-reinit unavailable this run. Run 'issue-to-project --init' to upgrade config."
        )
        # Set a sentinel so Phase 1 knows migration failed
        title_migration_failed = True
    else:
        data = _json.loads(result.stdout)
        fetched_title = data.get("title", "")
        if fetched_title:
            # Write title (and bump init_skill_version) into config.json
            gp["title"] = fetched_title
            gp["init_skill_version"] = "2.5.0"
            _write_config(config)   # atomic write (see config write rules below)
            print(
                f"[issue-to-project] INFO: migrated v1 config — "
                f"cached title \"{fetched_title}\" for project #{gp['number']}"
            )
            title_migration_failed = False
        else:
            print(
                "[issue-to-project] WARN: title migration returned empty title — "
                "auto-reinit unavailable this run. Run 'issue-to-project --init'."
            )
            title_migration_failed = True
else:
    title_migration_failed = False
```

**Migration rules:**
- Migration is **idempotent**: if `title` is present (even from a prior migration), skip silently.
- Migration failure does NOT abort normal sync. Only the auto-reinit sub-path is blocked for this run.
- If the stale-config trigger fires AND migration failed, fall through to HALT `STALE_CONFIG` with the additional note:
  `"issue-to-project: auto-reinit skipped: title not cached; run 'issue-to-project --init' to upgrade config."`
- `DRY_RUN=1` does NOT suppress the migration write: the title is a read-only enrichment, not a mutation of board state.

---

## Phase 1 — Validate Gate Conditions

Before entering the sub-path, confirm:

```python
auto_reinit_active = "--auto-reinit" in sys.argv
no_auto_reinit_flag = "--no-auto-reinit" in sys.argv

if no_auto_reinit_flag:
    print("[issue-to-project] INFO: --no-auto-reinit has no effect in v2.5; auto-reinit defaults OFF")

if not auto_reinit_active:
    # v2.5 default: auto-reinit OFF; fall through to v1 STALE_CONFIG halt
    print("issue-to-project: cached project_node_id appears stale or the project was archived/deleted. "
          "Re-run 'issue-to-project --init'.")
    print("HALT: STALE_CONFIG")
    sys.exit(1)

if title_migration_failed:
    # Migration failed earlier; cannot match without title
    print("issue-to-project: cached project_node_id appears stale. "
          "auto-reinit skipped: title not cached; run 'issue-to-project --init' to upgrade config.")
    print("HALT: STALE_CONFIG")
    sys.exit(1)

print("[issue-to-project] INFO: stale-config trigger fired after 2 consecutive item-add failures")
print(f"[issue-to-project] INFO: auto-reinit: searching for project #{gp['number']} "
      f"under owner {gp['owner']}")
```

---

## Phase 2 — Project List Lookup (step 2 of sub-path)

```bash
PROJECT_LIST_LIMIT="${PROJECT_LIST_LIMIT:-50}"
LIST_RAW="$(GH_HOST=github.com timeout "${ITP_GH_TIMEOUT_SECONDS:-30}" \
  gh project list --owner "${OWNER}" --format json --limit "${PROJECT_LIST_LIMIT}" 2>&1)"
```

Parse and filter:

```python
import json as _json

project_list = _json.loads(LIST_RAW).get("projects", [])

cached_number = gp["number"]
cached_title  = gp["title"].lower().strip()
cached_owner_type = gp["owner_type"]

matches = [p for p in project_list if p.get("number") == cached_number]

# --- Error cases ---

if len(matches) == 0:
    print(
        f"[issue-to-project] WARN: auto-reinit could not find project "
        f"#{cached_number} under owner {gp['owner']}. "
        "Project may have been deleted or transferred."
    )
    print(
        f"issue-to-project: auto-reinit could not find project #{cached_number} "
        f"under owner {gp['owner']}. Project may have been deleted or transferred. "
        "Re-run 'issue-to-project --init'."
    )
    print("HALT: AMBIGUOUS_REINIT")
    sys.exit(1)

if len(matches) > 1:
    print(
        f"[issue-to-project] WARN: auto-reinit found multiple projects at "
        f"#{cached_number} (API invariant violation)."
    )
    print(
        f"issue-to-project: auto-reinit found multiple projects at #{cached_number}. "
        "Re-run 'issue-to-project --init'."
    )
    print("HALT: AMBIGUOUS_REINIT")
    sys.exit(1)

match = matches[0]
found_title = match.get("title", "").lower().strip()

if found_title != cached_title:
    print(
        f"[issue-to-project] WARN: auto-reinit found project #{cached_number} "
        f"but title mismatch (cached: '{gp['title']}', found: '{match.get('title', '')}'). "
    )
    print(
        f"issue-to-project: auto-reinit found project #{cached_number} but title mismatch "
        f"(cached: '{gp['title']}', found: '{match.get('title', '')}'). "
        "Re-run 'issue-to-project --init' to confirm the correct project."
    )
    print("HALT: AMBIGUOUS_REINIT")
    sys.exit(1)

# Owner-type change check (user vs org projects may share numbers across boundaries)
# gh project list --owner <login> returns the project under the owner's space;
# if owner_type changed, the URL shape changes. Detect via URL prefix.
found_url = match.get("url", "")
is_user_url = "/users/" in found_url
is_org_url  = "/orgs/" in found_url

owner_type_mismatch = (
    (cached_owner_type == "user" and is_org_url) or
    (cached_owner_type == "organization" and is_user_url)
)
if owner_type_mismatch:
    print(
        f"[issue-to-project] WARN: auto-reinit detected owner-type change for "
        f"project #{cached_number}."
    )
    print(
        f"issue-to-project: auto-reinit detected owner-type change for project "
        f"#{cached_number}. Re-run 'issue-to-project --init'."
    )
    print("HALT: AMBIGUOUS_REINIT")
    sys.exit(1)

new_project_node_id = match.get("id", "")
new_url = found_url
print(
    f"[issue-to-project] INFO: auto-reinit: matched project "
    f"#{cached_number} \"{match.get('title', '')}\" — new node_id {new_project_node_id}"
)
```

---

## Phase 3 — Status Field Validation (step 3 of sub-path)

```bash
FIELD_LIST_RAW="$(GH_HOST=github.com timeout "${ITP_GH_TIMEOUT_SECONDS:-30}" \
  gh project field-list "${NUMBER}" --owner "${OWNER}" --format json 2>&1)"
```

```python
fields = _json.loads(FIELD_LIST_RAW).get("fields", [])

# Find the Status field by name (case-insensitive)
status_field = next(
    (f for f in fields if f.get("name", "").lower() == gp["status_field_name"].lower()),
    None
)

if not status_field:
    print(
        f"[issue-to-project] WARN: auto-reinit found project #{cached_number} but "
        f"Status field '{gp['status_field_name']}' not found or renamed."
    )
    print(
        f"issue-to-project: auto-reinit found project #{cached_number} but Status field "
        f"structure has changed (field '{gp['status_field_name']}' not found or renamed). "
        "Re-run 'issue-to-project --init'."
    )
    print("HALT: AMBIGUOUS_REINIT")
    sys.exit(1)

# Validate option names (case-insensitive) — must contain all four
REQUIRED_OPTION_NAMES = {"todo", "in progress", "done", "blocked"}
live_option_names = {
    opt.get("name", "").lower()
    for opt in status_field.get("options", [])
}
if not REQUIRED_OPTION_NAMES.issubset(live_option_names):
    missing = REQUIRED_OPTION_NAMES - live_option_names
    print(
        f"[issue-to-project] WARN: auto-reinit found project #{cached_number} but "
        f"Status options changed (missing: {sorted(missing)})."
    )
    print(
        f"issue-to-project: auto-reinit found project #{cached_number} but Status options "
        f"changed (expected: Todo/In Progress/Done/Blocked). Re-run 'issue-to-project --init'."
    )
    print("HALT: AMBIGUOUS_REINIT")
    sys.exit(1)

# Extract new field IDs and option IDs
new_status_field_id = status_field.get("id", "")
new_options = {}
option_name_map = {opt["name"].lower(): opt for opt in status_field.get("options", [])}
for key, name in [("todo", "todo"), ("in_progress", "in progress"), ("done", "done"), ("blocked", "blocked")]:
    opt = option_name_map.get(name)
    new_options[key] = opt["id"] if opt else gp["options"].get(key)

print("[issue-to-project] INFO: auto-reinit: Status field and options unchanged — proceeding")
```

---

## Phase 4 — Idempotency Guard

```python
old_project_node_id = gp["project_node_id"]

if new_project_node_id == old_project_node_id:
    # Already fixed (e.g. a previous auto-reinit on this run, or a concurrent run).
    # No config write needed. Resume item-add with existing IDs.
    print(
        f"[issue-to-project] INFO: auto-reinit: new node_id matches cached node_id "
        f"{new_project_node_id} — idempotency guard; skipping config write"
    )
    auto_reinit_fired = True
    auto_reinit_old_node_id = old_project_node_id
    auto_reinit_new_node_id = new_project_node_id
    # Skip Phase 5; go directly to Phase 6 (resume item-add).
```

---

## Phase 5 — Config Write

Update the `github_project` block in `.claude/config.json`. Rules:

- **Mutable keys** (update in-place): `project_node_id`, `status_field_id`, `options.todo`, `options.in_progress`, `options.done`, `options.blocked`, `url`.
- **New keys** (append): `reinit_timestamp`, `reinit_skill_version`, `reinit_reason`.
- **Immutable keys** (never change): `init_timestamp`, `init_skill_version`.

```python
import datetime as _dt

reinit_ts = _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")

if os.environ.get("DRY_RUN") == "1":
    # Suppress config write; record sentinel
    print(
        f"[issue-to-project] INFO: DRY_RUN=1 — auto-reinit config write suppressed. "
        f"Would have written new node_id {new_project_node_id}"
    )
    auto_reinit_new_node_id_recorded = "dry_run_not_written"
    # Use new IDs in-memory for the resumed item-add loop anyway
    gp["project_node_id"] = new_project_node_id
    gp["status_field_id"]  = new_status_field_id
    gp["options"].update(new_options)
    gp["url"] = new_url
else:
    gp["project_node_id"]      = new_project_node_id
    gp["status_field_id"]       = new_status_field_id
    gp["options"].update(new_options)
    gp["url"]                   = new_url
    gp["reinit_timestamp"]      = reinit_ts
    gp["reinit_skill_version"]  = "2.5.0"
    gp["reinit_reason"]         = (
        f"stale_project_node_id: {old_project_node_id} rejected by item-add"
    )
    # init_timestamp and init_skill_version are NOT touched

    try:
        _write_config(config)  # atomic write via tmp + os.replace
        print(
            f"[issue-to-project] INFO: auto-reinit: config updated; "
            f"resuming item-add from issue #{first_failed_issue_number}"
        )
        auto_reinit_new_node_id_recorded = new_project_node_id
    except OSError as e:
        print(
            f"issue-to-project: auto-reinit resolved new IDs but could not write "
            f".claude/config.json ({e}). Re-run 'issue-to-project --init'."
        )
        print("HALT: INIT_FAILED")
        sys.exit(1)

auto_reinit_fired = True
auto_reinit_old_node_id = old_project_node_id
auto_reinit_new_node_id = auto_reinit_new_node_id_recorded
```

### Config Write Helper (`_write_config`)

The config write is always atomic (write to `.tmp`, then `os.replace`):

```python
def _write_config(config: dict) -> None:
    """Atomically write updated config to .claude/config.json."""
    import pathlib, json as _json, os as _os
    config_path = pathlib.Path(".claude/config.json")
    tmp_path = config_path.with_suffix(".json.tmp")
    tmp_path.write_text(_json.dumps(config, indent=2) + "\n")
    _os.replace(tmp_path, config_path)
```

---

## Phase 6 — Resume Item-Add Loop

Resume the item-add loop from the first-failed issue (the one that triggered the stale detection) using the new `project_node_id`, `status_field_id`, and `options.*` values already updated in `gp`.

The auto-reinit sub-path hands control back to step 4's item-add loop. The resumed issues use `outcome: "recovered_via_auto_reinit"` instead of `added_default` or `added_blocked` to distinguish them from organic adds.

**Loop guard — `STALE_CONFIG_PERSISTENT`:**

If the very next `item-add` call after resumption ALSO fails with a stale-id error pattern, abort immediately:

```python
# Detect persistent staleness: do NOT re-enter the auto-reinit sub-path
if consecutive_failures_after_reinit >= 2:
    print(
        "issue-to-project: auto-reinit updated project IDs but new IDs are also stale. "
        "Re-run 'issue-to-project --init' to manually resolve."
    )
    print("HALT: STALE_CONFIG_PERSISTENT")
    # Mark remaining issues as skipped_after_total_failure
    # Write artifact (step 5 still runs)
    sys.exit(1)
```

**One attempt only.** The loop guard fires at 2 consecutive failures after reinit — identical to the v1 stale-detection threshold, applied to the post-reinit batch. No secondary auto-reinit is attempted.

---

## Phase 7 — Artifact Emission (auto_reinit_log)

After the item-add loop completes (success or partial), append the auto-re-init log entry to the artifact before step 5 writes it:

```python
auto_reinit_log_entry = {
    "timestamp":            reinit_ts,
    "old_project_node_id":  auto_reinit_old_node_id,
    "new_project_node_id":  auto_reinit_new_node_id,
    "trigger_reason":       f"item-add failure: project not found ({auto_reinit_old_node_id})",
}

# Set schema_version to "2.5" when auto_reinit_log is present
artifact["schema_version"] = "2.5"
artifact["skill_version"]  = "2.5.0"
artifact["auto_reinit_log"] = [auto_reinit_log_entry]
```

`auto_reinit_log` is an array to accommodate future multi-phase logging. In v2.5 it always contains exactly one entry when present.

---

## HALT Codes Summary

| HALT code | Phase | Trigger |
|---|---|---|
| `STALE_CONFIG` | Phase 1 | `--auto-reinit` absent (v2.5 default OFF) or title migration failed |
| `AMBIGUOUS_REINIT` | Phase 2 or 3 | Zero matches, title mismatch, 2+ matches, owner-type change, Status field/option drift |
| `INIT_FAILED` | Phase 5 | Config write failure after successful resolution |
| `STALE_CONFIG_PERSISTENT` | Phase 6 (loop guard) | New IDs are also stale; loop guard fired |

All HALT codes exit `1`. Exit code semantics are unchanged from v1.

---

## Error Messages (verbatim)

| Failure | Stderr/stdout |
|---|---|
| `--auto-reinit` absent (no-op in v2.5 default) | `"issue-to-project: cached project_node_id appears stale or the project was archived/deleted. Re-run 'issue-to-project --init'."` + `HALT: STALE_CONFIG` |
| Title migration failed | `"[issue-to-project] WARN: title migration failed (<error>) — auto-reinit unavailable this run. Run 'issue-to-project --init' to upgrade config."` (then STALE_CONFIG if stale trigger fires) |
| Project not found | `"issue-to-project: auto-reinit could not find project #<n> under owner <owner>. Project may have been deleted or transferred. Re-run 'issue-to-project --init'."` + `HALT: AMBIGUOUS_REINIT` |
| Title mismatch | `"issue-to-project: auto-reinit found project #<n> but title mismatch (cached: '<old>', found: '<new>'). Re-run 'issue-to-project --init' to confirm the correct project."` + `HALT: AMBIGUOUS_REINIT` |
| 2+ matches (API invariant) | `"issue-to-project: auto-reinit found multiple projects at #<n>. Re-run 'issue-to-project --init'."` + `HALT: AMBIGUOUS_REINIT` |
| Owner-type change | `"issue-to-project: auto-reinit detected owner-type change for project #<n>. Re-run 'issue-to-project --init'."` + `HALT: AMBIGUOUS_REINIT` |
| Status field missing/renamed | `"issue-to-project: auto-reinit found project #<n> but Status field structure has changed (field '<name>' not found or renamed). Re-run 'issue-to-project --init'."` + `HALT: AMBIGUOUS_REINIT` |
| Status options changed | `"issue-to-project: auto-reinit found project #<n> but Status options changed (expected: Todo/In Progress/Done/Blocked). Re-run 'issue-to-project --init'."` + `HALT: AMBIGUOUS_REINIT` |
| Config write failure | `"issue-to-project: auto-reinit resolved new IDs but could not write .claude/config.json (<errno>). Re-run 'issue-to-project --init'."` + `HALT: INIT_FAILED` |
| New IDs also stale | `"issue-to-project: auto-reinit updated project IDs but new IDs are also stale. Re-run 'issue-to-project --init' to manually resolve."` + `HALT: STALE_CONFIG_PERSISTENT` |
| `--no-auto-reinit` in v2.5 (no-op) | `"[issue-to-project] INFO: --no-auto-reinit has no effect in v2.5; auto-reinit defaults OFF"` (then normal v2.5 behavior) |

---

## Idempotency Contract

Re-running after a successful auto-re-init is fully idempotent:
- The updated config has the new IDs; the re-run guard snapshots the board.
- Issues added in the auto-reinit run are already on the board (`already_on_board` on re-run).
- `recovered_via_auto_reinit` is NOT emitted on the second run — those items appear as `already_on_board`.

Re-running when `AMBIGUOUS_REINIT` fired leaves the config unchanged. The operator must run `--init` manually (interactive, always safe).

---

## DRY_RUN=1 Interaction

`DRY_RUN=1` with `--auto-reinit`:
- Phases 0–4 run normally (all `gh` discovery reads execute).
- Phase 5 (config write) is **suppressed**; new IDs are applied in-memory only.
- The artifact records `"new_project_node_id": "dry_run_not_written"` in `auto_reinit_log`.
- Resumed item-add calls in Phase 6 use `outcome: "dry_run"` (not `recovered_via_auto_reinit`).
- This is the safe audit path: operators can verify what auto-reinit would discover without committing config changes.

---

## v2.6 Preview (for context only — not implemented in this file)

In v2.6, auto-reinit defaults ON. `--auto-reinit` becomes a no-op (the feature is on by default). `--no-auto-reinit` becomes meaningful: it suppresses auto-reinit and reverts to the v1 `STALE_CONFIG` halt behavior. Operators who want the v1 halt in v2.6+ must pass `--no-auto-reinit` explicitly.
