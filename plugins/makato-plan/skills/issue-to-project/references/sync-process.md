<!-- markdownlint-disable MD013 -->
# Normal-run sync — 5-step flow

Pre-flight checks 1–4 from SKILL.md run first. This file picks up after they pass and the slug has been resolved (argv positional or most-recently-modified `specs/*/created-issues.json`).

## Step 0.5 — Pre-flight check 5: Verify-on-first-call (v2.3.0+)

After checks 1–4 pass and after Step 1 config validation completes (so `PROJECT_NODE_ID`, `STATUS_FIELD_ID`, `OWNER`, and `NUMBER` are available), run one lightweight `gh project view` probe to confirm the cached IDs still match the live board. This catches `status_field_id` typo-drift before any mutations run.

**Skip conditions:**
- `ITP_SKIP_VERIFY=1` → log `[issue-to-project] WARN: ITP_SKIP_VERIFY=1 — skipping board ID verification` and continue.
- `--board-audit` mode → skip (read-only, no IDs to verify).
- `--init` mode → skip (IDs are being written, not validated).

```bash
VERIFY_RAW="$(timeout "${ITP_GH_TIMEOUT_SECONDS:-30}" \
  GH_HOST="${RESOLVED_HOST:-github.com}" gh project view "$NUMBER" --owner "$OWNER" --format json 2>&1)" || {
    echo "issue-to-project: board ID verify probe failed: $VERIFY_RAW. Check network/auth and retry, or re-run '--init'."
    echo "HALT: CROSS_REPO_VERIFY_FAILED"
    exit 1
}
```

Pipe the JSON output to the following Python assertion:

```python
import json, sys
d = json.load(sys.stdin)
assert d["id"] == PROJECT_NODE_ID, (
    f"issue-to-project: cached project_node_id does not match live board "
    f"({PROJECT_NODE_ID!r} vs {d['id']!r}). Re-run 'issue-to-project --init'."
)
fields = {f["id"] for f in d.get("fields", {}).get("nodes", [])}
assert STATUS_FIELD_ID in fields, (
    f"issue-to-project: cached status_field_id {STATUS_FIELD_ID!r} not found on live board. "
    "Re-run 'issue-to-project --init'."
)
```

Any assertion failure or `gh` error → exit 1 with HALT `CROSS_REPO_VERIFY_FAILED`:
- ID mismatch: `"issue-to-project: cached project_node_id or status_field_id does not match live board. Re-run 'issue-to-project --init'."`
- Probe failure: `"issue-to-project: board ID verify probe failed: <gh error>. Check network/auth and retry, or re-run '--init'."`

**Performance note:** check 5 adds one `gh project view` call (~200 ms). `DRY_RUN=1` still runs check 5 (it is a read). The original v1 `STALE_CONFIG` heuristic (2-consecutive-item-add failures) remains active as a backstop even when check 5 is skipped.

## Step 1 — Read and validate config

```python
import json, pathlib, sys
config = json.loads(pathlib.Path(".claude/config.json").read_text())
gp = config.get("github_project")
if not gp:
    sys.exit(("issue-to-project: 'github_project' block missing in .claude/config.json. "
              "Run 'issue-to-project --init' to set up project board sync.\nHALT: MISSING_CONFIG"))

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

# v2.3.0+: validate optional cross-repo fields
import re as _re
known_repos = gp.get("known_repos", [])
reconcile_scope = gp.get("reconcile_scope", "this-repo-only")

VALID_REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
for repo in known_repos:
    if not VALID_REPO_RE.match(repo):
        sys.exit(f"issue-to-project: known_repos entry {repo!r} is not in 'owner/repo' format. Re-run --init.\nHALT: MALFORMED_CONFIG")

VALID_SCOPES = {"this-repo-only", "all-known-repos"}
if reconcile_scope not in VALID_SCOPES:
    sys.exit(f"issue-to-project: reconcile_scope {reconcile_scope!r} is not valid. Must be one of: {sorted(VALID_SCOPES)}.\nHALT: MALFORMED_CONFIG")

if reconcile_scope == "all-known-repos" and not known_repos:
    print("[issue-to-project] WARN: reconcile_scope is 'all-known-repos' but known_repos is empty "
          "— all foreign items will be treated as orphans. Add known_repos entries or switch to 'this-repo-only'.")
```

## Step 2 — Read and validate input

Locate the target slug:
- If argv positional given, use `specs/<slug>/created-issues.json` exactly.
- Otherwise, glob `specs/*/created-issues.json` and pick the most recently modified.

```python
input_path = pathlib.Path(f"specs/{slug}/created-issues.json")
if not input_path.exists():
    sys.exit((f"issue-to-project: no created-issues.json found at specs/{slug}/. "
              f"Run 'to-issues {slug}' first.\nHALT: MISSING_INPUT"))

data = json.loads(input_path.read_text())
schema = json.loads(pathlib.Path(
    "plugins/makato-plan/skills/to-issues/references/created-issues.schema.json"
).read_text())
import jsonschema
try:
    jsonschema.validate(data, schema)
except jsonschema.ValidationError as e:
    sys.exit(f"issue-to-project: created-issues.json schema-invalid: {e.message}\nHALT: MALFORMED_INPUT")

issues = data["issues"]
if not issues:
    sys.exit(("issue-to-project: created-issues.json contains zero issues — "
              "wrong slug, or DRY_RUN=1 artifact committed?\nHALT: EMPTY_INPUT"))

# Deduplicate URLs (M10)
seen_urls, unique = set(), []
for it in issues:
    if it["url"] in seen_urls:
        print(f"[issue-to-project] WARN: duplicate URL in created-issues.json: {it['url']} — first occurrence wins")
        continue
    seen_urls.add(it["url"])
    unique.append(it)
issues = unique
```

**Tie-break:** if two `specs/*/created-issues.json` share the same mtime (within 1 ms) when the slug is not explicit, exit 1 with HALT `AMBIGUOUS_SLUG` and instruct the operator to pass the slug explicitly.

## Step 2.5 — Signal extraction (v2.4.0+)

After reading `created-issues.json`, extract field signals from each issue once and cache them as a per-issue `signals` dict. This step runs only when `gp.get("fields")` is present (i.e. a v2.4 config); it is skipped silently for v1-shaped configs after in-memory translation.

