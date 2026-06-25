<!-- markdownlint-disable MD013 -->
# Spec: Webhook Listener — Push-Mode Lifecycle Sync, v2.1.0

> **Status:** Design. Targets `issue-to-project` v2.1.0. Depends on v1.0.0+ contract.
> **Spec date:** 2026-06-26
> **Predecessor:** `docs/superpowers/specs/2026-06-24-issue-to-project-design.md` (v1.0.0)

## Goal

Deliver push-mode lifecycle sync: a **long-running component** (a GitHub Actions workflow — not the skill itself) that subscribes to repository events and triggers `issue-to-project` with a webhook payload whenever an issue or PR transitions to a state that maps to a project Status change. Specifically:

- `issues.opened` → add the new issue to the board (same as the manual skill, but automated).
- `issues.labeled` (label = `status:blocked`) → set Status=Blocked even after `to-issues` has run.
- `pull_request.opened` → set Status=`In Progress` on the linked issue.
- `pull_request.closed` (merged=true) → set Status=`Done` on the linked issue.
- `pull_request.closed` (merged=false) → set Status=`Todo` (abandon) on the linked issue.

The skill gains a new `--from-webhook <event-json-path>` flag; the Action invokes the skill with that flag so the skill's sync logic is reused verbatim without an existing `created-issues.json`.

## Non-Goals

- Multi-tenant listener (one Action serving multiple repos). v2.1 is single-repo per workflow file.
- GitHub App vs. PAT deep-dive — a fine-grained PAT in repo secrets is sufficient for v2.1.
- Bidirectional sync (board → labels). Covered by O3 in the v1 spec, not here.
- Self-hosted HTTP server as the primary delivery vehicle. GitHub Action is primary; others are documented as rejected alternatives.
- Bulk reconciliation of pre-existing issues not added by `to-issues`. Remains O3 from v1.

## Architecture

### High-level

```
GitHub event
    │  (webhook, built-in to Actions)
    ▼
.github/workflows/issue-to-project-lifecycle.yml
    │
    ├─ checkout repo
    ├─ write $GITHUB_EVENT_PATH fragment to /tmp/webhook-event.json
    └─ invoke: issue-to-project --from-webhook /tmp/webhook-event.json
                      │
                      ▼
              skill (SKILL.md, Python/gh glue)
              ├─ parse & validate webhook payload
              ├─ resolve linked issue URL(s)
              ├─ snapshot board (step 3 re-run guard, unchanged)
              ├─ item-add / item-edit per resolved issue
              └─ write audit artifact to
                 .issue-to-project/lifecycle/<YYYY-MM-DD>/<delivery-id>.json
```

The Action runs on `github.com` runners with a fine-grained PAT (`ITP_GITHUB_TOKEN`) stored as a repo secret. `GITHUB_TOKEN` is not used for `gh project` calls because it does not carry the `project` scope by default.

### Why this approach (alternatives considered)

**GitHub Action is chosen as primary** for four reasons:
1. Zero infrastructure cost — no server to provision, patch, or scale.
2. Auth is a solved problem — fine-grained PAT in repo secrets, rotated via GitHub UI.
3. Delivery reliability — GitHub retries failed Action runs; the 30-day delivery log enables replay.
4. Keeps the component in-repo alongside the skill — no out-of-band service to coordinate.

**Self-hosted HTTP server (Fly.io / Cloud Run)** — rejected. Requires persistent infra, TLS termination, secret rotation, and a public endpoint. Appropriate for multi-tenant (v3+) but disproportionate for single-repo.

**Serverless function (Lambda / Cloud Function with event batching)** — rejected. Adds a deployment pipeline, environment-specific IAM/secret management, and cold-start latency. Complexity exceeds value for a single-repo trigger.

## Data Flow

