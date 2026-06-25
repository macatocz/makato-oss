<!-- markdownlint-disable MD013 -->
# `--board-audit` flow (v2.3.0+)

Read-only board-wide snapshot that re-derives the current state of a shared GitHub Projects v2 board across all contributing repos. Run from any repo whose `.claude/config.json` → `github_project` block points at the shared board. Writes `board-audit.json` to the repo root; **never mutates the board**.

Pre-flight checks 1–4 from SKILL.md run first (pre-flight check 5 is skipped — read-only, no IDs to verify). Config is read and validated as in the normal sync path (Step 1 of `sync-process.md`), but the `known_repos` and `reconcile_scope` optional keys drive audit grouping rather than mutation logic.

## Mutual exclusion

`--board-audit` is mutually exclusive with `--init` and with a positional slug.

```
argparse.add_mutually_exclusive_group()
  --board-audit
  --init
  positional slug
```

Passing `--board-audit` with `--init` OR with a slug → exit `1`:
`"issue-to-project: --board-audit takes no positional slug and cannot be combined with --init."`

`DRY_RUN=1` with `--board-audit` is accepted silently — audit is already read-only; `DRY_RUN` has no effect.

## Step 1 — Read and validate config

Identical to `sync-process.md` Step 1 config read (all required keys plus optional `known_repos` and `reconcile_scope`). Validation rules 1–7 from `config-schema.md` apply.

Extract:

```python
OWNER = gp["owner"]
NUMBER = gp["number"]
URL = gp["url"]
known_repos = gp.get("known_repos", [])
reconcile_scope = gp.get("reconcile_scope", "this-repo-only")
```

## Step 2 — Fetch all board items

```bash
AUDIT_RAW="$(GH_HOST=github.com timeout "${ITP_GH_TIMEOUT_SECONDS:-30}" \
  gh project item-list "$NUMBER" --owner "$OWNER" --format json --limit 9999 2>&1)" || {
    echo "issue-to-project: board audit item-list failed/timed-out: $AUDIT_RAW" >&2
    echo "HALT: SNAPSHOT_FAILED"
    exit 1
}
```

**Ceiling warn:** if the response returns exactly 9999 items, log:
`[issue-to-project] WARN: board-audit hit the 9999 ceiling — counts may be incomplete`
and continue (same pattern as the normal-run snapshot warn).

```python
import json
payload = json.loads(AUDIT_RAW)
items = payload.get("items", [])
total_items = len(items)
```

## Step 3 — Extract and group by repo

For each item, extract the `repository.nameWithOwner` value from the nested `content` block. Draft project items (no `content` block, or `content.repository` is null) are counted separately as `draft_items_skipped`.

```python
import collections, datetime

by_repo = collections.defaultdict(lambda: {"count": 0, "blocked": 0, "todo": 0, "in_progress": 0, "done": 0})
unknown_repos = collections.defaultdict(lambda: {"count": 0})
draft_items_skipped = 0

for item in items:
    content = item.get("content")
    if not content or not content.get("repository") or not content["repository"].get("nameWithOwner"):
        draft_items_skipped += 1
        continue

    repo_name = content["repository"]["nameWithOwner"]
    status_name = (item.get("status") or {}).get("name", "")

    # Route to known or unknown bucket
    if known_repos and repo_name not in known_repos:
        unknown_repos[repo_name]["count"] += 1
        continue

    bucket = by_repo[repo_name]
    bucket["count"] += 1
    status_lower = status_name.lower()
    if "blocked" in status_lower:
        bucket["blocked"] += 1
    elif "progress" in status_lower:
        bucket["in_progress"] += 1
    elif "done" in status_lower:
        bucket["done"] += 1
    else:
        bucket["todo"] += 1  # default: Todo, or any unmapped status name
```

**Note on `unknown_repos`:**
- When `known_repos` is empty (`[]` or absent), ALL repos are treated as known — `unknown_repos` will always be empty. This preserves v1 ergonomics where no cross-repo config means "no filtering".
- When `reconcile_scope == "all-known-repos"` and `unknown_repos` is non-empty, log a soft-warn per unknown repo:
  `[issue-to-project] WARN: board-audit found items from unknown repo <owner/repo> — not in known_repos`
- No HALT is emitted from `--board-audit` for unknown repos; the `UNKNOWN_REPO` HALT applies only to the `reconcile` path with `ITP_UNKNOWN_REPO_BEHAVIOR=error`.

## Step 4 — Write `board-audit.json`

Written to `$(git rev-parse --show-toplevel)/board-audit.json` (repo root, same directory as `.claude/config.json`). Atomic-rename via `os.replace`.