```python
SIZE_MAP = {"S": 1, "M": 3, "L": 8, "XL": 13}

def extract_signals(issue: dict) -> dict:
    """Extract non-Status field signals from a single issue entry.

    Returns a dict with keys: priority, iteration, estimate, date_target.
    Any signal that cannot be resolved is None — the caller treats None as no_signal.
    """
    labels = issue.get("labels", [])
    milestone = issue.get("milestone") or {}

    # Priority: first priority:* label wins; multiple → WARN
    priority_labels = [l for l in labels if l.startswith("priority:")]
    if len(priority_labels) > 1:
        print(f"[issue-to-project] WARN: issue #{issue['number']}: multiple priority:* labels — "
              f"first occurrence wins")
    priority = priority_labels[0].split(":", 1)[1] if priority_labels else None

    # Iteration: iter:* label wins over milestone title
    iter_labels = [l for l in labels if l.startswith("iter:")]
    iteration = iter_labels[0].split(":", 1)[1] if iter_labels else milestone.get("title")

    # Estimate: points:N is canonical; size:* is deprecated fallback
    estimate = None
    points_labels = [l for l in labels if l.startswith("points:")]
    size_labels   = [l for l in labels if l.startswith("size:")]
    if points_labels:
        raw = points_labels[0].split(":", 1)[1]
        try:
            estimate = int(raw)
        except ValueError:
            print(f"[issue-to-project] WARN: issue #{issue['number']}: label "
                  f"'points:{raw}' is not a valid integer — estimate skipped")
            estimate = None
    elif size_labels:
        size_val = size_labels[0].split(":", 1)[1].upper()
        estimate = SIZE_MAP.get(size_val)
        if estimate is not None:
            print(f"[issue-to-project] WARN: issue #{issue['number']}: size:* label is deprecated — "
                  f"use points:N instead")

    # Date Target: milestone due_on
    date_target = milestone.get("due_on")  # ISO-8601 date string or None

    return {
        "priority":    priority,
        "iteration":   iteration,
        "estimate":    estimate,
        "date_target": date_target,
    }

# Build signals cache (only when v2.4 fields config present)
fields_config = gp.get("fields", {})
if fields_config:
    issue_signals = {issue["url"]: extract_signals(issue) for issue in issues}
else:
    issue_signals = {}  # no-op for v1 configs
```

**`ITP_SKIP_FIELDS` handling:** if the env var is set, parse comma-separated field keys and remove them from `fields_config` in-memory before the field-write loop. Unrecognised keys emit a soft-warn:

```python
skip_fields = set(os.environ.get("ITP_SKIP_FIELDS", "").split(",")) - {""}
for key in skip_fields:
    if key not in fields_config:
        print(f"[issue-to-project] WARN: ITP_SKIP_FIELDS contains unknown field key '{key}' — ignored")
    fields_config.pop(key, None)
```

## Step 3 — Snapshot the board

```bash
SNAPSHOT_RAW="$(timeout "${ITP_GH_TIMEOUT_SECONDS:-30}" \
  GH_HOST="${RESOLVED_HOST:-github.com}" gh project item-list "$NUMBER" --owner "$OWNER" --format json --limit 9999 2>&1)" || {
    echo "issue-to-project: item-list failed/timed-out: $SNAPSHOT_RAW" >&2
    echo "HALT: SNAPSHOT_FAILED"
    exit 1
}
```

### Rate-limit guard (v2.6.0+)

Wrap every `gh project item-list`, `item-add`, and `item-edit` call. After each call, check the captured stderr+stdout for rate-limit signals:

```python
def check_rate_limit(raw_output: str, host: str) -> None:
    """Raise a halt if the output signals a rate limit."""
    # HTTP 429 is surfaced by gh as 'rate limit exceeded' in stderr
    if "rate limit exceeded" in raw_output.lower() or "429" in raw_output:
        # Extract Retry-After value if present
        import re
        retry_after = "unknown"
        m = re.search(r"retry-after:\s*(\d+)", raw_output, re.IGNORECASE)
        if m:
            retry_after = f"{m.group(1)}s"
        print(f"[issue-to-project] WARN: rate limit on {host}; Retry-After: {retry_after}")
        print(f"issue-to-project: rate limit exceeded on {host}. "
              f"Retry-After: {retry_after}. Re-run after the wait window.")
        print("HALT: RATE_LIMIT_EXCEEDED")
        sys.exit(1)
```

### TLS guard (v2.6.0+)

Check the same captured output for TLS/certificate errors:

```python
TLS_PATTERNS = ("certificate verify failed", "ssl", "x509", "tls:")

def check_tls_error(raw_output: str, host: str) -> None:
    """Raise a halt if the output signals a TLS/certificate error."""
    lower = raw_output.lower()
    if any(p in lower for p in TLS_PATTERNS):
        print(f"issue-to-project: TLS error connecting to {host}. "
              "Install the GHES CA certificate into the system trust store. "
              "See your GHES administrator.")
        print("HALT: TLS_TRUST_FAILED")
        sys.exit(1)
```

Call both guards after each `gh project` invocation in steps 3 and 4:

```python
RESOLVED_HOST = gp.get("host", "github.com")
# ... run snapshot ...
check_rate_limit(SNAPSHOT_RAW, RESOLVED_HOST)
check_tls_error(SNAPSHOT_RAW, RESOLVED_HOST)
# ... run item-add ...
check_rate_limit(ADD_RAW, RESOLVED_HOST)
check_tls_error(ADD_RAW, RESOLVED_HOST)
# ... run item-edit ...
check_rate_limit(EDIT_RAW, RESOLVED_HOST)
check_tls_error(EDIT_RAW, RESOLVED_HOST)
```

**Three shape gotchas (verified against `gh project` source):**

1. `--limit 9999` is the documented v1 ceiling. `--limit 0` does NOT mean unlimited; `gh` defaults to 30 when omitted. Boards expected to exceed 9999 items must read `gh project view --format json | .items.totalCount` first to drive the limit. If the snapshot returns exactly 9999 items, log a soft warning that the snapshot may be incomplete.
2. The per-item URL is nested at `item['content']['url']`, NOT `item['url']`. Draft project items have no `content` block — guard against `KeyError`.
3. The Status field value emitted by `item-list` is the option **name** (e.g. `"Todo"`), not the opaque option ID — that's why the snapshot dict stores `currentStatusName` (the human-readable name), not a raw option ID. The cached `options.*` IDs are write-only (consumed by `item-edit --single-select-option-id`); reads compare by name.

```python
payload = json.loads(SNAPSHOT_RAW)
items = payload.get("items", [])
if len(items) == 9999:
    print("[issue-to-project] WARN: item-list hit the 9999 ceiling — snapshot may be incomplete; "
          "consult references/sync-process.md")

snapshot = {
    item["content"]["url"]: {
        "projectItemId": item["id"],
        "currentStatusName": (item.get("status") or {}).get("name"),
    }
    for item in items
    if item.get("content") and item["content"].get("url")
}
```

### Snapshot enrichment for non-Status fields (v2.4.0+)

When `fields_config` is non-empty (v2.4 config), extend each snapshot entry with current values for all configured fields. This enables the `skipped_already_set` idempotency check in the field-write loop.

The `gh project item-list --format json` response includes field values in each item's payload. Extract them per field:

```python
if fields_config:
    for item in items:
        content = item.get("content")
        if not content or not content.get("url"):
            continue
        url = content["url"]
        # gh project item-list emits field values under each field's name key
        # in the item object. The exact key depends on the field's name in the project.
        # Build a lookup from field name → current value for all configured fields.
        field_values = {}
        for field_key, field_cfg in fields_config.items():
            if field_key == "status":
                continue  # already captured as currentStatusName
            field_name = field_cfg["name"]
            # item-list returns field values with the field's name as the key (lowercased).
            # Probe both exact-case and lower-case to handle gh version differences.
            raw_val = item.get(field_name) or item.get(field_name.lower())
            field_values[field_key] = raw_val
        snapshot[url]["fieldValues"] = field_values

# Verify all configured non-Status field IDs are live on the project
# (FIELD_NOT_FOUND check — done once before the add/edit loop)
if fields_config:
    live_field_ids = {f["id"] for f in payload.get("fields", {}).get("nodes", [])}
    for field_key, field_cfg in fields_config.items():
        if field_key == "status":
            continue  # Status id validated in pre-flight check 5
        if field_cfg["id"] not in live_field_ids:
            sys.exit(
                f"issue-to-project: cached field id for '{field_cfg['name']}' not found on "
                f"project #{gp['number']}. Re-run 'issue-to-project --init' to refresh field IDs.\n"
                f"HALT: FIELD_NOT_FOUND"
            )
```