```
1. GitHub fires a webhook to the Actions runner (event triggers listed in workflow).

2. Runner writes the full $GITHUB_EVENT_PATH JSON (provided by Actions) to disk.
   The event JSON is already present at $GITHUB_EVENT_PATH; the workflow step
   just passes that path to the skill flag.

3. skill --from-webhook $GITHUB_EVENT_PATH
   a. Validate payload shape (new HALT codes below).
   b. Determine actionability: event type + action field → lifecycle transition
      or emit HALT WEBHOOK_NOT_ACTIONABLE and exit 0 (non-error; Action passes).
   c. Resolve issue URL(s) from the payload:
      - issues.* events: payload.issue.html_url
      - pull_request.* events: body-scan for "Closes #N", "Fixes #N", "Resolves #N"
        → construct https://github.com/<owner>/<repo>/issues/<N>
        If no linked issue is found, emit HALT WEBHOOK_NOT_ACTIONABLE and exit 0.
   d. Build a synthetic single-issue input (replaces created-issues.json):
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
   e. Run the normal 5-step sync (snapshot → add/edit → audit artifact).
      Status is determined by the lifecycle-transition map, NOT by labels[] alone.

4. Audit artifact written to:
   .issue-to-project/lifecycle/<YYYY-MM-DD>/<delivery-id>.json
   where delivery-id = env var GITHUB_DELIVERY (set by Actions; falls back to
   a timestamp-based UUID if not present, e.g. manual invocations).

5. Action exits 0 on success (RESULT sentinel present on stdout).
   Action exits 1 on skill exit 1 (HALT code visible in runner logs).
```

### Lifecycle transition map

| Event | Condition | Status written |
|---|---|---|
| `issues.opened` | always | `Todo` (project default) |
| `issues.labeled` | `label.name == "status:blocked"` | `Blocked` |
| `pull_request.opened` | linked issue found | `In Progress` |
| `pull_request.closed` | `merged == true`, linked issue found | `Done` |
| `pull_request.closed` | `merged == false`, linked issue found | `Todo` |

Any event/action combination not in this table → `WEBHOOK_NOT_ACTIONABLE`, exit 0.

## Config Schema (diff vs v1)

No new keys in `github_project`. Two new **additive** keys are written by `--init` if not present (default values shown; `--init` does not re-prompt for them):

```json
{
  "github_project": {
    "...existing v1 keys...": "...",
    "webhook_audit_dir": ".issue-to-project/lifecycle",
    "webhook_pr_link_patterns": ["Closes", "Fixes", "Resolves"]
  }
}
```

| Key | Default | Purpose |
|---|---|---|
| `webhook_audit_dir` | `.issue-to-project/lifecycle` | Root dir for per-delivery audit artifacts. Relative to repo root. |
| `webhook_pr_link_patterns` | `["Closes", "Fixes", "Resolves"]` | Case-insensitive prefixes scanned in PR body to find linked issues. Operators may extend (e.g. `"Relates to"`) but the skill warns if the list exceeds 10. |

All v1 `github_project` keys remain readable and required. `--init` does NOT re-run field discovery; it merges the two new keys with defaults unless they already exist.

## Audit Artifact (diff vs v1)

Normal-run writes to `specs/{slug}/project-sync.json`. Webhook-mode writes to a **different tree** because there is no slug:

```
.issue-to-project/lifecycle/
  2026-06-26/
    d1e2a3b4-5f6c-7890-abcd-ef1234567890.json   ← GITHUB_DELIVERY id
    d1e2a3b4-...another.json
```

The per-delivery artifact mirrors `project-sync.json`'s schema with two extensions:

```json
{
  "schema_version": "1",
  "slug": "_webhook",
  "run_timestamp": "2026-06-26T10:30:00Z",
  "skill_version": "2.1.0",
  "webhook": {
    "delivery_id": "d1e2a3b4-5f6c-7890-abcd-ef1234567890",
    "event_type": "pull_request",
    "action": "closed",
    "merged": true,
    "lifecycle_transition": "Done"
  },
  "project": { "...same as v1..." },
  "summary": { "...same as v1 keys..." },
  "results": [ "...same as v1 per-issue shape..." ]
}
```

New artifact keys: `webhook` block (all fields required in webhook-mode; null in manual-run mode). Existing v1 keys unchanged — downstream consumers that parse `project-sync.json` will also parse these artifacts without modification.

The `slug: "_webhook"` sentinel signals to downstream tools that the artifact was written in webhook mode and no `created-issues.json` exists.

## Argv & Flag Contract

Inherits all v1 flags. New flag:

| Flag | Description |
|---|---|
| `--from-webhook <path>` | Path to a JSON file containing the GitHub webhook event payload. Bypasses `created-issues.json` discovery; operates on the synthetic single-issue input derived from the payload. Mutually exclusive with `--init` and with a positional slug. |

Mutual exclusion rules (enforced via `argparse.add_mutually_exclusive_group`):
- `--from-webhook` + `--init` → exit 1: `"issue-to-project: --from-webhook and --init are mutually exclusive."`
- `--from-webhook` + positional slug → exit 1: `"issue-to-project: --from-webhook takes no positional slug argument."`
- `--from-webhook` + `DRY_RUN=1` → allowed; dry-run operates on the synthetic input.

