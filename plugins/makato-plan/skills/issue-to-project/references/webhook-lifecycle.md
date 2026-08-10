<!-- markdownlint-disable MD013 MD033 -->
# `--from-webhook` flow — 9-step reference

Pre-flight checks 1–4 from SKILL.md run first. This file picks up after they pass and dispatch (SKILL.md Step 0) has identified the run as `--from-webhook`. The webhook flow never reads `created-issues.json` and does not use a positional slug — it derives a synthetic single-issue input from the payload.

## Pre-flight

Same 4 checks as all other modes. See SKILL.md Step 0. All four checks run before any file read or network call. On failure: exit 1, HALT `PREFLIGHT_FAILED`.

## Step 1 — Parse `--from-webhook <path>`

Validate that the path given as the `--from-webhook` argument exists on disk:

```python
import pathlib, sys

webhook_path = pathlib.Path(args.from_webhook)
if not webhook_path.exists():
    sys.exit(
        f"issue-to-project: webhook event file not found: {webhook_path}\n"
        f"HALT: MISSING_INPUT"
    )
```

Parse the file as JSON. If parsing fails for any reason (empty file, truncated delivery, encoding error), abort immediately:

```python
import json

try:
    payload = json.loads(webhook_path.read_text())
except json.JSONDecodeError as e:
    sys.exit(
        f"issue-to-project: webhook payload at {webhook_path} is not valid JSON: {e}\n"
        f"HALT: WEBHOOK_PAYLOAD_INVALID"
    )
```

## Step 2 — Validate payload shape

The payload must contain `action` (top-level string) and at least one of `issue` or `pull_request` (top-level object). Name the missing field explicitly in the HALT message.

```python
if "action" not in payload:
    sys.exit(
        "issue-to-project: webhook payload missing required field 'action'.\n"
        "HALT: WEBHOOK_PAYLOAD_INVALID"
    )

if "issue" not in payload and "pull_request" not in payload:
    sys.exit(
        "issue-to-project: webhook payload missing required field: "
        "one of 'issue' or 'pull_request' must be present.\n"
        "HALT: WEBHOOK_PAYLOAD_INVALID"
    )
```

The `X-GitHub-Event` header is not available in the file-based invocation path — derive `event_type` from the payload shape: if `pull_request` key is present, `event_type = "pull_request"`; else `event_type = "issues"`. The `action` field is read directly from `payload["action"]`.

```python
event_type = "pull_request" if "pull_request" in payload else "issues"
action = payload["action"]
```

## Step 3 — Determine actionability

Consult the lifecycle transition map. Any event/action combination not listed in this table is non-actionable.

### Lifecycle transition map

| Event | Condition | Status written |
|---|---|---|
| `issues.opened` | always | `Todo` (project default — item-add only, no item-edit) |
| `issues.labeled` | `payload["label"]["name"] == "status:blocked"` | `Blocked` |
| `issues.assigned` | linked issue found on board | `In progress` (forward-only — promotes from `Ready`/`Todo`/unset, never rolls back from `In review`/`Done`/`Blocked`) |
| `pull_request.opened` | linked issue found | `In review` (when `options.in_review` present) or `In Progress` (fallback with WARN) |
| `pull_request.closed` | `payload["pull_request"]["merged"] == True`, linked issue found | `Done` |
| `pull_request.closed` | `payload["pull_request"]["merged"] == False`, linked issue found | `Todo` (abandon) |