**Note:** `gh project item-list` does not guarantee field value keys match field names in a simple dict; the actual structure depends on the `--format json` shape for the `gh` version in use. The field-write loop must treat a missing or null `fieldValues[key]` as "unknown current value" and proceed with the write (conservative side of idempotency). Only an exact match `signals[key] == fieldValues[key]` produces `skipped_already_set`.

## Step 4 — Add and (conditionally) edit each issue

For each issue NOT in `snapshot`:

```bash
ADD_RAW="$(timeout "${ITP_GH_TIMEOUT_SECONDS:-30}" \
  GH_HOST="${RESOLVED_HOST:-github.com}" gh project item-add "$NUMBER" --owner "$OWNER" --url "$ISSUE_URL" --format json 2>&1)"
```

On success, parse `{"id": "PVTI_..."}`. Then resolve the routing target from the issue's `labels[]` using the pure function below — if it returns a non-default target, follow up with an `item-edit` against the matching `options.*` ID from the config.

### `resolve_status_label` (v1.2.0 routing logic)

```python
STATUS_MAP = {
    "status:todo":        ("Todo",        None),            # no edit needed
    "status:ready":       ("Ready",       "ready"),         # NEW in v2.7
    "status:in-progress": ("In Progress", "in_progress"),
    "status:in-review":   ("In review",   "in_review"),     # NEW in v2.7
    "status:blocked":     ("Blocked",     "blocked"),
    "status:done":        ("Done",        "done"),
}
# Priority for multi-label collision (D2 v2.7). Reading the column as a workflow:
# blocked is most operationally urgent (must not be silently dropped); done > in-review >
# in-progress > ready > todo keeps a finished/late-stage item from regressing to earlier
# columns when a stale label survives a relabel.
PRIORITY = ["status:blocked", "status:done", "status:in-review",
            "status:in-progress", "status:ready", "status:todo"]
KNOWN = set(STATUS_MAP.keys())

def resolve_status_label(labels):
    """Return (status_name, options_key, used_label) for routing, or (None, None, None) for default-Todo.

    - No status:* label              → (None, None, None)          # outcome: added_default
    - One known status:* label       → STATUS_MAP[lbl] + (lbl,)    # explicit routing target
    - Multiple known status:* labels → priority winner, loud WARN
    - One unknown status:* label     → (None, None, None), loud WARN, falls through to default
    """
    matched = [lbl for lbl in labels if lbl.startswith("status:")]
    known = [lbl for lbl in matched if lbl in KNOWN]
    unknown = [lbl for lbl in matched if lbl not in KNOWN]

    if unknown and not known:
        print(f"[issue-to-project] WARN: unknown status label {unknown[0]!r} — "
              f"leaving at project default (Todo)")
        return (None, None, None)

    if not known:
        return (None, None, None)

    if len(known) > 1:
        winner = next(lbl for lbl in PRIORITY if lbl in known)
        print(f"[issue-to-project] WARN: multi-status collision {known!r} → "
              f"using {winner!r} (priority order)")
        name, opt = STATUS_MAP[winner]
        return (name, opt, winner)

    name, opt = STATUS_MAP[known[0]]
    return (name, opt, known[0])
```

`resolve_status_label` is a pure function — no I/O, no live GitHub queries. The only routing signal is `created-issues.json`'s `labels[]` array (Hard Guarantee 3).

### Ready-queue ownership mode (D10) — v2.7.0+

`Ready` is the **handoff queue between user and orchestrator**. Issues land in `Ready` when they are scoped, triaged, and ready for an orchestrator to pick up. The skill supports two ownership modes via the optional config key `ready_queue_mode` (default: `"manual"`):

| Mode | Who promotes Todo → Ready | When |
|---|---|---|
| `"manual"` (default) | The user, via UI or via setting `status:ready` in `created-issues.json` | The skill never auto-promotes a `Todo` item to `Ready`. The `Ready` column is strictly user-driven. |
| `"autonomous"` | The skill itself, applying the auto-promotion rule | Items not currently `Blocked`, not `In progress`/`In review`/`Done`, not awaiting human decision (no `needs-human-review` label), and not carrying any explicit `status:*` label are promoted to `Ready` on every normal-run pass. |

Auto-promotion rule (autonomous mode only):

```python
# The orchestrator-handoff marker stamped by THIS skill after a successful
# auto-promotion (v2.8.0+, see "Ready-label stamp on autonomous promotion (D11)"
# below). It is NOT a board-routing instruction and must NOT block auto-promotion,
# unlike every other status:* label (which encode operator/upstream intent).
READY_FOR_DEV_LABEL = "status:ready-for-dev"

def auto_promote_to_ready(issue_labels: list[str], current_board_status: str | None) -> bool:
    """Return True when an item should be auto-promoted Todo → Ready in autonomous mode."""
    # Hard guards: never override an externally-set non-Todo Status (v1 hard guarantee, narrowed for autonomous mode).
    # NOTE: this passes for current_board_status in (None, "Todo"). A human who manually
    # drags a card from Ready → Todo will be re-promoted on the next autonomous run unless
    # an explicit signal label is added. See the "Manual-demote escape hatch" note below.
    if current_board_status not in (None, "Todo"):
        return False
    # Skip if the issue carries any explicit status:* label OTHER THAN the
    # orchestrator-handoff marker status:ready-for-dev — that label is the user's intent.
    # Idempotency for re-runs is guaranteed by the board-state guard above: once an item
    # is promoted, its currentStatusName is "Ready", so `current_board_status not in
    # (None, "Todo")` returns False before we reach here. Exempting the handoff marker
    # therefore does NOT re-promote already-Ready items; it only lets an issue that
    # carries the marker (e.g. seeded ahead of the run) still reach Ready. Every other
    # status:* label (status:todo, status:blocked, …) still blocks — that is operator intent.
    if any(l.startswith("status:") and l != READY_FOR_DEV_LABEL for l in issue_labels):
        return False
    # Skip if the issue is flagged for human review.
    if "needs-human-review" in issue_labels:
        return False
    # Skip if blocked by dependency labels (e.g. `blocked-by:#42`).
    if any(l.startswith("blocked-by:") for l in issue_labels):
        return False
    # Skip if the operator has explicitly opted this issue out of auto-promotion.
    if "hold-in-todo" in issue_labels:
        return False
    return True
```

**Manual-demote escape hatch.** Autonomous mode cannot distinguish between a never-touched `Todo` and a human-demoted `Todo` from board state alone. Operators who need to keep a specific item at `Todo` without auto-promotion must add one of these signal labels: `status:todo` (explicit user intent — wins over auto-promotion), `needs-human-review` (flag for human decision), `hold-in-todo` (v2.7-introduced opt-out marker recognized by `auto_promote_to_ready()`), or any `blocked-by:*` label. **Note (v2.8.0+):** `status:ready-for-dev` does **not** suppress auto-promotion — it is the orchestrator-handoff marker this skill stamps *after* promoting, and is explicitly exempted from the `status:*` block guard. Operators who want to block a `Todo` item must use one of the four signals above, never `status:ready-for-dev`.

**`[issue-to-project:auto]` log prefix.** Autonomous-mode log lines use the `[issue-to-project:auto]` prefix to distinguish inference decisions from explicit user-driven routing:

- Successful promotions: `[issue-to-project:auto] issue #N: auto-promoted Todo → Ready (autonomous mode; no human signals on issue)`
- Skip lines (one per False return): `[issue-to-project:auto] issue #N: skip auto-promote — reason: <reason_code>`