New env var:

| Env var | Default | Purpose |
|---|---|---|
| `ITP_WEBHOOK_STRICT_LINK` | `0` | When `1`, `pull_request.*` events with no linked issue exit `1` (HALT `WEBHOOK_NOT_ACTIONABLE`) instead of the default exit `0`. Use in CI jobs where a missing PR→issue link should block the run. |

## Error Handling

All v1 error rows are unchanged. New rows for webhook-mode:

| Failure mode | When detected | Severity | Action |
|---|---|---|---|
| `--from-webhook` path does not exist | Pre-flag validation | **Abort** | Exit 1, HALT `MISSING_INPUT`: `"issue-to-project: webhook event file not found: <path>"` |
| Webhook payload is not valid JSON | Payload parse | **Abort** | Exit 1, HALT `WEBHOOK_PAYLOAD_INVALID`: `"issue-to-project: webhook payload at <path> is not valid JSON: <parse error>"` |
| Webhook payload missing required fields (`action`, one of `issue`/`pull_request`) | Schema check | **Abort** | Exit 1, HALT `WEBHOOK_PAYLOAD_INVALID`, name the missing field. |
| Event type + action not in the lifecycle transition map | Routing | **Exit 0** | Emit `[issue-to-project] INFO: event <type>/<action> is not actionable — skipping.` then `HALT: WEBHOOK_NOT_ACTIONABLE`. Exit 0 so the Action step passes. |
| PR body has no matching link pattern; `ITP_WEBHOOK_STRICT_LINK=0` | Link resolution | **Exit 0** | Emit `[issue-to-project] WARN: no linked issue found in PR #<N> body. Skipping lifecycle transition.` then `HALT: WEBHOOK_NOT_ACTIONABLE`. Exit 0. |
| PR body has no matching link pattern; `ITP_WEBHOOK_STRICT_LINK=1` | Link resolution | **Abort** | Exit 1, HALT `WEBHOOK_NOT_ACTIONABLE`: `"issue-to-project: no linked issue found in PR #<N> body. Set ITP_WEBHOOK_STRICT_LINK=0 to skip instead of failing."` |
| Audit dir creation fails (permissions) | Step 5 | **Exit 1** | HALT `AUDIT_WRITE_FAILED`: `"issue-to-project: cannot create webhook_audit_dir <path> — check filesystem permissions."` |
| Delivery ID not set (not running under Actions) | Step 5 fallback | **Soft-warn** | Log `[issue-to-project] WARN: GITHUB_DELIVERY not set; using timestamp-based ID for audit artifact filename.` Generate `<YYYYMMDDTHHMMSS>-<8-char-random-hex>.json`. Continue. |

## Cross-cutting

### Exit codes

Inherits v1 unchanged: `0` = success or partial success or non-actionable webhook; `1` = abort; `2` = `--init` user-cancelled. No new codes.

### HALT codes (new + inherited)

All v1 HALT codes are immutable. Two new codes:

| HALT code | Meaning | Exit |
|---|---|---|
| `WEBHOOK_PAYLOAD_INVALID` | Payload file not valid JSON or missing required top-level fields | 1 |
| `WEBHOOK_NOT_ACTIONABLE` | Event type/action not in transition map, or no linked issue found in PR body | 0 (default) or 1 (when `ITP_WEBHOOK_STRICT_LINK=1`) |

### Logging

Same prefixes as v1. `[issue-to-project:auto]` (previously reserved) is now used for webhook-mode inference decisions, specifically the PR-body link extraction and lifecycle-transition routing step:

```
[issue-to-project:auto] pull_request.closed merged=true → Status=Done for issue #47
[issue-to-project:auto] PR body match: "Closes #47" → https://github.com/owner/repo/issues/47
```

### Idempotency contract

Webhook events can fire twice (GitHub guarantees at-least-once delivery). The v1 re-run guard (step 3 board snapshot) makes the `item-add` path idempotent already — if the issue is already on the board, it is recorded as `already_on_board` and no edit is attempted.

For Status flips (`item-edit`) triggered by webhook events, the idempotency rule is: **if the item's current Status already matches the transition target, no `item-edit` call is made**. The snapshot (step 3) captures `currentStatusName`; the skill checks `currentStatusName == target_status_name` before calling `item-edit`. If they match, outcome is recorded as `already_on_board`.