> **`issues.assigned` (makato delta, #33).** The autonomous `loop.sh`
> dispatcher assigns an issue to the actor driving it just before spawning
> the PO-agent, so "someone is actively working this" maps to `In progress`.
> This is implemented natively in `.github/workflows/post-merge.yml`; the
> Claude-driven `--from-webhook` path treats `issues.assigned` as
> non-actionable (falls through `TRANSITION_MAP.get` → `None`) unless a
> future release wires it in. Keep the two in sync when either changes.

> **`issues.opened` plan-tier classification (makato delta, #211).** The
> native `.github/workflows/project-board-sync.yml` extends the plain
> `issues.opened → Todo` add above with a deterministic bash/jq classifier
> (`.github/scripts/classify-plan-tier.sh`) that stamps exactly one
> `plan-tier:{light|full|change}` label at onboard time. Precedence (D8): a
> human-set `plan-tier:*` label always wins; else `type:change`/change
> keywords → `change`; else a **decomposition signal**
> (`effort:xl` / `points:>=13` / `epic:*` / `phase:*`) → `full`; else
> `light` (the safe default). The classifier reads **no body length** — `full`
> means "splits into multiple stories", a structural fact carried by sizing/epic
> labels, not a property of description length (the prior >1500-char signal was
> removed). No LLM, no new secret (D5/SC-4). Promotion `Todo → Ready` is a
> separate gate owned by `seed-issue` (#212), not this workflow.

```python
label_name = (payload.get("label") or {}).get("name", "")
merged = (payload.get("pull_request") or {}).get("merged", None)

# D8: pull_request.opened targets "In review" when options.in_review is present in
# config, falling back to "In Progress" (v2.0 behavior) with a loud WARN when absent.
if (event_type, action) == ("pull_request", "opened"):
    if gp.get("options", {}).get("in_review"):
        pr_opened_target = "In review"
    else:
        print(
            "[issue-to-project] WARN: pull_request.opened received but options.in_review "
            "is absent — falling back to In Progress. Re-run --init to enable the "
            "In review transition.",
            file=sys.stderr,
        )
        pr_opened_target = "In Progress"
else:
    pr_opened_target = None

TRANSITION_MAP = {
    ("issues",       "opened"):  "Todo",
    ("issues",       "labeled"): "Blocked" if label_name == "status:blocked" else None,
    ("pull_request", "opened"):  pr_opened_target,
    ("pull_request", "closed"):  "Done" if merged is True else ("Todo" if merged is False else None),
}

lifecycle_transition = TRANSITION_MAP.get((event_type, action))

if lifecycle_transition is None:
    print(f"[issue-to-project] INFO: event {event_type}/{action} is not actionable — skipping.")
    print("HALT: WEBHOOK_NOT_ACTIONABLE")
    sys.exit(0)
```

Non-actionable events exit 0 so the GitHub Actions step passes and does not mark the workflow run as failed. The `HALT: WEBHOOK_NOT_ACTIONABLE` line on stdout provides observability for operators scanning logs.

## Step 4 — Resolve issue URL

For `issues.*` events, the issue URL is in the payload directly:

```python
if event_type == "issues":
    issue_url  = payload["issue"]["html_url"]
    issue_number = payload["issue"]["number"]
    issue_title  = payload["issue"].get("title", "")
    issue_labels = [lbl["name"] for lbl in payload["issue"].get("labels", [])]
```

For `pull_request.*` events, scan the PR body for a closing-keyword reference. The pattern list is read from config (`webhook_pr_link_patterns`, defaulting to `["Closes", "Fixes", "Resolves"]`):

```python
import re, os

pr_body = (payload.get("pull_request") or {}).get("body") or ""
pr_number = (payload.get("pull_request") or {}).get("number")
pr_url_parts = (payload.get("pull_request") or {}).get("html_url", "").split("/")
# pr_url_parts: ['https:', '', 'github.com', '<owner>', '<repo>', 'pull', '<N>']
if len(pr_url_parts) >= 5:
    repo_owner = pr_url_parts[3]
    repo_name  = pr_url_parts[4]
else:
    repo_owner = gp["owner"]
    repo_name  = ""   # fallback; construct URL from config if needed

patterns = gp.get("webhook_pr_link_patterns", ["Closes", "Fixes", "Resolves"])
if len(patterns) > 10:
    print("[issue-to-project] WARN: webhook_pr_link_patterns has more than 10 entries — "
          "truncating to first 10 for performance.")
    patterns = patterns[:10]

alt = "|".join(re.escape(p) for p in patterns)
link_re = re.compile(rf"(?i)\b(?:{alt})\b[ \t]+#(\d+)\b")
match = link_re.search(pr_body)

if not match:
    strict = os.environ.get("ITP_WEBHOOK_STRICT_LINK", "0") == "1"
    if strict:
        sys.exit(
            f"issue-to-project: no linked issue found in PR #{pr_number} body. "
            "Set ITP_WEBHOOK_STRICT_LINK=0 to skip instead of failing.\n"
            "HALT: WEBHOOK_NOT_ACTIONABLE"
        )
    else:
        print(f"[issue-to-project] WARN: no linked issue found in PR #{pr_number} body. "
              "Skipping lifecycle transition.")
        print("HALT: WEBHOOK_NOT_ACTIONABLE")
        sys.exit(0)

linked_issue_number = int(match.group(1))
issue_url = f"https://github.com/{repo_owner}/{repo_name}/issues/{linked_issue_number}"
issue_number = linked_issue_number
issue_title  = ""    # not available from PR body scan
issue_labels = []    # not available from PR body scan
print(f'[issue-to-project:auto] PR body match: "{match.group(0)}" → {issue_url}')
```

Log line confirms the body-scan result for operators reading the Actions run log.

## Step 5 — Build synthetic single-issue input

Construct an in-memory object that mirrors the `created-issues.json` contract so that Steps 6–8 can use the normal sync machinery unchanged:

```json
{
  "schema_version": "1",
  "slug": "_webhook",
  "issues": [
    {
      "number": <N>,
      "url": "<issue-html-url>",
      "title": "<issue-title or empty-string>",
      "labels": <labels-array-from-payload or []>
    }
  ]
}
```

```python
synthetic_input = {
    "schema_version": "1",
    "slug": "_webhook",
    "issues": [
        {
            "number": issue_number,
            "url": issue_url,
            "title": issue_title,
            "labels": issue_labels,
        }
    ],
}
slug = "_webhook"
issues = synthetic_input["issues"]
```

The `labels[]` array is used by `resolve_status_label` (from `sync-process.md` Step 4) only when the lifecycle transition is `Todo` or when the normal label-routing path falls through. For transitions driven by the webhook event (all rows in the transition map), the lifecycle-transition value takes precedence over the label-derived target. See the outcome-routing table in Step 7.

## Step 6 — Snapshot the board

Identical to `sync-process.md` Step 3. Run `gh project item-list` to build a `snapshot` dict keyed by issue URL:

```bash
SNAPSHOT_RAW="$(GH_HOST=github.com timeout "${ITP_GH_TIMEOUT_SECONDS:-30}" \
  gh project item-list "$NUMBER" --owner "$OWNER" --format json --limit 9999 2>&1)" || {
    echo "issue-to-project: item-list failed/timed-out: $SNAPSHOT_RAW" >&2
    echo "HALT: SNAPSHOT_FAILED"
    exit 1
}
```

```python
payload_snap = json.loads(SNAPSHOT_RAW)
items = payload_snap.get("items", [])
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

## Step 7 — Item-add and conditional item-edit

The target Status for the single issue is the `lifecycle_transition` determined in Step 3, NOT the label-derived target from `resolve_status_label`. The webhook event is the authoritative driver.

### Outcome routing

| Condition | Write(s) | `outcome` |
|---|---|---|
| Not in snapshot; lifecycle_transition is actionable Status | `item-add` then (if target ≠ `Todo`) `item-edit` | `added_<status>` per existing v1 set (e.g. `added_in_progress`, `added_done`, `added_blocked`, `added_default` for Todo) |
| Not in snapshot; lifecycle_transition = `Todo` (issues.opened or PR-abandon) | `item-add` only | `added_default` |
| In snapshot; `currentStatusName == lifecycle_transition` | No writes (idempotency per D8) | `already_on_board` |
| In snapshot; `currentStatusName != lifecycle_transition` | `item-edit` to transition target | `webhook_status_updated` |

The `webhook_status_updated` outcome is new in v2.1.0 and covers the case where the issue is already on the board at a different Status. Webhook mode is the authoritative Status driver (D8): human-pinned values in non-webhook mode are preserved by the precedence rule (D5), but in webhook mode the transition target is always written when it differs from the current board status.

```python
snapshot_entry = snapshot.get(issue_url)
target_status = lifecycle_transition  # e.g. "In Progress", "Done", "Blocked", "Todo"

if snapshot_entry is None:
    # Issue not yet on board — follow normal add+edit path
    # ... item-add call (same as sync-process.md Step 4) ...
    # If target_status == "Todo": outcome = "added_default" (no item-edit needed)
    # Else: item-edit to target_status using the matching options.* ID
    pass
else:
    current = snapshot_entry["currentStatusName"]
    if current == target_status:
        # Already at target — skip all writes (D8 idempotency)
        outcome = "already_on_board"
        print(f"[issue-to-project:auto] issue #{issue_number}: already at '{target_status}' — no write needed.")
    else:
        # Webhook is authoritative — flip to target
        # item-edit to target_status using the matching options.* ID
        # outcome = "webhook_status_updated"
        print(f"[issue-to-project:auto] issue #{issue_number}: Status '{current}' → '{target_status}' (webhook-authoritative)")
```

**Options key mapping for `item-edit`:**

| `lifecycle_transition` | `options` key |
|---|---|
| `In review` | `in_review` |
| `In Progress` | `in_progress` |
| `Done` | `done` |
| `Blocked` | `blocked` |
| `Todo` | _(no item-edit — default; or no-op if already Todo)_ |

**PR-label stamp on open-PR detection (D9):**

When `lifecycle_transition` is `"In review"` or `"In Progress"` (i.e. the PR is open), stamp the `pr_label_name` repo label onto the issue. Skip the call when `pr_label_name == ""` (empty-string disable sentinel). The call is made without a pre-read of existing labels — GitHub's add-label API is idempotent.

```python
pr_label_name = gp.get("pr_label_name", "PR")

if lifecycle_transition in ("In review", "In Progress") and pr_label_name != "":
    label_cmd = (
        f"GH_HOST=github.com gh issue edit {issue_number} "
        f"--repo {repo_owner}/{repo_name} --add-label \"{pr_label_name}\""
    )
    label_result = subprocess.run(
        label_cmd, shell=True, capture_output=True, text=True,
        timeout=int(os.environ.get("ITP_GH_TIMEOUT_SECONDS", 30)),
    )
    if label_result.returncode == 0:
        row["pr_label_action"] = "added"
        print(f"[issue-to-project] issue #{issue_number}: stamped label '{pr_label_name}' (add-label idempotent)")
    else:
        first_err_line = (label_result.stderr or "").splitlines()[0] if label_result.stderr else "unknown error"
        row["pr_label_action"] = "failed"
        row["pr_label_error"] = first_err_line
        print(
            f"[issue-to-project] WARN: issue #{issue_number}: could not stamp label "
            f"'{pr_label_name}': {first_err_line}",
            file=sys.stderr,
        )
        # Soft-warn: label failure does NOT block the Status flip.
else:
    row["pr_label_action"] = None
    row["pr_label_error"] = None
```

The `PR` label is **never removed** — not on PR close, not on merge, not on issue close.

**Soft-warn messages (exact text):**

```
[issue-to-project] WARN: issue #<N>: item-add failed: <error>
[issue-to-project] WARN: issue #<N>: webhook status edit to '<Status>' failed: <error>
[issue-to-project:auto] issue #<N>: Status '<current>' → '<target>' (webhook-authoritative)
[issue-to-project:auto] PR body match: "Closes #47" → https://github.com/owner/repo/issues/47
```

## Step 8 — Write the per-delivery audit artifact

Webhook runs write to a **separate append-only tree**, not to `specs/{slug}/project-sync.json`. The tree is date-partitioned for retention clarity (D4).

### Path resolution

```python
import datetime, os

webhook_audit_dir = gp.get("webhook_audit_dir", ".issue-to-project/lifecycle")
today = datetime.date.today().strftime("%Y-%m-%d")
delivery_id = os.environ.get("GITHUB_DELIVERY")

if not delivery_id:
    import secrets
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S")
    delivery_id = f"{ts}-{secrets.token_hex(4)}"
    print(f"[issue-to-project] WARN: GITHUB_DELIVERY not set; using timestamp-based ID "
          f"for audit artifact filename: {delivery_id}")

artifact_dir = pathlib.Path(webhook_audit_dir) / today
artifact_path = artifact_dir / f"{delivery_id}.json"
```

### Artifact shape

The per-delivery artifact mirrors `project-sync.json`'s schema with `schema_version: "2.8"`, `slug: "_webhook"`, and the `webhook` block populated:

```python
artifact = {
    "schema_version": "2.8",
    "slug": "_webhook",
    "run_timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "skill_version": "2.8.0",
    "retry_source": None,
    "webhook": {
        "delivery_id":          delivery_id,
        "event_type":           event_type,
        "action":               action,
        "merged":               merged,    # None → JSON null; True/False for PR events
        "lifecycle_transition": lifecycle_transition,
    },
    "project": {
        "owner": gp["owner"], "number": gp["number"], "url": gp["url"],
    },
    "summary": { ... },  # same keys as v1 normal-run summary, plus v2.7 keys:
                         # set_in_review, set_ready, auto_promoted_ready,
                         # pr_label_added, pr_label_failed
    "results": results,
}
```

When `DRY_RUN=1`, the `outcome` in `results` is `"dry_run"` for the single row, and `cli_command` is populated with the literal `item-add` (and, if applicable, `&& item-edit`) command that would have run.

### Atomic write

```python
schema = json.loads(pathlib.Path(
    "plugins/makato-plan/skills/issue-to-project/references/project-sync.schema.json"
).read_text())
try:
    jsonschema.validate(artifact, schema)
except jsonschema.ValidationError as e:
    sys.exit(f"issue-to-project: webhook artifact failed schema validation: {e.message}\n"
             f"HALT: AUDIT_SCHEMA_FAILED")

try:
    artifact_dir.mkdir(parents=True, exist_ok=True)
except OSError as e:
    sys.exit(f"issue-to-project: cannot create webhook_audit_dir {artifact_dir} — "
             f"check filesystem permissions.\nHALT: AUDIT_WRITE_FAILED")

tmp_path = artifact_path.with_suffix(".json.tmp")
try:
    tmp_path.write_text(json.dumps(artifact, indent=2) + "\n")
    os.replace(tmp_path, artifact_path)
except OSError as e:
    print(f"issue-to-project: webhook artifact write failed ({e}). "
          f"Board sync DID happen — see GitHub Project board for actual state.",
          file=sys.stderr)
    print("HALT: AUDIT_WRITE_FAILED")
    sys.exit(1)
```

`os.replace` is atomic on POSIX filesystems — write-then-rename ensures the artifact is never partially visible.

## Step 9 — Emit RESULT sentinel

After Step 8 succeeds, emit the R1 sentinel as the second-to-last line:

```python
result = {
    "status":                     "ok",   # or "partial" / "failed" per standard logic
    "slug":                       "_webhook",
    "artifact_path":              str(artifact_path),
    "issues_in_input":            1,
    "already_on_board":           summary["already_on_board"],
    "added":                      summary["added"],
    "set_blocked":                summary["set_blocked"],
    "left_default":               summary["left_default"],
    "add_failed":                 summary["add_failed"],
    "edit_failed":                summary["edit_failed"],
    "skipped_after_total_failure":0,
    "dry_run":                    summary["dry_run"],
    "set_in_review":              summary.get("set_in_review", 0),
    "pr_label_added":             summary.get("pr_label_added", 0),
    "pr_label_failed":            summary.get("pr_label_failed", 0),
    "webhook_event":              f"{event_type}/{action}",
    "webhook_transition":         lifecycle_transition,
}
print(f"RESULT: {json.dumps(result, separators=(',', ':'))}")
print(f"Next: review {artifact_path}")
```

`webhook_event` is a string in the format `"<type>/<action>"` (e.g. `"pull_request/closed"`). `webhook_transition` is the Status written (e.g. `"Done"`) or `"none"` for `WEBHOOK_NOT_ACTIONABLE` exits (those exit before Step 9). Both keys are `null` in non-webhook runs (v1 parsers that ignore unknown keys are unaffected — additive contract).

On non-zero exit, also print `HALT: <code>` as the final line (after the `Next:` line).

## DRY_RUN=1 behavior

When `DRY_RUN=1` is in env, the snapshot (Step 6) still runs (read-only). Steps 7's `item-add` and `item-edit` calls are skipped. For the single issue, record `outcome: "dry_run"` and populate `cli_command` with the literal command(s) that would have run (same format as normal-run DRY_RUN: for non-Todo targets, `item-add ... && item-edit ...` joined on one shell line). Step 8 still writes the artifact with `dry_run` outcome; exit 0.

## Replay procedure

GitHub Actions delivers webhooks at-least-once. Per D10, the recommended recovery procedure for outage-window missed events is:

1. Navigate to **Settings > Webhooks > Recent Deliveries** in the consuming repo.
2. Filter to the outage window's timestamp range.
3. Re-deliver each event via the **Re-deliver** button (or `POST /repos/{owner}/{repo}/hooks/{hook_id}/deliveries/{delivery_id}/attempts` via the GitHub API).
4. The skill receives the re-delivered payload with the same `GITHUB_DELIVERY` ID, runs the full 9-step flow, and writes a new per-delivery artifact.

Per-delivery artifacts under `<webhook_audit_dir>/<YYYY-MM-DD>/` (e.g. `.issue-to-project/lifecycle/2026-06-26/`) provide a complete record of what was processed, enabling gap detection: if an expected delivery ID is missing from the directory, that event was never successfully processed and should be re-delivered.

GitHub's delivery log is retained for **30 days**. After that window, missed events require a manual `issue-to-project <slug>` run or a partial reconciliation approach.

## Workflow YAML template

Operators copy the following YAML into `.github/workflows/issue-to-project-lifecycle.yml` in their consuming repo. It is not deployed from the makato repo — each consumer maintains their own copy.

```yaml
# .github/workflows/issue-to-project-lifecycle.yml
# Copy this file into your consuming repo and set ITP_GITHUB_TOKEN as a repo secret.
# Required secret: ITP_GITHUB_TOKEN — fine-grained PAT with Issues: Read and write,
#   Projects: Read and write, and Pull requests: Read scopes.

name: Issue-to-Project Lifecycle Sync

on:
  issues:
    types: [opened, labeled]
  pull_request:
    types: [opened, closed]

jobs:
  lifecycle-sync:
    runs-on: ubuntu-latest
    # Only run labeled events for the status:blocked label to save runner minutes.
    if: >
      github.event_name == 'issues' && github.event.action == 'opened' ||
      github.event_name == 'issues' && github.event.action == 'labeled' &&
        github.event.label.name == 'status:blocked' ||
      github.event_name == 'pull_request'

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Run issue-to-project lifecycle sync
        env:
          GH_HOST: github.com
          GH_TOKEN: ${{ secrets.ITP_GITHUB_TOKEN }}
          GITHUB_DELIVERY: ${{ github.event.delivery }}
        run: |
          python3 plugins/makato-plan/skills/issue-to-project/run.py \
            --from-webhook "$GITHUB_EVENT_PATH"
```

The `if:` condition on the job filters `issues.labeled` events to only the `status:blocked` label, saving runner minutes on all other label events. `pull_request` events pass through entirely because the transition-map routing (Step 3) handles the non-actionable combinations internally with `WEBHOOK_NOT_ACTIONABLE` exit 0.

## Token setup

1. Go to https://github.com/settings/tokens?type=beta.
2. Create a fine-grained PAT scoped to the consuming repo with permissions: `Issues: Read and write`, `Projects: Read and write`, `Pull requests: Read`.
   - `Issues: Read and write` is required in v2.7+ for the PR-label stamp (`gh issue edit --add-label`). Without it, every open-PR detection emits `pr_label_action: "failed"` (soft-warn; does not block the Status flip).
3. Add it as a repo secret named `ITP_GITHUB_TOKEN` in **Settings > Secrets and variables > Actions**.
4. The workflow uses `GH_TOKEN` (the env var `gh` reads by default) set to the secret value. `GITHUB_TOKEN` is not used for `gh project` calls because it does not carry the `project` scope by default.

If the consumer is already using a PAT for manual `issue-to-project` runs (set via `gh auth login --with-token`), that PAT may already have `project` scope. Check whether it also has `issues:write` before reusing it as `ITP_GITHUB_TOKEN`; if not, extend it or create a second PAT.

### Pre-flight token-scope check (`--init` Step 6c)

When `pr_label_name` is non-empty, `--init` runs a soft advisory check to confirm the token has `issues:write` before the first live run:

```bash
# Inspect token scopes from the X-OAuth-Scopes response header.
gh auth status --show-token 2>&1 | grep -i "Token scopes" | grep -q "repo\|issues"
# Or via gh api headers:
SCOPES="$(gh api user --include 2>/dev/null | grep -i '^X-OAuth-Scopes:' | cut -d: -f2-)"
echo "$SCOPES" | grep -qiE '\brepo\b|\bissues\b'
```

- If the scope check passes: emit `[issue-to-project:init] INFO: token has issues/repo scope — PR-label stamp will work.`
- If the scope check fails or is inconclusive: emit `[issue-to-project:init] WARN: token may lack issues:write scope. PR-label stamps will fail at runtime (pr_label_action: "failed") until the token is extended. Re-run --init after updating the token.`
- The pre-flight check is advisory only — it does NOT HALT `--init`. The wizard continues regardless.

## Migration notes

**v1.0.0 → v2.7.0 (consumers already running v1):**

1. Run `issue-to-project --init` once to merge the new config keys (`webhook_audit_dir`, `webhook_pr_link_patterns`, `pr_label_name`, `ready_queue_mode`) into `.claude/config.json`. No re-prompting; `--init` detects existing v1 config and merges defaults only. Step 6c creates the `PR` repo label (color `0E8A16`) if absent.
2. Copy `.github/workflows/issue-to-project-lifecycle.yml` (from the Workflow YAML template section above) into the consuming repo.
3. Create `ITP_GITHUB_TOKEN` repo secret with **`Issues: Read and write`** scope (see Token setup above). Existing PATs with only `Issues: Read` will cause `pr_label_action: "failed"` on every open-PR event — extend the PAT.
4. Add `.issue-to-project/` to `.gitignore` if audit artifacts should not be committed, or `git add .issue-to-project/` if they should be versioned. No default either way — operator decision.
5. Existing `specs/*/project-sync.json` artifacts from v1 runs are unaffected; the new webhook audit tree is separate.
6. Webhook artifacts now emit `schema_version: "2.7"`. Downstream consumers parsing the per-delivery JSON files must accept the new value. The additive-only contract means all v2.1–v2.6 keys are present with the same types; the new keys (`set_in_review`, `pr_label_added`, `pr_label_failed`) can be ignored by v2.6 consumers.