Skip reason codes: `status_label_present`, `needs_human_review`, `blocked_by_label_present`, `current_status_not_promotable`. The `:auto` prefix is gated entirely behind `ready_queue_mode == "autonomous"` — manual-mode operators see no `:auto` prefix lines.

**Manual-mode invariant.** When `ready_queue_mode == "manual"`, the skill NEVER writes `Ready` autonomously. The only paths into `Ready` are:

1. A `status:ready` label in `created-issues.json` (operator-set).
2. A user moving the card on the UI.
3. A `reconcile --repair-aggressive` run that brings the board in line with a `status:ready` label.

This invariant gives manual-mode operators the same control over `Ready` as v1.2 gives over `Blocked`.

**Idempotency contract amendment for autonomous mode.** When `ready_queue_mode == "autonomous"`, items in the step-3 snapshot whose `current_board_status == "Todo"` (or absent) are **not** exempted from the status-write path — `auto_promote_to_ready()` may write `Ready` over `Todo`. This is the **only** narrowing of the v1 re-run guard in v2.7. The hard guarantee that the skill never overwrites an **externally non-Todo** Status is preserved: items at `Ready`, `In progress`, `Blocked`, `In review`, or `Done` are still skipped. Manual mode is unchanged from v1.

### Behavior changes vs v1.2.0

| Input labels | v1.2.0 outcome | v2.7.0 outcome |
|---|---|---|
| `["status:ready"]` | `added_default` + WARN unknown | `added_ready` (when `options.ready` present) OR `added_default` + WARN (when absent) |
| `["status:in-review"]` | `added_default` + WARN unknown | `added_in_review` (when `options.in_review` present) OR `added_default` + WARN |
| `["status:ready", "status:blocked"]` | `added_blocked` + WARN collision | `added_blocked` + WARN collision (priority unchanged for blocked) |
| `["status:in-review", "status:in-progress"]` | `added_in_progress` + WARN unknown for in-review | `added_in_review` + WARN collision (in-review wins over in-progress) |
| `["status:done", "status:in-review"]` | `added_done` + WARN unknown | `added_done` + WARN collision (done wins) |

The collision-priority change for the `in-review × in-progress` and `in-review × ready` cases is the **only behavioral regression** for v1.2.0 consumers that were already manually adding `status:in-review` labels and relying on the v1.2 silent-fallback-to-Todo behavior.

### Edit invocation

When `resolve_status_label` returns an options key (i.e. target != Todo), issue exactly one `item-edit`:

```bash
EDIT_RAW="$(timeout "${ITP_GH_TIMEOUT_SECONDS:-30}" \
  GH_HOST="${RESOLVED_HOST:-github.com}" gh project item-edit \
    --id "$PROJECT_ITEM_ID" \
    --project-id "$PROJECT_NODE_ID" \
    --field-id "$STATUS_FIELD_ID" \
    --single-select-option-id "$TARGET_OPTION_ID" 2>&1)"
```

`$TARGET_OPTION_ID` is `gp["options"][options_key]` for the resolved `options_key` (one of `in_progress`, `blocked`, `done`, `ready`, `in_review` — the `status:todo` path returns `options_key=None` and skips this entire step).

**Absent-option fallback (v2.7.0+).** When `resolve_status_label()` returns an `options_key` that is absent from `gp["options"]` (e.g. `options.ready` missing on a v1.0–v2.6 config), the skill emits a loud WARN and falls through to `added_default`:

```text
[issue-to-project] WARN: status label 'status:ready' resolved to option 'ready' but options.ready is absent from .claude/config.json — leaving at project default (Todo). Re-run 'issue-to-project --init' to cache the optional Status options.
```

The same message shape applies to `options.in_review` when `status:in-review` is resolved. This makes v2.7 strictly forward-compatible — operators upgrade the skill first, then re-run `--init` at their leisure to enable the new routes.

**Outcome routing:**

| Condition | `outcome` | `needs_status_retry` | `final_status` |
|---|---|---|---|
| Already in snapshot | `already_on_board` | false | snapshot's `currentStatusName` |
| `item-add` ok, no `status:*` label or unknown `status:*` | `added_default` | false | `"Todo"` |
| `item-add` ok, `status:todo` in labels | `added_todo_explicit` | false | `"Todo"` |
| `item-add` ok, `status:in-progress` resolved, `item-edit` ok | `added_in_progress` | false | `"In Progress"` |
| `item-add` ok, `status:in-progress` resolved, `item-edit` failed | `added_in_progress_edit_failed` | **true** | `"Todo"` |
| `item-add` ok, `status:blocked` resolved, `item-edit` ok | `added_blocked` | false | `"Blocked"` |
| `item-add` ok, `status:blocked` resolved, `item-edit` failed | `added_blocked_edit_failed` | **true** | `"Todo"` |
| `item-add` ok, `status:done` resolved, `item-edit` ok | `added_done` | false | `"Done"` |
| `item-add` ok, `status:done` resolved, `item-edit` failed | `added_done_edit_failed` | **true** | `"Todo"` |
| `item-add` ok, `status:ready` resolved, `item-edit` ok | `added_ready` | false | `"Ready"` |
| `item-add` ok, `status:ready` resolved, `item-edit` failed | `added_ready_edit_failed` | **true** | `"Todo"` |
| `item-add` ok, `status:in-review` resolved, `item-edit` ok | `added_in_review` | false | `"In review"` |
| `item-add` ok, `status:in-review` resolved, `item-edit` failed | `added_in_review_edit_failed` | **true** | `"Todo"` |
| `item-add` ok, autonomous mode, `auto_promote_to_ready()` True, `item-edit` ok | `auto_promoted_ready` | false | `"Ready"` |
| `item-add` ok, autonomous mode, `auto_promote_to_ready()` True, `item-edit` failed | `auto_promoted_ready_edit_failed` | **true** | `"Todo"` |
| `item-add` failed | `add_failed` | false | null |
| Batch aborted by stale-`project_node_id` heuristic | `skipped_after_total_failure` | false | null |
| `DRY_RUN=1`, would have added | `dry_run` | false | null |
| Auto-reinit fired; `item-add` succeeded after new IDs resolved | `recovered_via_auto_reinit` | false | `"Todo"` or `"Blocked"` per label routing |

**Stale-`project_node_id` early-abort (D13):** unchanged from v1.0.0 — if the first 2 consecutive `item-add` calls fail AND each error contains `PVT_`, `not found`, or `was deleted`, mark all remaining issues as `skipped_after_total_failure`, set HALT `STALE_CONFIG`, message: `"issue-to-project: cached project_node_id appears stale or the project was archived/deleted. Re-run 'issue-to-project --init'."` Exit 1 after step 5 writes the artifact.

**Step 4a — Auto-re-init sub-path (v2.5.0+, opt-in via `--auto-reinit`)**

When the stale-config trigger fires (2 consecutive `item-add` failures matching the stale-id pattern), before emitting HALT `STALE_CONFIG`, check whether auto-reinit is enabled:

- If `--no-auto-reinit` is in argv (v2.5 no-op but parsed): log `[issue-to-project] INFO: --no-auto-reinit has no effect in v2.5; auto-reinit defaults OFF` and proceed to HALT `STALE_CONFIG` (v1 behavior).
- If `--auto-reinit` is NOT in argv (v2.5 default OFF): proceed to HALT `STALE_CONFIG` (v1 behavior).
- If `--auto-reinit` IS in argv: enter the auto-re-init sub-path below.

Load `references/auto-reinit-process.md` for the full sub-path procedure. High-level summary:

```
Auto-reinit sub-path (entered when --auto-reinit is active and stale trigger fires):
  1. Check title migration: if github_project.title absent, run
       GH_HOST="${RESOLVED_HOST:-github.com}" gh project view <number> --owner <owner> --format json
     to fetch and cache the title. On timeout/failure: log WARN, skip auto-reinit,
     fall through to HALT STALE_CONFIG with note "auto-reinit skipped: title not cached".

  2. Run: GH_HOST="${RESOLVED_HOST:-github.com}" gh project list --owner <owner> --format json --limit ${PROJECT_LIST_LIMIT:-50}
     Filter: entry.number == cached.number AND entry.title ~= cached.title (case-insensitive).
     - Zero matches       → HALT AMBIGUOUS_REINIT (project not found)
     - Title mismatch     → HALT AMBIGUOUS_REINIT (title changed)
     - 2+ matches         → HALT AMBIGUOUS_REINIT (API invariant violated)
     - Owner type changed → HALT AMBIGUOUS_REINIT (structural change)

  3. Run: GH_HOST="${RESOLVED_HOST:-github.com}" gh project field-list <number> --owner <owner> --format json
     Validate: Status field present, same name, same 4 option names (case-insensitive: Todo, In Progress, Done, Blocked).
     Mismatch → HALT AMBIGUOUS_REINIT (field structure drift).

  4. Extract new project_node_id, status_field_id, options.*.
     If new project_node_id == old project_node_id → idempotency guard: log INFO and resume (no write needed).

  5. Write updated github_project block to .claude/config.json:
     - Update: project_node_id, status_field_id, options.*, url
     - Append: reinit_timestamp, reinit_skill_version, reinit_reason
     - Preserve: init_timestamp, init_skill_version (IMMUTABLE)
     - DRY_RUN=1: suppress write; record new_project_node_id: "dry_run_not_written"
     - Write failure → HALT INIT_FAILED

  6. Append entry to auto_reinit_log in the artifact (written in step 5).

  7. Resume item-add loop from the first-failed issue with new IDs.
     If new IDs are ALSO stale → HALT STALE_CONFIG_PERSISTENT (no retry loop).
```

**Logging (exact text):**

```
[issue-to-project] INFO: stale-config trigger fired after 2 consecutive item-add failures
[issue-to-project] INFO: auto-reinit: searching for project #<N> under owner <owner>
[issue-to-project] INFO: auto-reinit: matched project #<N> "<title>" — new node_id <PVT_new>
[issue-to-project] INFO: auto-reinit: Status field and options unchanged — proceeding
[issue-to-project] INFO: auto-reinit: config updated; resuming item-add from issue #<N>
```

On `AMBIGUOUS_REINIT`, log the mismatch detail at WARN level before the HALT line.

**Soft-warn messages (exact text):**

```
[issue-to-project] WARN: issue #<N>: item-add failed: <error>
[issue-to-project] WARN: issue #<N>: status edit to '<Status Name>' failed after add: <error>. Item is on board at default Status. Re-run will NOT retry this edit (idempotency contract). Recovery: 'issue-to-project --retry-blocked-edits' (since v1.1.0), OR delete the project item via 'gh project item-delete' and re-run, OR set Status manually in the GitHub Project UI.
[issue-to-project] WARN: unknown status label '<lbl>' — leaving at project default (Todo)
[issue-to-project] WARN: multi-status collision <[lbl, ...]> → using '<winner>' (priority order)
```

The "<Status Name>" placeholder above is one of `"In Progress"`, `"Blocked"`, `"Done"`, `"Ready"`, `"In review"` — never `"Todo"` (the Todo path issues no `item-edit`).

### Call-site dispatch for autonomous mode (v2.7.0+)

The auto-promotion check is dispatched **after** `resolve_status_label()` returns `(None, None, None)` for an issue with no status label, and **before** the item-edit branch:

```python
# Inside the step-4 loop, per-issue, after item-add ok:
status_name, option_key = resolve_status_label(issue["labels"])[:2]
if status_name is None and ready_queue_mode == "autonomous":
    # NOTE (v2.8.0): the step-3 snapshot is keyed by issue URL string
    # (item["content"]["url"]) and stores the human-readable Status under
    # "currentStatusName" (see step 3). Look it up by URL, not by the integer
    # issue number, and read "currentStatusName", not "status". The pre-v2.8
    # `snapshot.get(issue["number"], {}).get("status")` always returned None
    # (int key never matches a URL-string key), so guard 1 of
    # auto_promote_to_ready() never fired for already-on-board items — latent
    # because autonomous mode had no exercised call-site until the D11 stamp
    # below. With the correct key an item already at Ready/In progress/… is
    # correctly skipped instead of being re-promoted over its live Status.
    current = snapshot.get(issue["url"], {}).get("currentStatusName")  # None if new-add, else live board Status
    if auto_promote_to_ready(issue["labels"], current):
        status_name, option_key = ("Ready", "ready")
        # Emit auto-promote log line and prepare auto_promoted_ready outcome.
    else:
        log_skip_reason(issue, current)  # emits [issue-to-project:auto] skip line with reason code
# else: manual mode OR label-driven routing — proceed as v2.6.

if status_name is None:
    # No promotion, no label match → left at project default (Todo).
    outcome = "added_default"
    summary["left_default"] += 1
else:
    # Existing v1.0 item-edit path; outcome is one of added_*, added_*_edit_failed,
    # auto_promoted_ready, auto_promoted_ready_edit_failed.
    ...
```

Autonomous-mode evaluations that return False emit `outcome: "added_default"` (no behavioral change vs manual mode for skipped items) and increment `left_default`. Each False return also emits an `[issue-to-project:auto]` skip line so operators can grep for the rejection reason (reason codes: `status_label_present`, `needs_human_review`, `blocked_by_label_present`, `current_status_not_promotable`).

When `auto_promote_to_ready()` returns True, the skill emits `outcome: "auto_promoted_ready"` (new in v2.7), writes the `Ready` Status, and adds a clear log line:

```text
[issue-to-project:auto] issue #N: auto-promoted Todo → Ready (autonomous mode; no human signals on issue)
```

Autonomous-mode promotions are surfaced in the new R1 sentinel key `auto_promoted_ready` (integer count). Operators can audit by grepping `project-sync.json` for `outcome: "auto_promoted_ready"`.

### Ready-label stamp on autonomous promotion (D11) — v2.8.0+

When autonomous mode auto-promotes a `Todo` item to `Ready`, the skill stamps a repo label (`ready_label_name`, default `status:ready-for-dev`) on the issue so the downstream orchestrator (`makato-orchestrate` po-agent / loop) has a passive, greppable marker that this issue was handed off for development. This mirrors the **PR-label stamp** contract (see `lifecycle-process.md` Step 4.5): additive, idempotent at the GitHub API level, and **never removed** by the skill.