This means a second delivery of the same `pull_request.closed merged=true` event produces zero mutations and exits 0 with all items as `already_on_board`.

## Return Format (R1)

Inherits v1's `RESULT: {json}` sentinel contract unchanged. In webhook mode, two new keys are added to the JSON object (existing keys unchanged):

```
RESULT: {"status":"ok","slug":"_webhook","artifact_path":".issue-to-project/lifecycle/2026-06-26/d1e2a3b4.json","issues_in_input":1,"already_on_board":0,"added":1,"set_blocked":0,"left_default":0,"add_failed":0,"edit_failed":0,"skipped_after_total_failure":0,"dry_run":0,"webhook_event":"pull_request/closed","webhook_transition":"Done"}
```

New keys: `webhook_event` (string, format `"<type>/<action>"`) and `webhook_transition` (string, the Status written, or `"none"` for `WEBHOOK_NOT_ACTIONABLE`). Both are null in non-webhook runs (additive; v1 parsers that ignore unknown keys are unaffected).

## Decisions

**D1 — GitHub Action as the primary hosting model**
Decided: the webhook listener is implemented as a GitHub Actions workflow. Not a self-hosted server or serverless function.
Reasons: (1) zero infrastructure cost and zero provisioning burden — the consumer only needs a workflow YAML and a repo secret; (2) auth is repo-secret PAT, the same model operators already use for `gh auth`; (3) GitHub's built-in retry and 30-day delivery log solve replay for free.
Alternatives rejected: (a) Fly.io/Cloud Run self-hosted server — requires persistent infra, TLS termination, secret rotation, and a public endpoint URL that must be registered as a webhook target; (b) AWS Lambda + SQS batching — adds deployment pipeline and IAM complexity that exceeds single-repo value; (c) Polling GitHub API on a cron — at-best-5-minute latency, burns API rate limit, detects changes by diff not by event.
Implications: the component is single-repo per workflow file; multi-tenant support requires a separate design (deferred to v3+).

**D2 — Fine-grained PAT in repo secrets, not GITHUB_TOKEN**
Decided: all `gh project` calls use `ITP_GITHUB_TOKEN` from a repo secret, not the default `GITHUB_TOKEN`.
Reasons: (1) `GITHUB_TOKEN` does not carry the `project` scope by default and GitHub does not allow granting it that scope on a per-repo basis; (2) a fine-grained PAT can be scoped to exactly the permissions needed (`read:org`, `project`) and rotated independently of the repo.
Alternatives rejected: (a) GitHub App installation token — more powerful but adds app registration overhead and webhook secret management; correct for v3 multi-tenant; (b) Classic PAT with `repo` + `project` — works but over-scoped; fine-grained PAT is the current GitHub best practice.
Implications: operators must create a fine-grained PAT with `read:org` and `project` permissions, add it as `ITP_GITHUB_TOKEN` in repo Settings > Secrets and variables > Actions. Doc in the workflow YAML comment block.

**D3 — `--from-webhook` flag on the skill, not a separate webhook-runner binary**
Decided: skill gains a new flag rather than shipping a separate entrypoint or wrapper script.
Reasons: (1) reuses all of v1's sync logic (snapshot, add, edit, audit write) without duplication; (2) keeps the audit artifact shape consistent between manual and webhook runs — same schema, same validation, same downstream consumers; (3) the flag contract is explicit and testable with a static JSON fixture.
Alternatives rejected: (a) a separate `issue-to-project-webhook` skill — duplicates the sync core and creates two HALT code surfaces to maintain; (b) a shell wrapper that calls the skill via subprocess — adds a process boundary with no benefit at single-repo scale.
Implications: the skill must handle three mutually exclusive modes (normal, `--init`, `--from-webhook`); `argparse` group enforcement is mandatory.

**D4 — Synthetic `_webhook` slug and separate audit dir**
Decided: webhook runs use slug sentinel `_webhook` and write to `.issue-to-project/lifecycle/<YYYY-MM-DD>/<delivery-id>.json` rather than `specs/_webhook/project-sync.json`.
Reasons: (1) the lifecycle audit tree is append-only (one file per delivery); overwriting a single `project-sync.json` per slug would make concurrently-fired webhooks race; (2) the date-partitioned layout makes retention cleanup trivial; (3) the `_webhook` slug sentinel lets downstream tools distinguish webhook artifacts from manual-run artifacts without inspecting the `webhook` block.
Alternatives rejected: (a) write to `specs/_webhook/project-sync.json` with overwrite semantics — loses per-delivery history; (b) append to a single NDJSON log — harder to parse, harder to replay a single delivery.
Implications: `.issue-to-project/` must be gitignored or committed depending on operator preference (see Migration Notes); the audit dir path is configurable via `webhook_audit_dir`.