```python
import os, pathlib

artifact = {
    "schema_version": "1",
    "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "skill_version": "2.3.0",
    "project": {
        "owner": OWNER,
        "number": NUMBER,
        "url": URL,
        "total_items": total_items,
    },
    "known_repos": known_repos,
    "by_repo": {repo: dict(counts) for repo, counts in sorted(by_repo.items())},
    "unknown_repos": {repo: dict(counts) for repo, counts in sorted(unknown_repos.items())},
    "draft_items_skipped": draft_items_skipped,
}

import jsonschema
schema_path = pathlib.Path(
    "plugins/makato-plan/skills/issue-to-project/references/board-audit.schema.json"
)
schema = json.loads(schema_path.read_text())
try:
    jsonschema.validate(artifact, schema)
except jsonschema.ValidationError as e:
    print(f"issue-to-project: board-audit.json failed schema validation: {e.message}",
          file=sys.stderr)
    print("HALT: AUDIT_SCHEMA_FAILED")
    sys.exit(1)

# Resolve repo root (works inside any subdirectory of the repo)
import subprocess
repo_root = subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip()
out = pathlib.Path(repo_root) / "board-audit.json"
tmp = out.with_suffix(".json.tmp")
try:
    tmp.write_text(json.dumps(artifact, indent=2) + "\n")
    os.replace(tmp, out)
except OSError as e:
    print(f"issue-to-project: board-audit.json write failed ({e}).", file=sys.stderr)
    print("HALT: AUDIT_WRITE_FAILED")
    sys.exit(1)
```

## Step 5 — Emit return format and handoff line

```python
result = {
    "status": "ok",
    "artifact_path": "board-audit.json",
    "total_items": total_items,
    "known_repos_count": len(known_repos),
    "unknown_repos_count": len(unknown_repos),
}
print(f"RESULT: {json.dumps(result, separators=(',', ':'))}")
print("Next: review board-audit.json; unknown_repos entries (if any) should be added to known_repos "
      "in each contributing repo's github_project config.")
```

No `slug` key in the `--board-audit` RESULT; the artifact is board-wide, not slug-scoped.

## Example output artifact

```json
{
  "schema_version": "1",
  "generated_at": "2026-06-26T10:05:00Z",
  "skill_version": "2.3.0",
  "project": {
    "owner": "zstary",
    "number": 1,
    "url": "https://github.com/users/zstary/projects/1",
    "total_items": 47
  },
  "known_repos": ["zstary/repo-a", "zstary/repo-b"],
  "by_repo": {
    "zstary/repo-a": { "count": 30, "blocked": 4, "todo": 22, "in_progress": 3, "done": 1 },
    "zstary/repo-b": { "count": 15, "blocked": 1, "todo": 12, "in_progress": 1, "done": 1 }
  },
  "unknown_repos": {
    "zstary/repo-c": { "count": 2 }
  },
  "draft_items_skipped": 3
}
```

`unknown_repos` is populated only when board items carry a `repository.nameWithOwner` value not in `known_repos`. Its presence is informational; no HALT is emitted from `--board-audit` alone.

When `known_repos` is empty (single-repo or no cross-repo config), `by_repo` lists all repos found on the board, and `unknown_repos` is always `{}`.

## HALT codes (board-audit path)

| HALT code | When | Exit |
|---|---|---|
| `PREFLIGHT_FAILED` | `gh` binary missing, not authenticated, too old, or missing `project` scope | 1 |
| `MISSING_CONFIG` | `.claude/config.json` or `github_project` block absent | 1 |
| `MALFORMED_CONFIG` | Config invalid JSON, required key missing, or ID format failure | 1 |
| `SNAPSHOT_FAILED` | `gh project item-list` failed or timed out | 1 |
| `AUDIT_SCHEMA_FAILED` | `board-audit.json` failed schema validation (skill bug) | 1 |
| `AUDIT_WRITE_FAILED` | `board-audit.json` write failed for I/O reason | 1 |

`UNKNOWN_REPO` is NOT raised from `--board-audit` (it is a reconcile-path code only). `CROSS_REPO_VERIFY_FAILED` is NOT raised from `--board-audit` (check 5 is skipped for read-only audit).

## `.gitignore` guidance

`board-audit.json` is a point-in-time snapshot. Consumer repos that do not want it committed should add it to `.gitignore`:

```
# issue-to-project board-wide audit snapshot
board-audit.json
```

## Idempotency

`--board-audit` is read-only and trivially idempotent. Running it twice in a row produces two identical `board-audit.json` files (modulo `generated_at` timestamp drift).