The stamp fires **only** on the `auto_promoted_ready` outcome, **only** in `ready_queue_mode == "autonomous"`, and **only** when `ready_label_name` is non-empty. It is never emitted by `sync-lifecycle` or `--from-webhook` (those cover PR-driven transitions via `pr_label_name`). Insert this block immediately after the item-edit that writes `Ready` succeeds and `outcome = "auto_promoted_ready"` is set:

```python
# D11 (v2.8.0+): stamp the ready-for-dev handoff marker after a successful auto-promotion.
ready_label_name = gp.get("ready_label_name", "status:ready-for-dev")

if outcome == "auto_promoted_ready" and ready_label_name != "":
    # Derive issue number + owner/repo from the issue URL for the `gh issue edit` call.
    # sync-process.md's board mutations use `gh project item-edit` (project-scoped, --owner
    # $OWNER / --id $PROJECT_ITEM_ID), so no gh_owner/gh_repo/issue_number are in scope here —
    # unlike lifecycle-process.md. Parse them from issue["url"] the same way lifecycle Step 2 does:
    # "https://github.com/<owner>/<repo>/issues/<number>".
    _url_parts = issue["url"].rstrip("/").split("/")
    gh_owner, gh_repo, issue_number = _url_parts[-4], _url_parts[-3], _url_parts[-1]
    label_cmd = (
        f"GH_HOST={RESOLVED_HOST} gh issue edit {issue_number} "
        f"--repo {gh_owner}/{gh_repo} --add-label \"{ready_label_name}\""
    )
    label_result = subprocess.run(
        label_cmd, shell=True, capture_output=True, text=True,
        timeout=int(os.environ.get("ITP_GH_TIMEOUT_SECONDS", 30)),
    )
    if label_result.returncode == 0:
        row["ready_label_action"] = "added"
        print(f"[issue-to-project:auto] issue #{issue_number}: stamped label '{ready_label_name}' (ready-for-dev handoff marker)")
    else:
        first_err_line = (label_result.stderr or "").splitlines()[0] if label_result.stderr else "unknown error"
        row["ready_label_action"] = "failed"
        row["ready_label_error"] = first_err_line
        print(
            f"[issue-to-project] WARN: issue #{issue_number}: could not stamp label "
            f"'{ready_label_name}': {first_err_line}",
            file=sys.stderr,
        )
        # Soft-warn: label failure does NOT block or roll back the Status flip.
else:
    row["ready_label_action"] = None
    row["ready_label_error"] = None
```

Notes:

- **Empty-string sentinel.** `ready_label_name == ""` disables the stamp entirely (same D9 pattern as `pr_label_name`); `ready_label_action` is then `None` for every row.
- **Guard interaction.** Because `auto_promote_to_ready()` exempts `status:ready-for-dev` from its `status:*` block (see the D10 guard above), an issue that already carries the marker is still eligible for promotion — but on a re-run the board-state guard (`current_board_status not in (None, "Todo")`) fires first once the item is at `Ready`, so no spurious re-stamp occurs. Re-stamping an already-labeled issue would in any case be an idempotent no-op at the GitHub API.
- **Collision with `pr_label_name`.** If an operator sets `ready_label_name` equal to `pr_label_name`, both features stamp the same label at different lifecycle moments — harmless but ambiguous for auditing. `--init` warns on this collision (see `init-wizard.md` Step 6e).

Autonomous ready-label stamps are surfaced in two new summary counters: `ready_label_stamped` (successful `--add-label` calls) and `ready_label_failed` (soft-warn failures). Both are always present with at least `0`; in manual mode they are always `0` because the D11 block is gated behind `ready_queue_mode == "autonomous"`.

**DRY_RUN=1 behavior:** step 3 (the snapshot) still runs (read-only). For each issue, classify as `already_on_board` if its URL is in the snapshot, otherwise `dry_run`. The `cli_command` field is populated with the literal command(s) that would have been issued — for issues routed to a non-default Status, this is the `item-add` followed by `&& ` and the `item-edit` (joined into one shell line) so a single copy-paste reproduces the intent. Step 5 still writes the artifact; exit 0.

### Field-write loop (v2.4.0+)

After the `item-add` (and optional Status `item-edit`) succeeds for an issue, run the field-write loop. The loop iterates `fields_config` (minus Status, minus `ITP_SKIP_FIELDS` keys) and emits one `gh project item-edit` per field with a resolved value.

Load `references/field-type-routing.md` for the per-type write call reference, signal resolution rules, and the `SIZE_MAP` constant.

```python
def run_field_write_loop(issue_url, project_item_id, signals, snapshot_entry, fields_config, gp):
    """Write all configured non-Status fields for one issue.

    Returns a list of per-field outcome dicts matching the fields[] schema shape.
    """
    field_outcomes = []
    field_values = (snapshot_entry or {}).get("fieldValues", {})

    for field_key, field_cfg in fields_config.items():
        if field_key == "status":
            continue  # Status handled by the main add/edit path

        field_name    = field_cfg["name"]
        field_type    = field_cfg["type"]
        field_id      = field_cfg["id"]
        signal_value  = signals.get(field_key)

        # DRY_RUN=1: skip actual write
        if os.environ.get("DRY_RUN") == "1":
            field_outcomes.append({
                "name": field_name, "intended_value": signal_value,
                "current_value": None, "outcome": "dry_run", "error": None,
            })
            continue

        # No signal → no_signal (leave field at project default)
        if signal_value is None:
            field_outcomes.append({
                "name": field_name, "intended_value": None,
                "current_value": field_values.get(field_key),
                "outcome": "no_signal", "error": None,
            })
            continue

        # Idempotency: skip if already at target
        current = field_values.get(field_key)
        if current is not None and current == signal_value:
            print(f"[issue-to-project] issue #{issue_number}: {field_name} → "
                  f"{signal_value!r} (skipped_already_set)")
            field_outcomes.append({
                "name": field_name, "intended_value": signal_value,
                "current_value": current, "outcome": "skipped_already_set", "error": None,
            })
            continue

        # Unsupported type (should be caught at config-validation time, but guard here)
        SUPPORTED_TYPES = {"single-select", "iteration", "number", "date"}
        if field_type not in SUPPORTED_TYPES:
            field_outcomes.append({
                "name": field_name, "intended_value": signal_value,
                "current_value": current, "outcome": "unsupported_type", "error": None,
            })
            continue

        # Resolve the write flag for this field type (see field-type-routing.md)
        write_flag, write_value, resolve_error = resolve_field_write(
            field_key, field_cfg, signal_value, gp
        )
        if resolve_error:
            print(f"[issue-to-project] WARN: issue #{issue_number} field '{field_name}': "
                  f"could not resolve write value: {resolve_error}")
            field_outcomes.append({
                "name": field_name, "intended_value": signal_value,
                "current_value": current, "outcome": "no_signal", "error": resolve_error,
            })
            continue

        # Issue the item-edit call
        edit_cmd = (
            f"timeout {os.environ.get('ITP_GH_TIMEOUT_SECONDS', '30')} "
            f"GH_HOST={os.environ.get('RESOLVED_HOST', 'github.com')} gh project item-edit "
            f"--id {project_item_id} "
            f"--project-id {gp['project_node_id']} "
            f"--field-id {field_id} "
            f"{write_flag} {write_value}"
        )
        edit_raw = subprocess.run(edit_cmd, shell=True, capture_output=True, text=True)
        if edit_raw.returncode != 0:
            err = edit_raw.stdout + edit_raw.stderr
            print(f"[issue-to-project] WARN: issue #{issue_number} field '{field_name}': "
                  f"write failed: {err.strip()}")
            field_outcomes.append({
                "name": field_name, "intended_value": signal_value,
                "current_value": current, "outcome": "write_failed", "error": err.strip(),
            })
        else:
            print(f"[issue-to-project] issue #{issue_number}: {field_name} → {signal_value!r} (set)")
            field_outcomes.append({
                "name": field_name, "intended_value": signal_value,
                "current_value": signal_value, "outcome": "set", "error": None,
            })

    return field_outcomes
```