**D5 — Non-actionable events exit 0, not exit 1**
Decided: events not in the lifecycle transition map (or PR with no linked issue when `ITP_WEBHOOK_STRICT_LINK=0`) emit `HALT: WEBHOOK_NOT_ACTIONABLE` and exit 0.
Reasons: (1) Actions treats any non-zero exit as a workflow failure, which would spam the repo's "Actions" tab with red runs on every non-actionable event (e.g. `issues.labeled` with a label other than `status:blocked`); (2) the HALT code in stdout still provides observability for operators who scan logs; (3) the `RESULT:` sentinel with `webhook_transition: "none"` provides machine-parseable signal.
Alternatives rejected: (a) exit 1 for non-actionable — would require the workflow to use `continue-on-error: true`, which also swallows real failures; (b) filter events only at the workflow `on:` level — GitHub's event filter grammar is too coarse to express "labeled with value X" without a separate job-level `if:` condition; both approaches are used in combination.
Implications: callers cannot use exit code alone to distinguish "skipped because not actionable" from "succeeded"; they must inspect the `RESULT:` webhook_transition key.

**D6 — PR→issue link via body scan, not the GitHub API**
Decided: the skill extracts the linked issue number by scanning the PR body for `Closes #N`-style keywords, not by calling `gh api repos/.../pulls/<N>/issues`.
Reasons: (1) no such REST endpoint exists in GitHub's v3 API for "issues closed by a PR"; the GraphQL `closingIssuesReferences` connection works but adds an extra network call and GraphQL surface to maintain; (2) the webhook payload already contains `pull_request.body` — a regex scan is offline and fast; (3) the pattern list is configurable via `webhook_pr_link_patterns` for operator customization.
Alternatives rejected: (a) GraphQL `closingIssuesReferences` — one extra network call, adds a new `gh api graphql` invocation with its own error surface; accurate for multi-issue PRs but over-engineered for single-issue common case; (b) requiring operators to pass the issue number as a workflow input — breaks the "zero-friction automation" goal.
Implications: PRs with no Closes-style keyword silently skip the transition (or fail hard with `ITP_WEBHOOK_STRICT_LINK=1`). Teams that use "relates to" rather than "closes" must add the keyword to `webhook_pr_link_patterns`.

**D7 — `issues.labeled` included as a trigger event**
Decided: `issues.labeled` events where `label.name == "status:blocked"` trigger a `Blocked` Status write, even for issues already on the board.
Reasons: (1) covers the post-hoc labeling case: an operator adds `status:blocked` to an issue that was already synced to the board as `Todo`; without this trigger, the board never reflects the label; (2) the v1 idempotency contract is preserved — if the item is already `Blocked`, the snapshot check suppresses the `item-edit`.
Alternatives rejected: (a) `issues.labeled` not included — leaves a gap for post-hoc labeling, which is a realistic operator workflow; (b) also handle `issues.unlabeled` for `status:blocked` → revert to `Todo` — bidirectional sync is O3; not here.
Implications: `issues.labeled` firing for other labels (e.g. `type:feat`) is handled by `WEBHOOK_NOT_ACTIONABLE` exit 0. The Action `if:` condition filters to `github.event.label.name == 'status:blocked'` to reduce runner minutes spent on non-actionable labeled events.

**D8 — Status flip idempotency via snapshot currentStatusName comparison**
Decided: before any `item-edit` call in webhook mode, compare the item's `currentStatusName` (from the step-3 snapshot) against the transition target. Skip the edit if they already match.
Reasons: (1) GitHub delivers webhooks at-least-once; a second delivery of the same event must not produce a redundant `item-edit` mutation; (2) the v1 re-run guard only suppresses `item-add` for already-on-board items, not `item-edit` for already-correct Status values; (3) zero extra network calls — the snapshot is already in memory.
Alternatives rejected: (a) always write the Status regardless of current value — produces spurious mutations visible in the board's activity log and wastes API quota; (b) deduplicate by delivery ID stored in a local cache file — adds state management complexity; the board itself is the source of truth.
Implications: if a human manually reverts a Status (e.g. sets Done → Todo after a PR merge), the next re-delivery of the same `pull_request.closed merged=true` event will NOT flip it back (the snapshot sees `Todo`, target is `Done` — they differ, so the edit WILL fire). The idempotency guarantee is delivery-scoped, not human-edit-preserving in webhook mode. This is intentional: webhook-mode is the authoritative Status driver; human overrides should be explicit.

