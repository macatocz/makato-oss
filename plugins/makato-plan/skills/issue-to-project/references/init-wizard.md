<!-- markdownlint-disable MD013 -->
# `--init` wizard — 6-step flow

The `--init` wizard runs once per consuming repo. It discovers the GitHub Projects v2 board, resolves the Status field + four option IDs, and writes the `github_project` block into `.claude/config.json`. Re-running re-prompts and overwrites (idempotent).

Pre-flight checks 1–4 from SKILL.md run first; this file picks up after they pass.

## Step 0 — Resolve host (v2.6.0+)

Ask for the GitHub host before any API calls, because all subsequent `gh` invocations need the correct `--hostname`.

```
[issue-to-project] GitHub host to target (default: github.com):
```

Empty input accepts `"github.com"`. Any non-empty answer becomes `HOST`. Derive `HOST_TYPE` automatically: if `HOST == "github.com"` then `HOST_TYPE = "cloud"`, otherwise `HOST_TYPE = "enterprise"`.

When `HOST_TYPE == "enterprise"`, run the GHES version check before proceeding:

```bash
META_RAW="$(gh --hostname "$HOST" api /meta 2>&1)" || {
    echo "issue-to-project: could not read /meta from $HOST to verify GHES version: $META_RAW. Check network access and authentication."
    echo "HALT: PREFLIGHT_FAILED"
    exit 1
}
```

Extract `installed_version` from the JSON and compare using integer tuples:

```python
import json, sys
meta = json.loads(META_RAW)
installed = meta.get("installed_version", "0.0")
min_ver = "3.10"  # or gp.get("min_ghes_version", "3.10") if config already exists
def ver_tuple(v): return tuple(int(x) for x in v.split("."))
if ver_tuple(installed) < ver_tuple(min_ver):
    print(f"issue-to-project: GHES {installed} on {HOST} does not support Projects v2 "
          f"(requires {min_ver}+). Upgrade GHES or use classic Projects instead.")
    print("HALT: GHES_TOO_OLD")
    sys.exit(1)
print(f"[issue-to-project] Targeting host: {HOST} (enterprise, GHES {installed})")
print(f"[issue-to-project] Check 5: GHES version {installed} >= {min_ver} — ok")
```

If Check 2 (auth) fails for the configured host, the failure message is:
`"issue-to-project: 'gh' is not authenticated for host <host>. Run 'gh auth login --hostname <host>' then retry."`

For GHES specifically, the correct auth invocation is:
```sh
gh auth login --hostname github.example.com --scopes project,read:project
```

## Step 1 — Resolve owner

```bash
OWNER_DEFAULT="$(gh --hostname "${HOST:-github.com}" api user --jq .login)"
echo "[issue-to-project] Authenticated as: $OWNER_DEFAULT"
```

Prompt the operator: `"Project owner (user login or organization name) [$OWNER_DEFAULT]:"`. Empty input accepts the default. Track `OWNER_TYPE` — start as `"user"`; if the operator types an org name (re-prompt branch in Step 2), flip to `"organization"`.

## Step 2 — List candidate projects

```bash
LIMIT="${PROJECT_LIST_LIMIT:-50}"
PROJECT_LIST_JSON="$(GH_HOST="${HOST:-github.com}" gh project list --owner "$OWNER" --format json --limit "$LIMIT" 2>&1)"
PROJECT_COUNT="$(echo "$PROJECT_LIST_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('projects', [])))")"
```

If the operator wants a different owner (e.g. an org), prompt: `"Look at a different owner? [y/N]:"` — on `y`, set `OWNER_TYPE=organization`, prompt for the org login, re-run the command.

If `PROJECT_COUNT == LIMIT`, warn:

```
[issue-to-project] WARN: hit the project-list limit ($LIMIT). Set PROJECT_LIST_LIMIT=200 and re-run --init to widen the search, or enter the project number directly at the next prompt.
```

Otherwise, render a numbered list with `title` + `url` per project.