**Per-field outcome enum (v2.4.0):**

| `outcome` | When |
|---|---|
| `set` | Write call succeeded; `current_value` confirmed from write response |
| `skipped_already_set` | Snapshot showed field already at target value; no write issued |
| `no_signal` | No source signal for this field in this issue; field left at project default |
| `write_failed` | `item-edit` for this field failed; `error` non-null |
| `unsupported_type` | Field `type` not in v2.4 write matrix; logged, skipped |
| `dry_run` | `DRY_RUN=1` was set; write not issued |

**`--fields-only` mode:** when `--fields-only` is in argv, the item-add step is skipped entirely. For each issue, check whether its URL is in the snapshot:
- If present → run the field-write loop as normal.
- If absent → record `outcome: "not_on_board_skipped"` with `fields: []`; log `[issue-to-project] WARN: issue #N not on board — skipped (--fields-only mode)`.

**Iteration field resolution note:** the Iteration field's `write_value` is a live iteration ID fetched at run start, not cached in config (iteration IDs change as sprints roll). Load `references/field-type-routing.md` for the `resolve_field_write` implementation, including the one-time `gh project iteration-list` call that builds the title → ID map.

## Step 5 — Write the audit artifact (overwrite-with-atomic-rename)

```python
import datetime, jsonschema, json, os, pathlib

ADDED_OUTCOMES = {
    "added_default", "added_todo_explicit",
    "added_in_progress", "added_in_progress_edit_failed",
    "added_blocked", "added_blocked_edit_failed",
    "added_done", "added_done_edit_failed",
    "added_ready", "added_ready_edit_failed",           # v2.7.0+
    "added_in_review", "added_in_review_edit_failed",  # v2.7.0+
    "auto_promoted_ready", "auto_promoted_ready_edit_failed",  # v2.7.0+ autonomous only
    "recovered_via_auto_reinit",  # v2.5.0+
}
LEFT_DEFAULT_OUTCOMES = {
    # Outcomes where the item is on the board at the project default (Todo).
    # added_todo_explicit is NOT in this set — it has its own bucket (set_todo).
    "added_default",
    "added_in_progress_edit_failed",
    "added_blocked_edit_failed",
    "added_done_edit_failed",
    "added_ready_edit_failed",           # v2.7.0+
    "added_in_review_edit_failed",       # v2.7.0+
    "auto_promoted_ready_edit_failed",   # v2.7.0+
}
EDIT_FAILED_OUTCOMES = {
    "added_in_progress_edit_failed",
    "added_blocked_edit_failed",
    "added_done_edit_failed",
    "added_ready_edit_failed",           # v2.7.0+
    "added_in_review_edit_failed",       # v2.7.0+
    "auto_promoted_ready_edit_failed",   # v2.7.0+
}

def count(outcomes):
    return sum(1 for r in results if r["outcome"] in outcomes)

# Aggregate field-write counts (v2.4.0+)
field_writes_attempted = sum(
    1
    for r in results
    for fo in r.get("fields", [])
    if fo["outcome"] not in ("no_signal", "skipped_already_set", "unsupported_type")
)
field_writes_succeeded = sum(
    1
    for r in results
    for fo in r.get("fields", [])
    if fo["outcome"] == "set"
)
field_writes_failed = sum(
    1
    for r in results
    for fo in r.get("fields", [])
    if fo["outcome"] == "write_failed"
)

artifact = {
    "schema_version": "2.8",  # v2.8.0+: ready-for-dev label stamp (ready_label_* fields + summary keys); v2.7.0+ added autonomous outcomes/summary keys/per-row fields
    "slug": slug,
    "retry_source": None,
    "project": {
        "owner": gp["owner"], "number": gp["number"], "url": gp["url"],
        "host": gp.get("host", "github.com"),  # v2.6.0+: always written; defaults to "github.com" for v1 configs
    },
    # v2.5.0+: include auto_reinit_log only when auto-reinit fired this run
    # "auto_reinit_log": [{"timestamp": "...", "old_project_node_id": "...",
    #                       "new_project_node_id": "...", "trigger_reason": "..."}],
    "summary": {
        "issues_in_input":            len(issues),
        "already_on_board":           count({"already_on_board"}),
        "added":                      count(ADDED_OUTCOMES),
        "set_todo":                   count({"added_todo_explicit"}),
        "set_ready":                  count({"added_ready"}),               # v2.7.0+
        "set_in_progress":            count({"added_in_progress"}),
        "set_in_review":              count({"added_in_review"}),            # v2.7.0+
        "set_blocked":                count({"added_blocked"}),
        "set_done":                   count({"added_done"}),
        "auto_promoted_ready":        count({"auto_promoted_ready"}),        # v2.7.0+ autonomous only
        # v2.8.0+ ready-for-dev label stamp counters (keyed on per-row ready_label_action, like pr_label_*).
        # Always present with at least 0; always 0 in manual mode (D11 block is autonomous-gated).
        "ready_label_stamped":        sum(1 for r in results if r.get("ready_label_action") == "added"),
        "ready_label_failed":         sum(1 for r in results if r.get("ready_label_action") == "failed"),
        "left_default":               count(LEFT_DEFAULT_OUTCOMES),
        "add_failed":                 count({"add_failed"}),
        "edit_failed":                count(EDIT_FAILED_OUTCOMES),
        "dry_run":                    count({"dry_run"}),
        "skipped_after_total_failure":count({"skipped_after_total_failure"}),
        "retry_attempted":            0,
        "retry_succeeded":            0,
        "retry_failed":               0,
        "retry_item_gone":            0,
        # v2.4.0+ field-write summary keys
        "field_writes_attempted":     field_writes_attempted,
        "field_writes_succeeded":     field_writes_succeeded,
        "field_writes_failed":        field_writes_failed,
        # v2.5.0+ auto-reinit summary key (0 when auto-reinit did not fire)
        "recovered":                  count({"recovered_via_auto_reinit"}),
    },
    "results": results,  # Each result row now carries a fields[] array (see below)
}
```

### `fields[]` array on each result row (v2.4.0+)

Each result row in `results` gains a `fields` key — an array of per-field outcome dicts, one entry per key in `fields_config`. The array is always present when `fields_config` is non-empty; it is an empty list `[]` for `already_on_board` items (whose field writes are skipped by the idempotency contract) and for `add_failed` items (no `project_item_id` to write against).

Example result row (v2.4):