**D9 — Workflow YAML lives at `.github/workflows/issue-to-project-lifecycle.yml`**
Decided: the canonical workflow file path is documented and templated in this spec. Operators copy it into their consuming repo.
Reasons: (1) it cannot live in the makato repo because it needs to trigger on the consumer repo's events; (2) a templated YAML in the spec (File-by-File Changes) is the most actionable format; (3) the path follows GitHub Actions naming convention and is discoverable.
Alternatives rejected: (a) a GitHub Actions reusable workflow hosted in the makato repo and called via `uses:` — requires the consumer repo to have access to the makato repo; appropriate for a marketplace product but not for a per-consumer template; (b) a Makefile target that creates the workflow file — adds a toolchain dependency.
Implications: operators are responsible for copying and maintaining the workflow YAML. Skill version upgrades may require updating the invocation command in the YAML.

**D10 — Replay procedure uses GitHub's webhook delivery log, not a custom replay command**
Decided: the recovery procedure for outage-window missed events is: navigate to Settings > Webhooks > Recent Deliveries in the consumer repo, filter to the outage window, and re-deliver each event via the GitHub UI or API. The skill does not ship a `--replay` flag in v2.1.
Reasons: (1) GitHub keeps 30 days of delivery logs with a one-click re-deliver button; (2) a `--replay` flag would need access to the delivery log via the GitHub API, adding a new API surface; (3) the per-delivery audit artifacts in `.issue-to-project/lifecycle/` provide a record of what was processed, letting operators identify gaps.
Alternatives rejected: (a) a `--replay <delivery-id>` flag — correct design for v3, but the delivery log API (`GET /repos/{owner}/{repo}/hooks/{hook_id}/deliveries`) requires additional PAT scopes; (b) polling on a 5-minute cron as a fallback — doubles the trigger surface and burns API quota.
Implications: operators must handle replay manually during the 30-day window. After 30 days, missed events require a manual `issue-to-project <slug>` run or a partial reconciliation approach.

## Out of Scope

| ID | Item | Why deferred |
|---|---|---|
| O1 | Multi-tenant listener (one Action / service serving multiple repos) | Single-repo-per-workflow-file is sufficient for v2.1. Multi-tenant design introduces routing, secret-per-repo management, and replay complexity. Own design cycle (v3+). |
| O2 | GitHub App installation token replacing the PAT | App token is the right answer for multi-tenant. For single-repo, PAT in repo secrets is simpler to set up and rotate. Revisit when O1 lands. |
| O3 | Bidirectional sync: board Status → issue labels | Would require a `project.item_edited` event (not yet available in GitHub webhooks as of 2026-06). Covered by O3 in v1 spec. |
| O4 | `--replay` flag to re-process deliveries from the GitHub delivery log API | Requires additional PAT scope (`admin:repo_hook`). Manual re-deliver via GitHub UI is sufficient for v2.1. |
| O5 | `issues.unlabeled` for `status:blocked` → revert to `Todo` | Bidirectional label↔Status sync is O3. Not in scope here. |
| O6 | Multi-issue PR links (one PR closes N issues) | The body-scan regex finds the first matching link. Multi-issue support adds iteration logic and multiple board mutations per event; deferred until there is clear demand. |
| O7 | `ITP_WEBHOOK_STRICT_LINK` default changed to `1` | Would break consumers with informal PR descriptions. Remains `0`; operators opt into strict mode. |

## File-by-File Changes

### Modified files