## Step 3 — Pick or create

Prompt: `"Pick a project [1-N], or 'c' to create a new one, or empty to cancel:"`.

- **Empty input** → exit 2 with HALT `USER_CANCELLED`: `"issue-to-project: --init cancelled. Config unchanged."`
- **Numeric** → set `PROJECT_NUMBER` from the listed project; jump to Step 4.
- **`c`** → prompt for title; run:

  ```bash
  GH_HOST="${HOST:-github.com}" gh project create --owner "$OWNER" --title "$TITLE" --format json
  ```

  Then halt with an instructional message — fresh projects ship with Todo/In Progress/Done but NOT Blocked:

  ```
  [issue-to-project] Project created: <url>.
  [issue-to-project] GitHub does not let the CLI add the 'Blocked' Status option to a default Status field. Open the URL above, add a 'Blocked' option to the Status field, then re-run 'issue-to-project --init' and pick this project.
  ```

  Exit 0 (the operator's next action is a UI click, not a re-run; --init is intentionally non-resumable here).

  If `gh project create` itself fails: exit 1 with HALT `INIT_FAILED`, print gh's error.

## Step 4 — Discover Status field + options

```bash
FIELD_JSON="$(GH_HOST="${HOST:-github.com}" gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json)"
```

Use Python (or `jq`) to find the field where `name == "Status"` AND `type == "ProjectV2SingleSelectField"`. **Both keys matter** — the filter discriminator is `type` (not `dataType`) and the value is the full GraphQL `__typename` `"ProjectV2SingleSelectField"` (not `"SINGLE_SELECT"`).

```python
import json
fields = json.loads(FIELD_JSON)["fields"]
status_field = next(
    (f for f in fields if f["name"] == "Status" and f["type"] == "ProjectV2SingleSelectField"),
    None,
)
if status_field is None:
    sys.exit("No 'Status' single-select field found in project.")

PROJECT_NODE_ID = status_field["__parentProjectId"]  # see note below
STATUS_FIELD_ID = status_field["id"]
options = {o["name"].lower().replace(" ", "_"): o["id"] for o in status_field["options"]}
```

> **Note:** `gh project field-list` does not expose the parent project's node ID on each field row. Read it separately:
>
> ```bash
> PROJECT_NODE_ID="$(GH_HOST="${HOST:-github.com}" gh project view "$PROJECT_NUMBER" --owner "$OWNER" --format json | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")"
> ```

## Step 4a — Discover non-Status fields for v2.4.0 config (v2.4.0+)

After discovering the Status field, iterate all fields returned by `gh project field-list` to wire up Priority, Iteration, Estimate, and Date Target. Store discovered candidate fields from the same `FIELD_JSON` payload — no additional `gh` call is needed.

```python
# FIELD_TYPE constants for GitHub Projects v2 GraphQL __typename values
SINGLE_SELECT_TYPE = "ProjectV2SingleSelectField"
ITERATION_TYPE     = "ProjectV2IterationField"
NUMBER_TYPE        = "ProjectV2Field"    # dataType: NUMBER
DATE_TYPE          = "ProjectV2Field"    # dataType: DATE

# Discover Priority (single-select named "Priority", case-insensitive)
priority_field = next(
    (f for f in fields
     if f["name"].lower() == "priority" and f["type"] == SINGLE_SELECT_TYPE),
    None,
)

# Discover Iteration (any iteration field)
iteration_field = next(
    (f for f in fields if f["type"] == ITERATION_TYPE),
    None,
)

# Discover Estimate (number field named "Estimate", "Story Points", or "Points", case-insensitive)
ESTIMATE_NAMES = {"estimate", "story points", "points"}
estimate_field = next(
    (f for f in fields
     if f["name"].lower() in ESTIMATE_NAMES
     and f.get("dataType", "").upper() == "NUMBER"),
    None,
)

# Discover Date Target (date field named "Target Date", "Due Date", or "Target", case-insensitive)
DATE_NAMES = {"target date", "due date", "target"}
date_target_field = next(
    (f for f in fields
     if f["name"].lower() in DATE_NAMES
     and f.get("dataType", "").upper() == "DATE"),
    None,
)
```

**Priority option validation:** if `priority_field` is found, check whether its option names match the expected `p0/p1/p2/p3` pattern (case-insensitive). If they do not match exactly, print a mapping prompt before accepting:

```
[issue-to-project] Priority field found, but option names don't match p0/p1/p2/p3:
  Detected options: High, Medium, Low, Critical
  Expected pattern: p0 (highest) → p3 (lowest)
Accept this mapping anyway? [y/N]:
```

If the operator declines (`N` or empty), `priority_field` is set to `None` and the Priority field is not wired.

## Step 4c — Field-wiring confirmation prompt (v2.4.0+)

After discovering all available fields (Step 4a), present a summary of the planned wiring and ask the operator to confirm before writing to config. This step runs even when only the Status field was found.

```
[issue-to-project] Planned field wiring:
  ✓ Status       (required, single-select, 4 options)
  ✓ Priority     (single-select, 4 options: p0/p1/p2/p3)
  ✓ Iteration    (iteration, current_only: true)
  ✓ Estimate     (number, sourced from points:N or size:S/M/L/XL)
  ✗ Date Target  (date field not found on project)

Wire these fields? [Y/n/edit]:
```

- **Empty or `Y`** → use the planned wiring; continue to Step 5.
- **`n`** → wire Status only (v1 behavior); `WIRED_FIELDS = {"status": ...}` only.
- **`edit`** → present a numbered list of found fields; operator types comma-separated numbers to include. Unselected fields are omitted from the config. Invalid input → re-prompt once, then default to all found fields.

Fields the operator unchecks are silently omitted from the `fields` dict; their absence is not an error on future runs.

## Step 5 — Validate four Status options

All four option keys must resolve: `todo`, `in_progress`, `done`, `blocked`. Name-match is case-insensitive (`"In Progress"` → `in_progress`). Missing any → exit 1 with HALT `INIT_FAILED`, name the missing options, print the project URL, and instruct: `"Open the URL, add the missing Status option(s), then re-run 'issue-to-project --init'."`

**Note (v2.7.0+):** `ready` and `in_review` are NOT required for `--init` to succeed. When either optional option is absent from the discovered Status field, emit one INFO line per missing optional and continue:

```text
[issue-to-project] INFO: Status option 'Ready' not found on project — options.ready will not be cached. issues with status:ready will route to Todo with WARN until you re-run --init after adding the option.
[issue-to-project] INFO: Status option 'In review' not found on project — options.in_review will not be cached. issues with status:in-review will route to Todo with WARN until you re-run --init after adding the option.
```

## Step 4b — Auto-discover `known_repos` from live board (v2.3.0+)

After resolving the Status field (Step 4), call `gh project item-list` once to collect `repository.nameWithOwner` from all existing board items. This auto-discovers which repos are already feeding the board.

```bash
ITEM_LIST_RAW="$(timeout "${ITP_GH_TIMEOUT_SECONDS:-30}" \
  GH_HOST="${HOST:-github.com}" gh project item-list "$PROJECT_NUMBER" --owner "$OWNER" --format json --limit 9999 2>&1)"
```

```python
import json
items = json.loads(ITEM_LIST_RAW).get("items", [])
discovered = sorted(set(
    item["content"]["repository"]["nameWithOwner"]
    for item in items
    if item.get("content") and item["content"].get("repository") and
       item["content"]["repository"].get("nameWithOwner")
))
```

**If `discovered` is empty (brand-new empty board):** skip the prompt and set `known_repos = []` silently. The operator can set `known_repos` later by re-running `--init`.

**If `discovered` is non-empty:** present the list and prompt:

```
[issue-to-project] Detected these repos on the board:
  - zstary/repo-a
  - zstary/repo-b
Add all as known_repos? [Y/n/edit]:
```

- **Empty or `Y`** → `known_repos = discovered`; continue.
- **`n`** → `known_repos = []`; continue.
- **`edit`** → open a text prompt: `"Enter known_repos (comma-separated owner/repo entries):"`. Parse and trim entries; validate each against `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`. Invalid entry → re-prompt once, then exit 2 with HALT `USER_CANCELLED`.

Then prompt for `reconcile_scope`:

```
Set reconcile_scope to 'all-known-repos'? This prevents reconcile from flagging foreign-repo items as orphans. [Y/n]:
```

- **Empty or `Y`** → `reconcile_scope = "all-known-repos"`.
- **`n`** → `reconcile_scope = "this-repo-only"` (v1 behaviour).

If `reconcile_scope == "all-known-repos"` and `known_repos` is empty, log a soft-warn matching validation rule 7 (config-schema.md §Validation rules); continue.

## Step 6 — Write config

Before writing, prompt the operator for the `include_draft_prs` setting (step 6b):

```
Count draft PRs as In Progress? [Y/n]:
```

Default `Y` (empty input → `true`). Explicit `n` or `N` → `false`. Any other input → re-prompt once, then default to `true`.

## Step 6c — Create PR repo label (v2.7.0+)

**Preserve-existing-on-reinit:** on a re-init run, read `config.get("github_project", {}).get("pr_label_name")` first. If the existing config already contains a `pr_label_name`, default this step to that value (pressing Enter keeps the current value). Only on a fresh init (no prior value) does the default fall back to `"PR"`.

Prompt the operator:

```text
PR label name (stamped on an issue when a linked open PR is first detected) ["PR"]:
```

Empty input accepts the default (either the existing value from config or `"PR"`). Entering `""` (an empty string, typed explicitly) sets `pr_label_name = ""` which disables all label stamping (D9 sentinel).

Validate the entered value against rule 15 in config-schema.md (whitespace-only → HALT `MALFORMED_CONFIG`; non-empty must match `^[A-Za-z0-9_:.-]+$`, 1–50 chars). On HALT, print the validation message and exit 1.

When `pr_label_name` is non-empty, run a **pre-flight token-scope check** (advisory only — does NOT HALT):

```bash
gh auth status --show-token 2>&1 | grep -E "(repo|issues)" && \
    echo "[issue-to-project] INFO: token scope check — issues:write (or repo) scope detected. PR label stamping should succeed." || \
    echo "[issue-to-project] WARN: token scope check — issues:write scope not detected. Every PR label stamp will fail at sync-lifecycle time with pr_label_action: 'failed'. Grant the 'Issues: Read and write' (issues:write) scope and re-run --init."
```

Then create the label in the repo if `pr_label_name` is non-empty:

```bash
# Skip the step entirely when pr_label_name is the empty-string disable sentinel.
if [ -z "$PR_LABEL_NAME" ]; then
    echo "[issue-to-project] INFO: Step 6c skipped: pr_label_name is empty — PR-label feature disabled."
else
    gh label create "$PR_LABEL_NAME" \
        --color "0E8A16" \
        --description "This issue has an open linked pull request." 2>&1 || {
        # Treat "already exists" as success; soft-warn on any other non-zero exit.
        LABEL_ERR="$?"
        echo "[issue-to-project] WARN: could not create repo label '$PR_LABEL_NAME': exit $LABEL_ERR."
        echo "  The skill will still attempt to stamp the label at sync-lifecycle time; if the"
        echo "  label does not exist there, the per-row pr_label_action will be 'failed'."
        echo "  Most common cause: the GitHub token lacks 'issues:write' (Issues: Read and write) scope."
    }
fi
```

Note: `gh label create` returns exit 0 when the label already exists (idempotent). A non-zero exit code is treated as a soft-warn — the wizard continues. The skill will attempt label stamping at runtime regardless; if the label does not exist, each attempt will be recorded as `pr_label_action: "failed"`.

## Step 6d — Prompt `ready_queue_mode` (v2.7.0+)

**Preserve-existing-on-reinit:** on a re-init run, read `config.get("github_project", {}).get("ready_queue_mode")` first. If the existing config already contains a `ready_queue_mode`, default the prompt to that value (pressing Enter keeps the current mode). Only on a fresh init (no prior value) does the default fall back to `"manual"`.

Prompt the operator:

```text
Ready-queue ownership: who promotes Todo → Ready?
  [m] manual     — the user moves items via UI or sets status:ready in to-issues. (default)
  [a] autonomous — the orchestrator auto-promotes items with no status/blocked/review labels.
Choice [m]:
```

- **Empty or `m`** → `ready_queue_mode = "manual"`.
- **`a`** → `ready_queue_mode = "autonomous"`.
- **Any other input** → re-prompt once, then default to `"manual"`.

When re-init and the prior value is `"autonomous"`, the prompt shows `Choice [a]:` and Enter keeps `"autonomous"`.

## Step 6e — Create ready-for-dev repo label (v2.8.0+)

**Runs only when `READY_QUEUE_MODE == "autonomous"`.** When the operator chose `"manual"` in Step 6d, skip this step entirely, set `READY_LABEL_NAME = ""` silently (manual mode never auto-promotes, so the label is never stamped), and continue to the config-write snippet.

**Preserve-existing-on-reinit:** on a re-init run, read `config.get("github_project", {}).get("ready_label_name")` first. If already set, default this step to that value (Enter keeps it). Only on a fresh init (no prior value) does the default fall back to `"status:ready-for-dev"`.

Prompt the operator:

```text
Ready-for-dev label name (stamped on an issue when the skill auto-promotes it to Ready) ["status:ready-for-dev"]:
```

Empty input accepts the default (either the existing value from config or `"status:ready-for-dev"`). Entering `""` (an empty string, typed explicitly) sets `READY_LABEL_NAME = ""`, which disables the ready-for-dev stamp (same D9 sentinel as `pr_label_name`). Validate the value against rule 17 in `config-schema.md`: a whitespace-only value → HALT `MALFORMED_CONFIG`.

Then create the label in the repo when `READY_LABEL_NAME` is non-empty:

```bash
# Skip the step entirely when ready_label_name is the empty-string disable sentinel.
if [ -z "$READY_LABEL_NAME" ]; then
    echo "[issue-to-project] INFO: Step 6e skipped: ready_label_name is empty — ready-for-dev label feature disabled."
else
    gh label create "$READY_LABEL_NAME" \
        --color "0075CA" \
        --description "This issue is ready for development pickup by the orchestrator." 2>&1 || {
        LABEL_ERR="$?"
        echo "[issue-to-project] WARN: could not create repo label '$READY_LABEL_NAME': exit $LABEL_ERR."
        echo "  The skill will still attempt to stamp the label on autonomous promotion; if the"
        echo "  label does not exist, the per-row ready_label_action will be 'failed'."
    }
fi
```

Color `0075CA` (GitHub blue) distinguishes it from the PR label's green (`0E8A16`). Note: `gh label create` returns exit 0 when the label already exists (idempotent); a non-zero exit is a soft-warn and the wizard continues.

**Collision warning.** If `READY_LABEL_NAME` is non-empty and equals `PR_LABEL_NAME`, print: `"[issue-to-project] WARN: ready_label_name equals pr_label_name — both features will stamp the same label at different lifecycle moments. Consider using distinct names."`

```python
import json, os, datetime, pathlib
config_path = pathlib.Path(".claude/config.json")
config_path.parent.mkdir(parents=True, exist_ok=True)
config = {}
if config_path.exists():
    try:
        config = json.loads(config_path.read_text())
    except json.JSONDecodeError as e:
        sys.exit(f"issue-to-project: existing .claude/config.json is invalid JSON: {e}")

# Build v2.4 fields dict from confirmed WIRED_FIELDS
fields_dict = {
    "status": {
        "id":      STATUS_FIELD_ID,
        "name":    "Status",
        "type":    "single-select",
        "options": {
            "todo":        options["todo"],
            "in_progress": options["in_progress"],
            "done":        options["done"],
            "blocked":     options["blocked"],
            # Optional v2.7.0+ options — only written when found on the board.
            **({} if "ready" not in options else {"ready": options["ready"]}),
            **({} if "in_review" not in options else {"in_review": options["in_review"]}),
        },
    },
}
if priority_field and "priority" in WIRED_FIELDS:
    fields_dict["priority"] = {
        "id":   priority_field["id"],
        "name": priority_field["name"],
        "type": "single-select",
        "options": {
            o["name"].lower().replace(" ", "_"): o["id"]
            for o in priority_field["options"]
        },
    }
if iteration_field and "iteration" in WIRED_FIELDS:
    fields_dict["iteration"] = {
        "id":           iteration_field["id"],
        "name":         iteration_field["name"],
        "type":         "iteration",
        "current_only": True,
    }
if estimate_field and "estimate" in WIRED_FIELDS:
    fields_dict["estimate"] = {
        "id":   estimate_field["id"],
        "name": estimate_field["name"],
        "type": "number",
    }
if date_target_field and "date_target" in WIRED_FIELDS:
    fields_dict["date_target"] = {
        "id":   date_target_field["id"],
        "name": date_target_field["name"],
        "type": "date",
    }

config["github_project"] = {
    "host": HOST,                             # v2.6.0+; "github.com" for cloud
    "host_type": HOST_TYPE,                   # v2.6.0+; "cloud" or "enterprise"
    # min_ghes_version written only for enterprise; harmless to always include
    "min_ghes_version": "3.10",               # v2.6.0+
    "owner": OWNER,
    "owner_type": OWNER_TYPE,
    "number": PROJECT_NUMBER,
    "url": f"https://{HOST}/{'users' if OWNER_TYPE=='user' else 'orgs'}/{OWNER}/projects/{PROJECT_NUMBER}",
    "project_node_id": PROJECT_NODE_ID,
    "fields": fields_dict,
    "init_timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "init_skill_version": "2.8.0",
    "include_draft_prs": INCLUDE_DRAFT_PRS,
    "webhook_audit_dir": config.get("github_project", {}).get("webhook_audit_dir", ".issue-to-project/lifecycle"),
    "webhook_pr_link_patterns": config.get("github_project", {}).get("webhook_pr_link_patterns", ["Closes", "Fixes", "Resolves"]),
    # v2.3.0+: cross-repo fields (always written; empty list = no-op, v1 behaviour)
    "known_repos": KNOWN_REPOS,
    "reconcile_scope": RECONCILE_SCOPE,
    # v2.7.0+: PR label and ready-queue mode
    "pr_label_name": PR_LABEL_NAME,
    "ready_queue_mode": READY_QUEUE_MODE,
    # v2.8.0+: ready-for-dev label stamped on autonomous promotion (empty string when manual mode or disabled)
    "ready_label_name": READY_LABEL_NAME,
}

tmp = config_path.with_suffix(".json.tmp")
tmp.write_text(json.dumps(config, indent=2) + "\n")
os.replace(tmp, config_path)
print(f"[issue-to-project] Wrote github_project block to {config_path}")
```

If the write fails with `PermissionError` or `OSError`, exit 1 with HALT `INIT_FAILED`: `"issue-to-project: cannot write .claude/config.json — check filesystem permissions."`

## --init failure summary

| When | Exit | HALT |
|---|---|---|
| Operator presses Ctrl-C or empty input at the project prompt | 2 | `USER_CANCELLED` |
| `gh project create` fails | 1 | `INIT_FAILED` |
| Status field not found OR not all four options resolve | 1 | `INIT_FAILED` |
| Config write fails | 1 | `INIT_FAILED` |