```json
{
  "issue_number": 47,
  "url": "https://github.com/zstary/sagibeast/issues/47",
  "labels": ["type:feat", "priority:p1", "points:3"],
  "outcome": "added_default",
  "project_item_id": "PVTI_lAHOA6Q…",
  "final_status": "Todo",
  "needs_status_retry": false,
  "fields": [
    {
      "name": "Status",
      "intended_value": "Todo",
      "current_value": "Todo",
      "outcome": "set",
      "error": null
    },
    {
      "name": "Priority",
      "intended_value": "p1",
      "current_value": "p1",
      "outcome": "set",
      "error": null
    },
    {
      "name": "Estimate",
      "intended_value": 3,
      "current_value": 3,
      "outcome": "set",
      "error": null
    },
    {
      "name": "Iteration",
      "intended_value": null,
      "current_value": null,
      "outcome": "no_signal",
      "error": null
    }
  ],
  "cli_command": null,
  "error": null
}
```

The `final_status` key is kept in v2.4 as a backward-compat alias for `fields[name="Status"].current_value`. It will be removed in v2.5.

**v2.3.0+ cross_repo block** inclusion logic is unchanged — included only when `known_repos` is configured.

```python
# v2.3.0+: include cross_repo block only when known_repos is configured
if known_repos:
    artifact["cross_repo"] = {
        "known_repos": known_repos,
        "reconcile_scope": reconcile_scope,
        "verify_on_first_call": {
            "ran": not bool(os.environ.get("ITP_SKIP_VERIFY")),
            "passed": verify_passed,           # True if check 5 ran and passed; False if skipped
            "cached_project_node_id_valid": verify_passed,
            "cached_status_field_id_valid": verify_passed,
        },
    }
# When known_repos is absent, cross_repo key is omitted entirely (not set to null)
# so v1 consumers reading a v2.4.0 artifact with no cross-repo config see no unexpected keys.
```

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
          f"Board sync DID happen — see GitHub Project board for actual state.", file=sys.stderr)
    print("HALT: AUDIT_WRITE_FAILED")
    sys.exit(1)
```

**Summary semantics:**

- `set_todo` counts ONLY issues with an explicit `status:todo` label that received `added_todo_explicit`.
- `left_default` counts issues that landed at Todo because they had no `status:*` label, had an unknown `status:*` label, OR had a known non-Todo label whose `item-edit` failed (the item is on the board at default Todo, awaiting retry). In autonomous mode, False returns of `auto_promote_to_ready()` also increment `left_default` and each emits a `[issue-to-project:auto]` skip line with a reason code.
- `set_todo + left_default` = total issues currently at Todo on the board after this run.
- `edit_failed` is the **combined** count across all edit-failed outcomes (blocked, in-progress, done, ready, in-review, auto-promoted-ready). For per-target breakdown, scan `results[].outcome`.
- `retry_*` summary keys are present in all v1.2 artifacts but always `0` for normal-run artifacts; they're populated only by `--retry-blocked-edits` (see `references/retry-process.md`).
- `retry_source` is `null` on normal-run artifacts; populated on `--retry-blocked-edits` artifacts.
- `field_writes_attempted` counts writes issued for non-Status fields (excludes `no_signal`, `skipped_already_set`, `unsupported_type`, and `dry_run`). Zero when no `fields` config.
- `field_writes_succeeded` counts `outcome: "set"` field entries across all result rows.
- `field_writes_failed` counts `outcome: "write_failed"` field entries. `status: "partial"` fires when this is > 0.

**`status: "partial"` triggers (v2.4 extension):** the RESULT `status` is `"partial"` when `field_writes_failed > 0`, even if `add_failed == 0` and `edit_failed == 0`. Total field-write failure alone does not escalate to exit 1.

**Ordering rule:** step 5 ALWAYS runs (even if every step-4 item failed). Evaluate the batch-wide exit code (TOTAL_SYNC_FAILED) only AFTER step 5 completes, so callers catching exit 1 still get an artifact.

## Step 6 — Emit return format and handoff line

After step 5 succeeds, emit the R1 sentinel as the second-to-last line:

```python
result = {
    "status": (
        "failed" if exit_code == 1 else
        "partial" if (summary["add_failed"] or summary["edit_failed"] or summary["field_writes_failed"]) else
        "ok"
    ),
    "slug": slug,
    "artifact_path": f"specs/{slug}/project-sync.json",
    "issues_in_input":            summary["issues_in_input"],
    "already_on_board":           summary["already_on_board"],
    "added":                      summary["added"],
    "set_todo":                   summary["set_todo"],
    "set_ready":                  summary["set_ready"],            # v2.7.0+
    "set_in_progress":            summary["set_in_progress"],
    "set_in_review":              summary["set_in_review"],         # v2.7.0+
    "set_blocked":                summary["set_blocked"],
    "set_done":                   summary["set_done"],
    "auto_promoted_ready":        summary["auto_promoted_ready"],   # v2.7.0+
    "ready_label_stamped":        summary["ready_label_stamped"],   # v2.8.0+
    "ready_label_failed":         summary["ready_label_failed"],    # v2.8.0+
    "left_default":               summary["left_default"],
    "add_failed":                 summary["add_failed"],
    "edit_failed":                summary["edit_failed"],
    "skipped_after_total_failure":summary["skipped_after_total_failure"],
    "dry_run":                    summary["dry_run"],
    # v2.4.0+: field-write counts (0 when no fields config)
    "field_writes_attempted":     summary["field_writes_attempted"],
    "field_writes_succeeded":     summary["field_writes_succeeded"],
    "field_writes_failed":        summary["field_writes_failed"],
    # v2.7.0+: echo the active mode so orchestrators can branch without re-reading config
    "ready_queue_mode":           ready_queue_mode,
}
# v2.3.0+: include cross_repo key in RESULT when known_repos is configured
if known_repos:
    result["cross_repo"] = {
        "verify_passed": verify_passed,
        "known_repos_count": len(known_repos),
    }
# v2.5.0+: include auto_reinit key in RESULT only when auto-reinit fired
if auto_reinit_fired:
    result["auto_reinit"] = {
        "fired": True,
        "old_node_id": auto_reinit_old_node_id,
        "new_node_id": auto_reinit_new_node_id,
        "recovered": summary["recovered"],
    }
# v2.6.0+: include host key in RESULT when non-default
if RESOLVED_HOST != "github.com":
    result["host"] = RESOLVED_HOST
print(f"RESULT: {json.dumps(result, separators=(',', ':'))}")
print(f"Next: review specs/{slug}/project-sync.json; if needs_status_retry rows exist, "
      "run 'issue-to-project --retry-blocked-edits' or see Idempotency contract in SKILL.md.")
```

If exiting non-zero, also print `HALT: <code>` as the final line (after the `Next:` line).

## Webhook mode

When `--from-webhook <path>` is in argv, the normal 5-step flow described in this file is **not** used for Steps 1 and 2. Instead:

- Step 1 (config read) is identical.
- Step 2 is replaced by webhook payload parsing and synthetic-input construction.
- Steps 3–5 (board snapshot, add/edit, artifact write) run as normal, but the audit artifact is written to `<webhook_audit_dir>/<YYYY-MM-DD>/<delivery-id>.json` rather than `specs/{slug}/project-sync.json`, and the slug is always `_webhook`.

Load `references/webhook-lifecycle.md` for the complete 9-step `--from-webhook` flow, the lifecycle transition map, PR-body link extraction rules, audit-dir write logic, replay procedure, and the workflow YAML template for GitHub Actions.