| Path | Change |
|---|---|
| `plugins/makato-plan/skills/issue-to-project/SKILL.md` | Add `--from-webhook <path>` to the Argv section and the HALT codes table; bump version to `2.1.0`. |
| `plugins/makato-plan/skills/issue-to-project/references/sync-process.md` | Add webhook-mode section: payload parse, transition-map routing, synthetic-input construction, audit-dir write logic. |
| `plugins/makato-plan/skills/issue-to-project/references/config-schema.md` | Document `webhook_audit_dir` and `webhook_pr_link_patterns` new optional keys. |
| `plugins/makato-plan/skills/issue-to-project/references/project-sync.schema.json` | Add `webhook` block schema (required in webhook mode, null-allowed in normal mode); add `webhook_event` and `webhook_transition` to the R1 RESULT keys comment. |
| `plugins/makato-plan/CHANGELOG.md` | New `**2.1.0**` block under `issue-to-project`. |

### New files

| Path | Purpose |
|---|---|
| `plugins/makato-plan/skills/issue-to-project/references/webhook-lifecycle.md` | Lifecycle transition map, payload parse rules, body-scan regex, `--from-webhook` step-by-step flow, replay procedure, token setup guide. Loaded only when `--from-webhook` is in argv. |

**Consumer repo file (templated — operator copies this):**

```yaml
# .github/workflows/issue-to-project-lifecycle.yml
# Copy this file into your consuming repo and set ITP_GITHUB_TOKEN as a repo secret.
# Required secret: ITP_GITHUB_TOKEN — fine-grained PAT with read:org + project scopes.

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

**Token setup (document in `webhook-lifecycle.md` and workflow comment):**

1. Go to https://github.com/settings/tokens?type=beta.
2. Create a fine-grained PAT scoped to the consuming repo with permissions: `Issues: Read`, `Projects: Read and write`, `Pull requests: Read`.
3. Add it as a repo secret named `ITP_GITHUB_TOKEN` in Settings > Secrets and variables > Actions.
4. The workflow uses `GH_TOKEN` (the env var `gh` reads by default) set to the secret value. `GITHUB_TOKEN` is not used for `gh project` calls.

## Testing Strategy

Inherits v1's posture (static + dry-run + live smoke). Additional webhook-mode tests:

| Test | What it covers | How |
|---|---|---|
| Payload validation | `WEBHOOK_PAYLOAD_INVALID` on malformed JSON and on missing `action` field | Static: hand-crafted bad payloads, run with `--from-webhook`, assert HALT code on stdout |
| Transition routing | Each row in the lifecycle transition map | Static: fixture JSONs for each event/action combination; run with `DRY_RUN=1 --from-webhook`; assert `webhook_transition` in RESULT sentinel |
| Non-actionable exit 0 | `issues.labeled` with label other than `status:blocked` | Static: fixture; assert exit 0 and `HALT: WEBHOOK_NOT_ACTIONABLE` on stdout |
| PR body scan | `Closes #N`, `Fixes #N`, `Resolves #N` — and no match | Static: fixture PR body strings; run body-scan function in isolation via `python3 -c` |
| Idempotency under double delivery | Two identical `--from-webhook` invocations; second run records all items as `already_on_board` | Manual against live project; verify audit artifact shows `already_on_board` on second run |
| Audit dir creation | `.issue-to-project/lifecycle/YYYY-MM-DD/` created if absent | Manual dry-run |
| Delivery ID fallback | `GITHUB_DELIVERY` unset → timestamp-based filename generated | Static: run without env var; verify filename pattern |
| Live Action smoke | Push a PR to a test repo; verify board transitions | Manual, one-time per release |

## Migration Notes

**v1.0.0 → v2.1.0 (consumers already running v1):**

1. Run `issue-to-project --init` once to merge the two new config keys (`webhook_audit_dir`, `webhook_pr_link_patterns`) into `.claude/config.json`. No re-prompting; `--init` detects existing v1 config and merges defaults only.
2. Copy `.github/workflows/issue-to-project-lifecycle.yml` (from File-by-File Changes above) into the consuming repo.
3. Create `ITP_GITHUB_TOKEN` repo secret (see Token setup above).
4. Add `.issue-to-project/` to `.gitignore` if audit artifacts should not be committed, or `git add .issue-to-project/` if they should be versioned. No default either way — operator decision.
5. Existing `specs/*/project-sync.json` artifacts from v1 runs are unaffected; the new webhook audit tree is separate.

**Token scope note:** if the consumer is already using a PAT for manual `issue-to-project` runs (set via `gh auth login --with-token`), that token may already have `project` scope. Reuse it as `ITP_GITHUB_TOKEN` to avoid creating a second PAT.

**No breaking changes to v1 contracts:** the `--from-webhook` flag is additive; all v1 HALT codes, exit codes, R1 sentinel keys, and audit artifact fields are unchanged.
