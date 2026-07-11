---
name: issue-to-project
description: >-
  Use when issues created by `to-issues` need to land on a GitHub Projects v2 board, or after
  any `to-issues` run when the operator wants Status=Blocked reflected on the board for issues
  tagged `status:blocked`. The natural workflow successor to `to-issues`. Reads `.claude/config.json`
  → `github_project` for cached project/field IDs, snapshots existing board items once,
  then adds each not-yet-on-board issue and conditionally sets Status=Blocked. Emits
  `specs/{slug}/project-sync.json` as a machine-readable audit. Run `issue-to-project --init` once
  per repo to set up project board sync. Use `issue-to-project sync-lifecycle [<slug>]` to
  automatically advance board Status to `In Progress`, `In review`, or `Done` as linked PRs open or merge.
  Use `issue-to-project --from-webhook <event-json-path>` for push-mode lifecycle sync driven by
  GitHub Actions webhook events (issues.opened, issues.labeled, pull_request.opened/closed).
  Use `issue-to-project reconcile [<slug>]` to diff the live board snapshot against expected state
  and detect/repair board drift without mutating by default.
  Use `issue-to-project --board-audit` for a read-only board-wide snapshot across all known repos
  feeding a shared GitHub Projects v2 board (cross-repo pattern, v2.3.0+).
  Use `issue-to-project --fields-only [<slug>]` to backfill non-Status field values (Priority,
  Iteration, Estimate, Date Target) for issues already on the board without re-adding them (v2.4.0+).
license: MIT
version: "2.8.0"
argument-hint: "[optional: feature slug] | --init | --retry-blocked-edits [<slug>] [--from <path>] | sync-lifecycle [<slug>] [--dry-run] | --from-webhook <event-json-path> | reconcile [<slug>] [--repair-additive | --repair-aggressive [--yes-i-know]] | --board-audit | --fields-only [<slug>] | --auto-reinit | --no-auto-reinit"
allowed-tools: Bash(gh *) Bash(git *) Bash(python3 *) Bash(timeout *) Read Write Grep Glob
hooks: ["sync issues to project", "land issues on board", "push issues to GitHub Projects", "update project board", "project board sync", "issue-to-project", "follow up to-issues with project sync", "set status on board", "init project board sync", "retry blocked edits", "recover blocked status", "route issues by status label", "route status:ready", "route status:in-review", "autonomous auto-promote"]
metadata:
  Authors: makato contributors
  last_updated: "2026-07-09"
  mcp_server: none
---

# Issue to Project

Sync GitHub issues to a GitHub Projects v2 board (github.com or a GitHub Enterprise Server instance, v2.6.0+). Strict consumer of `to-issues` v3.2.0's `created-issues.json` contract: reads `labels[]` to decide Status routing. Adds every new issue at the project default (`Todo`), then routes to the column matched by the issue's `status:*` label. Never removes items from the board. Never overwrites a Status that was changed externally after the board entry was created.

**Status routing (v2.7.0):**

| Label | Final Status | Notes |
|---|---|---|
| `status:todo` | `Todo` | Explicit no-op write (records `added_todo_explicit` outcome, distinct from `added_default`) |
| `status:ready` | `Ready` | New in v2.7; requires `options.ready` in config — absent → `Todo` + loud `WARN` |
| `status:in-progress` | `In Progress` | New in v1.2 |
| `status:in-review` | `In review` | New in v2.7; requires `options.in_review` in config — absent → `Todo` + loud `WARN` |
| `status:blocked` | `Blocked` | Unchanged from v1.0 |
| `status:done` | `Done` | New in v1.2 |
| _(none)_ | `Todo` (project default) | `added_default` outcome; in `ready_queue_mode: "autonomous"` may be auto-promoted to `Ready` |
| Unknown `status:*` (e.g. `status:wontfix`) | `Todo` (project default) | Loud `WARN`; falls through to default; never aborts |
| Multi-label collision (e.g. `status:blocked` + `status:in-progress`) | Priority winner | `blocked > done > in-review > in-progress > ready > todo`; loud `WARN` with the full collision set |

Routing comes from `labels[]` in `created-issues.json` only — the skill never queries live GitHub labels. Re-runs do NOT re-route already-on-board items, even if labels changed since the original run (see Idempotency contract).

**Upstream emission status:** `to-issues` v3.2.0 emits only `status:blocked` at issue-creation time. The other label paths (`status:todo`, `status:in-progress`, `status:done`, `status:ready`, `status:in-review`) are dormant for auto-emission — they activate when a future `to-issues` release adds emission or when operators manually relabel issues between `to-issues` and `issue-to-project` runs. v1.2 is strictly additive: without the new labels, behavior is byte-for-byte identical to v1.0.0.

**PR label stamp (v2.7.0+):** when `sync-lifecycle` or `--from-webhook` detects a linked open PR for an issue, the skill calls `gh issue edit --add-label <pr_label_name>` on that issue. The label is a **permanent historical marker** — the skill NEVER removes it, even after the PR closes or merges. Default label name is `"PR"` (configurable via `pr_label_name` in config; empty string `""` disables all label calls). `--init` creates the label in the repo if absent (color `0E8A16`, description `"This issue has an open linked pull request."`). The add-label call is additive and idempotent at the GitHub API level; `pr_label_action` row field encodes `"added"` or `"failed"`; `pr_label_added` / `pr_label_failed` summary counters track totals per run.

**Ready-for-dev label stamp (v2.8.0+):** when autonomous mode (`ready_queue_mode: "autonomous"`) auto-promotes a `Todo` item to `Ready`, the skill calls `gh issue edit --add-label <ready_label_name>` on that issue — a passive handoff marker the downstream orchestrator (`makato-orchestrate` po-agent / loop) can grep without reading the board. Like the PR label, it is a **permanent historical marker** the skill NEVER removes. Default label name is `"status:ready-for-dev"` (configurable via `ready_label_name` in config; empty string `""` disables the stamp). `--init` v2.8.0+ creates the label in the repo if absent (color `0075CA`, blue). The `ready_label_action` row field encodes `"added"` or `"failed"`; `ready_label_stamped` / `ready_label_failed` summary counters track totals per run. Fired **only** on the `auto_promoted_ready` outcome in autonomous mode — never by `sync-lifecycle` or `--from-webhook`. Note: `status:ready-for-dev` is exempted from the `auto_promote_to_ready()` `status:*` block guard (it is stamped by the skill itself, not an operator routing signal), so it never suppresses promotion; operators wanting to block a `Todo` item use `status:todo`, `needs-human-review`, `hold-in-todo`, or a `blocked-by:*` label.

## Tools

| Tool | Purpose |
|------|---------|
| `Bash(gh *)` | Discover projects, fields, options; add and edit project items on the configured host (`--hostname <host>`) |
| `Bash(git *)` | Resolve repo root |
| `Bash(python3 *)` | Parse `.claude/config.json`, validate `created-issues.json` and `project-sync.json` against schemas, render outcomes |
| `Bash(timeout *)` | Wrap every `gh project` call so a hung call doesn't block the batch indefinitely |
| `Read` | Load references, config, input, schemas |
| `Write` | Write `specs/{slug}/project-sync.json` and `.claude/config.json` (during `--init`) |
| `Grep`, `Glob` | Locate `created-issues.json` via slug discovery |

## Reference Files

- **MANDATORY (every run)** — load `references/config-schema.md` for the `github_project` block contract and validation rules.
- **MANDATORY (every run)** — load `references/project-sync.schema.json` as the validation schema for the output artifact.
- **MANDATORY (`--init` runs)** — load `references/init-wizard.md` for the 6-step `--init` flow with exact `gh` invocations, prompt phrasing, and config-write template.
- **MANDATORY (normal runs)** — load `references/sync-process.md` for the 5-step normal-run flow with exact `gh` invocations, snapshot logic, item-add/item-edit decision rules, and audit-artifact emission rules.
- **MANDATORY (`--retry-blocked-edits` runs)** — load `references/retry-process.md` for the 3-step retry flow with exact `gh project item-edit` invocations, 404 detection, outcome routing, and artifact-forwarding rules.
- **MANDATORY (`sync-lifecycle` runs)** — load `references/lifecycle-process.md` for the 5-step lifecycle-transition flow with exact GraphQL query shape, PR-selection precedence rule, per-item outcome routing, `.bak` write, and artifact emission rules.
- **MANDATORY (`--from-webhook` runs)** — load `references/webhook-lifecycle.md` for the full webhook event parse, transition-map routing, synthetic-input construction, PR-body link extraction, audit-dir write, and replay procedure.
- **MANDATORY (`reconcile` runs)** — load `references/reconcile-process.md` for the full reconcile flow: paged snapshot, 6 drift-case classifiers, repair-mode dispatch, TTY confirmation, artifact emission, and human summary format.
- **MANDATORY (`--board-audit` runs)** — load `references/board-audit.md` for the full board-audit flow: `item-list` call, `repository.nameWithOwner` extraction, grouping by known/unknown repos, `board-audit.json` write, schema, and HALT rules.
- **MANDATORY (normal runs and `--fields-only` runs with `fields` config)** — load `references/field-type-routing.md` for the per-field-type write call reference: single-select (`--single-select-option-id`), iteration (`--iteration-id`), number (`--number`), date (`--date`); signal resolution rules per type; `SIZE_MAP` constant; and the field-write loop dispatch table.
- **MANDATORY (normal runs when `--auto-reinit` flag is active or stale-config trigger fires)** — load `references/auto-reinit-process.md` for the auto-re-init sub-path: title migration, project-list matching algorithm, Status-field validation, config-write rules, loop guard, and `STALE_CONFIG_PERSISTENT` / `AMBIGUOUS_REINIT` halt conditions.

## Argv & flag contract

- `issue-to-project` — normal sync; resolves slug via most-recent-mtime if not passed.
- `issue-to-project <slug>` — normal sync against the named slug.
- `issue-to-project --init` — interactive setup wizard.
- `issue-to-project --retry-blocked-edits` — retry the `item-edit` step for prior-artifact rows tagged `needs_status_retry: true`; resolves slug via most-recent-mtime against `specs/*/project-sync.json` if not passed.
- `issue-to-project --retry-blocked-edits <slug>` — retry against the named slug's prior `project-sync.json`.
- `issue-to-project --retry-blocked-edits --from <path>` — retry against the explicit prior-artifact path (operators with non-standard layouts).
- `issue-to-project sync-lifecycle` — lifecycle transition run; queries linked PRs for each issue in the most-recent `project-sync.json`; resolves slug via most-recent-mtime.
- `issue-to-project sync-lifecycle <slug>` — lifecycle transition run against the named slug's `project-sync.json`.
- `issue-to-project sync-lifecycle --dry-run` — prints what would change; no `item-edit` calls; writes artifact with `outcome: "dry_run"` for lifecycle rows. Both `--dry-run` flag and `DRY_RUN=1` env var are honored; flag takes precedence.
- `issue-to-project --from-webhook <path>` — webhook-mode sync; reads and validates the GitHub Actions webhook event JSON at `<path>`; derives a synthetic single-issue input from the payload; runs the normal board snapshot + add/edit cycle with the Status determined by the lifecycle transition map; writes the audit artifact to `<webhook_audit_dir>/<YYYY-MM-DD>/<delivery-id>.json`.
- `--init` and `--retry-blocked-edits` are in the same `argparse.add_mutually_exclusive_group()`. Passing both exits `1`: `"issue-to-project: --init and --retry-blocked-edits are mutually exclusive."`
- `sync-lifecycle` is **mutually exclusive** with `--init` and is a positional subcommand, not a flag. Passing `--init sync-lifecycle` exits `1`.
- `--init` and a positional slug are **mutually exclusive**: passing both exits `1` with `"issue-to-project: --init takes no positional slug argument."`
- `--from-webhook` is **mutually exclusive** with `--init`: passing both exits `1` with `"issue-to-project: --from-webhook and --init are mutually exclusive."`
- `--from-webhook` and a positional slug are **mutually exclusive**: passing both exits `1` with `"issue-to-project: --from-webhook takes no positional slug argument."`
- `--from-webhook` and `--retry-blocked-edits` are **mutually exclusive**: passing both exits `1`.
- `--from-webhook` and `sync-lifecycle` are **mutually exclusive**: passing both exits `1`.
- `--from-webhook` + `DRY_RUN=1` is **allowed**; dry-run operates on the synthetic input derived from the payload.
- `--from` without `--retry-blocked-edits` exits `1`: `"issue-to-project: --from requires --retry-blocked-edits."`
- A positional `<slug>` and `--from` together exit `1`: `"issue-to-project: --from and a positional slug are mutually exclusive — use one to identify the prior artifact."`
- `issue-to-project reconcile` — union all `specs/*/created-issues.json`; read-only drift report; written to `specs/.reconcile-report.json`.
- `issue-to-project reconcile <slug>` — scoped to one slug; read-only drift report; written to `specs/{slug}/reconcile-report.json`.
- `issue-to-project reconcile [<slug>] --repair-additive` — fix only `sync_gap` items (v1 safe re-sync logic); no confirmation required; safe for scripts.
- `issue-to-project reconcile [<slug>] --repair-aggressive` — fix all repairable drift; requires interactive `yes` confirmation on a TTY, or `--yes-i-know` for non-TTY / CI.
- `issue-to-project reconcile [<slug>] --repair-aggressive --yes-i-know` — skip interactive confirmation (required on non-TTY).
- `--repair-additive` and `--repair-aggressive` are mutually exclusive. Passing both exits `1`: `"issue-to-project: --repair-additive and --repair-aggressive are mutually exclusive."`
- `reconcile` and `--init` are mutually exclusive. Passing both exits `1`.
- `--reconcile` is accepted as an alias for `reconcile` (positional subcommand) for backward compatibility (D1); treated identically.
- `DRY_RUN=1 issue-to-project reconcile ...` — reads and classifies drift; repair calls replaced by `cli_command` output only; no mutations; artifact still written.
- `DRY_RUN=1` env var — controls dry-run behavior in normal-run AND `--retry-blocked-edits` (prints would-be `item-edit` calls, writes artifact with `outcome: "dry_run"` for retried rows); ignored in `--init`. No `--dry-run` flag for these modes (env-var convention matches `to-issues`). Exception: `sync-lifecycle` additionally supports `--dry-run` flag (more discoverable for a standalone invocation).
- `ITP_GH_TIMEOUT_SECONDS` env var — overrides the default 30-second per-`gh`-call timeout (applies to each `item-edit` in retry runs and each `gh api graphql` call in `sync-lifecycle`).
- `PROJECT_LIST_LIMIT` env var — overrides the `--init` project-list cap (default 50).
- `ITP_WEBHOOK_STRICT_LINK` env var — default `0`. When `1`, `pull_request.*` events with no linked issue in the PR body exit `1` (HALT `WEBHOOK_NOT_ACTIONABLE`) instead of the default exit `0`. Use in CI jobs where a missing PR→issue link should block the run.
- `ITP_RECONCILE_PAGE_SIZE` env var — default `100`. Overrides items-per-page in the paged board snapshot loop used by `reconcile`. Applies only to the `reconcile` subcommand path; normal-run and `--retry-blocked-edits` are unaffected. `ITP_GH_TIMEOUT_SECONDS` still applies per-call inside the reconcile paged loop.
- `issue-to-project --board-audit` — read-only board-wide snapshot (v2.3.0+). Calls `gh project item-list --limit 9999`, groups items by `repository.nameWithOwner`, counts per-repo and per-status, writes `board-audit.json` to the repo root. No mutations. Exits `0` on success; `1` on HALT. Mutually exclusive with `--init` and with a positional slug — passing both exits `1` with `"issue-to-project: --board-audit takes no positional slug and cannot be combined with --init."` (`argparse.add_mutually_exclusive_group`).
- `--board-audit` with `DRY_RUN=1` — no-op; audit is already read-only; `DRY_RUN` has no effect on `--board-audit` but is accepted silently.
- `issue-to-project --fields-only [<slug>]` — field-write-only run (v2.4.0+). Skips item-add entirely; runs only the field-write loop for issues whose URL is already on the board (items not on the board are recorded as `outcome: "not_on_board_skipped"`). Slug resolution follows normal-run rules (explicit positional or most-recent-mtime). Mutually exclusive with `--init`: passing both exits `1` with `"issue-to-project: --fields-only and --init are mutually exclusive."` Useful for backfilling field values after config is extended without triggering duplicate-add attempts.
- `ITP_SKIP_FIELDS` env var (v2.4.0+) — comma-separated list of field keys to skip in this run (e.g. `ITP_SKIP_FIELDS=priority,iteration`). Applies to both normal-run and `--fields-only`. Useful for partial rollouts or debugging. Keys must match entries in `fields` dict exactly; unrecognised keys emit a soft-warn and are ignored.
- `ITP_SKIP_VERIFY` env var (v2.3.0+) — default unset. When `1`, bypasses Pre-flight check 5 (verify-on-first-call). Logs `[issue-to-project] WARN: ITP_SKIP_VERIFY=1 — skipping board ID verification`. Use only as a short-term escape hatch in CI environments with flaky connectivity; schedule a periodic re-init to catch genuine drift.
- `ITP_UNKNOWN_REPO_BEHAVIOR` env var (v2.3.0+) — `"warn"` (default) or `"error"`. Controls whether `UNKNOWN_REPO` is a soft-warn or a hard abort during `reconcile` with `reconcile_scope == "all-known-repos"`. Does not affect `--board-audit`.
- **`GH_HOST` env var note (v2.6.0+):** If `GH_HOST` is set in your environment to a different host than `github_project.host`, `gh` will use `GH_HOST`. Unset it (`unset GH_HOST`) to avoid silent mis-targeting when running v2.6 against a GHES host that differs from your `GH_HOST` value.
- `--auto-reinit` flag (v2.5.0+) — opt-in activation of the auto-re-init sub-path for v2.5 burn-in. In v2.5, auto-reinit defaults **OFF**; passing `--auto-reinit` enables it. In v2.6, the default flips and `--auto-reinit` becomes a no-op. Mutually exclusive with `--init`: passing both exits `1` with `"issue-to-project: --auto-reinit and --init are mutually exclusive."` Can be combined with `DRY_RUN=1`: reads run normally; config write is suppressed; artifact records `new_project_node_id: "dry_run_not_written"`.
- `--no-auto-reinit` flag (v2.5.0+) — in v2.5 this flag is parsed but is a **no-op** (auto-reinit already defaults OFF); logs `[issue-to-project] INFO: --no-auto-reinit has no effect in v2.5; auto-reinit defaults OFF`. In v2.6 (when auto-reinit defaults ON), this flag reverts to v1 `STALE_CONFIG` halt behavior. Accepted without error in both versions.

## Process

### Step 0 — Pre-flight checks (always)

Run these four checks in order. ANY failure exits `1` with HALT `PREFLIGHT_FAILED` and the documented actionable message. No config read, no spec read, no network beyond `gh auth status` happens before they pass.

| # | Check | Command | Failure message |
|---|---|---|---|
| 1 | `gh` binary on PATH | `command -v gh` | `"issue-to-project: 'gh' CLI not found. Install: https://cli.github.com/"` |
| 2 | `gh` authenticated (for resolved host) | `gh --hostname <resolved_host> auth status` | `"issue-to-project: 'gh' is not authenticated for host <host>. Run 'gh auth login --hostname <host>' then retry."` |
| 3 | `gh` ≥ v2.13.0 (`project` subcommand exists) | `gh project --help >/dev/null 2>&1` | `"issue-to-project: installed 'gh' does not support the 'project' subcommand. Upgrade to ≥ v2.13.0: https://github.com/cli/cli/releases"` |
| 4 | `project` OAuth scope (deferred) | First real `gh project` call; trap stderr containing `requires the 'project' scope` or `Your token has not been granted the required scopes` | `"issue-to-project: token is missing the 'project' scope. Run 'gh auth refresh -s project,read:project' then retry."` |

Check 4 cannot be pre-flighted directly (`gh auth status` doesn't report scopes uniformly). The first `gh project list` (in `--init`) or `gh project item-list` (in normal-run) is wrapped: on a scope-error stderr match, surface message #4 verbatim and exit with HALT `PREFLIGHT_FAILED` instead of the generic step abort.

**Pre-flight check 5 — Verify-on-first-call (v2.3.0+, normal-run only)**

After checks 1–4 pass and config is read (step 1), run a cheap `gh project view` probe to confirm cached `project_node_id` and `status_field_id` still match the live board. Applies to every normal sync run. Skipped when `ITP_SKIP_VERIFY=1` (logs a WARN). Skipped for `--board-audit` (read-only, no IDs to validate). Skipped for `--init` (IDs are being written, not read). See `references/sync-process.md` §Pre-flight check 5 for the exact command and assertion snippet.

| # | Check | Command | Failure message |
|---|---|---|---|
| 5 | Board ID verify (verify-on-first-call) | `GH_HOST=<resolved_host> gh project view <number> --owner <owner> --format json` piped to Python assertion | `"issue-to-project: cached project_node_id or status_field_id does not match live board. Re-run 'issue-to-project --init'."` → HALT `CROSS_REPO_VERIFY_FAILED` |

**Pre-flight check 6 — GHES version gate (v2.6.0+, enterprise only)**

When `github_project.host_type == "enterprise"` (resolved after Step 1 config read), run a `/meta` API call to confirm the GHES installed version meets `min_ghes_version` (default `"3.10"`). Applies to `--init`, normal-run, `sync-lifecycle`, and `--from-webhook` paths. Skipped when `host_type == "cloud"` (including the github.com default).

| # | Check | Command | Failure message |
|---|---|---|---|
| 6 | GHES version ≥ min_ghes_version (enterprise only) | `gh --hostname <host> api /meta` → extract `installed_version` → compare as integer tuples | `"issue-to-project: GHES <installed_version> on <host> does not support Projects v2 (requires 3.10+). Upgrade GHES or use classic Projects instead."` → HALT `GHES_TOO_OLD` |

### Step 1 — Dispatch by mode

- If `--init` is in argv (and no positional slug): load `references/init-wizard.md` and follow its 6 steps.
- Else if `--retry-blocked-edits` is in argv: load `references/retry-process.md` and follow its 3 steps.
- Else if `sync-lifecycle` is the first positional argument: load `references/lifecycle-process.md` and follow its 5 steps.
- Else if `--from-webhook <path>` is in argv: load `references/webhook-lifecycle.md` and follow its 9 steps.
- Else if `reconcile` is the first positional argument (or `--reconcile` alias is present): load `references/reconcile-process.md` and follow its 6 steps.
- Else if `--board-audit` is in argv: load `references/board-audit.md` and follow the board-audit flow.
- Else if `--fields-only` is in argv: load `references/sync-process.md` and `references/field-type-routing.md`; skip item-add entirely and run only the field-write loop for issues already on the board.
- Otherwise: load `references/sync-process.md` and follow its 5 steps.

The five paths share Pre-flight, the same config reader, and the same `gh` wrappers, but no other state. `--retry-blocked-edits` never invokes the snapshot step from `sync-process.md` — the prior artifact's `project_item_id` is the only board reference it needs. `sync-lifecycle` reads the prior `project-sync.json` as its input (not `created-issues.json`) and never re-adds issues. `--from-webhook` bypasses `created-issues.json` entirely and derives its input from the webhook payload.

## Return Format (R1)

Emit a single-line stdout sentinel as the second-to-last line of stdout (the last line is the `Next: ...` handoff, with optional `HALT: <code>` after on failure).

**Normal-run shape:**

```
RESULT: {"status":"ok","slug":"<slug>","artifact_path":"specs/<slug>/project-sync.json","issues_in_input":12,"already_on_board":3,"added":9,"set_todo":1,"set_ready":1,"set_in_progress":2,"set_in_review":2,"set_blocked":2,"set_done":1,"auto_promoted_ready":0,"ready_label_stamped":0,"ready_label_failed":0,"left_default":0,"add_failed":0,"edit_failed":0,"skipped_after_total_failure":0,"dry_run":0,"ready_queue_mode":"manual"}
```

`host` is an optional additive key emitted in the RESULT when the configured host is non-default (i.e. not `"github.com"`). Existing parsers that only read the v1 keys are unaffected.

`set_ready` and `set_in_review` slot into the existing `set_*` count series (v2.7.0+). `auto_promoted_ready` is a new top-level counter that always appears with at least `0`. `ready_label_stamped` / `ready_label_failed` (v2.8.0+) count the ready-for-dev label stamps applied during autonomous promotion; both always appear with at least `0` and are always `0` in manual mode. `ready_queue_mode` echoes the active config value (`"manual"` or `"autonomous"`). `field_writes_attempted`, `field_writes_succeeded`, and `field_writes_failed` are present when the `fields` config block is present; they are `0` / absent otherwise. (`pr_label_added` / `pr_label_failed` appear only in `sync-lifecycle` RESULT output, not normal-run — PR labels are stamped on PR-lifecycle transitions, never during issue sync.)

**Normal-run shape with auto-reinit (v2.5.0+, when `--auto-reinit` fires):**

```
RESULT: {"status":"ok","slug":"my-feature","artifact_path":"specs/my-feature/project-sync.json","issues_in_input":12,"already_on_board":3,"added":7,"set_blocked":2,"left_default":5,"add_failed":0,"edit_failed":0,"skipped_after_total_failure":0,"dry_run":0,"auto_reinit":{"fired":true,"old_node_id":"PVT_old","new_node_id":"PVT_new","recovered":2}}
```

`auto_reinit` key is present only when auto-re-init fired during the run. When auto-re-init did not fire, `auto_reinit` is absent (not `null`) to keep the sentinel compact. Callers testing for recovery use `"auto_reinit" in result`. A run that auto-reinited and then succeeded fully emits `status: "ok"`.

**Normal-run shape with cross-repo config (v2.3.0+, when `known_repos` is present):**

```
RESULT: {"status":"ok","slug":"my-feature","artifact_path":"specs/my-feature/project-sync.json","issues_in_input":12,"already_on_board":3,"added":9,"set_blocked":2,"left_default":7,"add_failed":0,"edit_failed":0,"skipped_after_total_failure":0,"dry_run":0,"cross_repo":{"verify_passed":true,"known_repos_count":2}}
```

`cross_repo` key is omitted from the RESULT JSON when `known_repos` is absent from config.

**`--retry-blocked-edits` shape** (counts reflect this invocation, not the prior artifact — the v1 add/edit counts belong to the prior run):

```
RESULT: {"status":"ok","slug":"<slug>","artifact_path":"specs/<slug>/project-sync.json","retried_count":1,"retry_succeeded":1,"retry_failed":0,"retry_item_gone":0}
```

**`sync-lifecycle` shape** (v2 keys added; all v1 normal-run keys retained for backward compatibility):

```
RESULT: {"status":"ok","slug":"<slug>","artifact_path":"specs/<slug>/project-sync.json","issues_in_input":12,"already_on_board":12,"added":0,"set_blocked":0,"left_default":0,"add_failed":0,"edit_failed":0,"skipped_after_total_failure":0,"dry_run":0,"set_in_progress":1,"set_in_review":2,"set_done":1,"auto_promoted_ready":0,"pr_label_added":2,"pr_label_failed":0,"ready_queue_mode":"manual","lifecycle_lookup_failed":0,"lifecycle_skipped":4}
```

`sync-lifecycle` sets `status: "partial"` when `lifecycle_lookup_failed > 0`.

**`--from-webhook` shape** (inherits all normal-run keys; two new keys added):

```
RESULT: {"status":"ok","slug":"_webhook","artifact_path":".issue-to-project/lifecycle/2026-06-26/d1e2a3b4.json","issues_in_input":1,"already_on_board":0,"added":1,"set_blocked":0,"left_default":0,"add_failed":0,"edit_failed":0,"skipped_after_total_failure":0,"dry_run":0,"webhook_event":"pull_request/closed","webhook_transition":"Done"}
```

New keys: `webhook_event` (string, format `"<type>/<action>"`) and `webhook_transition` (string, the Status written, or `"none"` for `WEBHOOK_NOT_ACTIONABLE`). Both are `null` in non-webhook runs (additive; v1 parsers that ignore unknown keys are unaffected).

**`reconcile` shape:**

```
RESULT: {"status":"ok","mode":"read_only","slug_scope":"my-feature","artifact_path":"specs/my-feature/reconcile-report.json","drift_total":3,"repaired":0,"orphans":1,"sync_gap":0,"label_blocked_board_not":1,"board_blocked_label_not":0}
```

`mode` values: `"read_only"`, `"repair_additive"`, `"repair_aggressive"`. `slug_scope` is the slug if scoped, or `"*"` for a union (slug-less) run. `artifact_path` is `specs/{slug}/reconcile-report.json` for slug-scoped runs or `specs/.reconcile-report.json` for union runs. New keys are additive; v1 parsers that ignore unknown keys are unaffected.

After the sentinel, human handoff line:

```
Next: review specs/<slug>/reconcile-report.json; orphans listed in orphans_for_review[] require manual board action.
```

**`--board-audit` shape (v2.3.0+):**

```
RESULT: {"status":"ok","artifact_path":"board-audit.json","total_items":47,"known_repos_count":2,"unknown_repos_count":1}
```

No `slug` key in `--board-audit` RESULT; the artifact is board-wide, not slug-scoped.

`status` values (all shapes): `"ok"` (exit 0, no failures), `"partial"` (exit 0 but `add_failed > 0` / `edit_failed > 0` / `retry_failed > 0` / `lifecycle_lookup_failed > 0`), `"failed"` (exit 1, any HALT).

Downstream consumers parse with `grep '^RESULT: ' | sed 's/^RESULT: //' | python3 -c "import json,sys; print(json.load(sys.stdin))"`.

## Exit codes

- `0` — success or partial success with ≥ 1 item synced (the artifact has been written).
- `1` — abort or zero items synced (the artifact is still written for normal-run; only `--init` aborts and `AUDIT_WRITE_FAILED` skip the artifact).
- `2` — `--init` user-cancelled or `--repair-aggressive` interactive confirmation cancelled. No other code produces exit 2.

## HALT codes

Every nonzero exit prints a single-line tail `HALT: <code>` to stdout after the actionable message. Callers parse with `tail -n 1 | sed 's/^HALT: //'`.

| HALT code | Meaning | Exit |
|---|---|---|
| `PREFLIGHT_FAILED` | `gh` binary missing, not authenticated, too old, or missing the `project` scope | 1 |
| `MISSING_CONFIG` | `.claude/config.json` or `github_project` block absent | 1 |
| `MALFORMED_CONFIG` | config invalid JSON, required key missing, or ID format failure | 1 |
| `MISSING_INPUT` | `created-issues.json` not found at the resolved path | 1 |
| `MALFORMED_INPUT` | `created-issues.json` failed schema validation | 1 |
| `EMPTY_INPUT` | `created-issues.json` has `issues: []` | 1 |
| `AMBIGUOUS_SLUG` | two specs share identical mtime and no positional slug | 1 |
| `SNAPSHOT_FAILED` | `gh project item-list` failed or timed out | 1 |
| `STALE_CONFIG` | cached project_node_id stale or project deleted/archived | 1 |
| `TOTAL_SYNC_FAILED` | batch ran but zero items synced | 1 |
| `AUDIT_WRITE_FAILED` | step-5 write to `project-sync.json` failed for I/O reason | 1 |
| `AUDIT_SCHEMA_FAILED` | step-5 schema validation rejected the artifact (skill bug) | 1 |
| `INIT_FAILED` | `--init` couldn't complete (create-new, option resolution, or config write) | 1 |
| `USER_CANCELLED` | `--init` user pressed Ctrl-C or returned empty selection | 2 |
| `RETRY_SOURCE_MISSING` | `--retry-blocked-edits`: no prior `project-sync.json` for the resolved slug or `--from` path | 1 |
| `RETRY_SOURCE_MALFORMED` | `--retry-blocked-edits`: prior artifact failed schema validation or carries an unsupported `schema_version` | 1 |
| `LIFECYCLE_LOOKUP_FAILED` | `sync-lifecycle`: GraphQL PR-lookup failed for every issue in the batch | 1 |
| `WEBHOOK_PAYLOAD_INVALID` | Webhook payload file is not valid JSON, or is missing required top-level fields (`action`, one of `issue`/`pull_request`) | 1 |
| `WEBHOOK_NOT_ACTIONABLE` | Event type/action not in the lifecycle transition map, or no linked issue found in PR body | 0 (default) or 1 when `ITP_WEBHOOK_STRICT_LINK=1` |
| `RECONCILE_NEEDS_CONFIRM` | `--repair-aggressive` on non-TTY without `--yes-i-know` | 1 |
| `PAGED_SNAPSHOT_FAILED` | Any page ≥ 2 of multi-page board snapshot failed mid-loop | 1 |
| `UNKNOWN_REPO` | Board item from a repo not in `known_repos` encountered during `all-known-repos` reconcile AND `ITP_UNKNOWN_REPO_BEHAVIOR=error` | 1 |
| `CROSS_REPO_VERIFY_FAILED` | Pre-flight check 5 probe returned mismatched IDs or itself failed (network, auth) | 1 |
| `FIELD_TYPE_UNSUPPORTED` | Config references a field `type` v2.4 cannot write (e.g. `"text"`, `"multi-select"`) | 1 |
| `FIELD_NOT_FOUND` | Cached field id in `fields` config is absent from current live project | 1 |
| `AMBIGUOUS_REINIT` | Auto-re-init could not safely identify the same project (title mismatch, owner-type change, Status field/option structure drift, zero or multiple matches) | 1 |
| `STALE_CONFIG_PERSISTENT` | Auto-re-init succeeded but new IDs are also stale; loop guard fired — manual `--init` required | 1 |
| `GHES_TOO_OLD` | GHES installed version is below the required floor (3.10) | 1 |
| `RATE_LIMIT_EXCEEDED` | HTTP 429 or rate-limit signal from `gh project` call | 1 |
| `TLS_TRUST_FAILED` | TLS/SSL certificate verification failed (self-signed CA not trusted) | 1 |

## Idempotency contract

Re-running the same command produces the same final board state:

- After `add_failed` — normal-run retries the failed item naturally (it's not in the next snapshot).
- After `added_blocked_edit_failed` — normal-run does NOT retry the edit (the item IS in the snapshot, so step 4 skips it). Intentional per Hard guarantee 2 — we never overwrite a Status, including our own from a prior run.

**v2.4.0 extension — non-Status field idempotency:** the step-3 snapshot is extended to capture current values for all configured fields (not just Status). A field write is skipped (`skipped_already_set`) when `signals[field_key] == snapshot[url][field_key]`. This extends the v1 hard guarantee "never overwrite a Status that was changed by a human" to all configured fields: `already_on_board` items are fully skipped (no field writes). `--fields-only` mode bypasses the add-guard; field writes still respect `skipped_already_set`.

**Recovery procedure for `added_blocked_edit_failed`:** grep `project-sync.json` for `"needs_status_retry": true`, then pick one path:
- **Preferred — `--retry-blocked-edits`** (since v1.1.0): `issue-to-project --retry-blocked-edits <slug>` replays `item-edit` for every `needs_status_retry: true` row without touching the snapshot or re-adding the item. Writes a forwarded artifact at the current `schema_version` floor with a populated `retry_source` block. Safe to re-run. Recovers every `*_edit_failed` outcome — `added_blocked_edit_failed` from v1.0.0+, `added_in_progress_edit_failed` / `added_done_edit_failed` from v1.2.0+, and `added_ready_edit_failed` / `added_in_review_edit_failed` / `auto_promoted_ready_edit_failed` from v2.7.0+. The full set of outcomes accepted by `--retry-blocked-edits` is defined in `references/retry-process.md` (`RETRY_TARGET` map).
- **Manual UI** — open the GitHub Project, set Status=Blocked on each affected card.
- **CLI delete-and-re-add** — `gh project item-delete --id <project_item_id> --project-id <project_node_id>` (the skill never does this on its own), then re-run `issue-to-project`. The next normal-run sees the URL absent from the snapshot and re-attempts the `add` → `edit` pair. Useful only when `--retry-blocked-edits` itself has failed repeatedly for the same row.

**Retry-run idempotency:** running `--retry-blocked-edits` twice in a row is safe. After the first successful retry, the new artifact has `needs_status_retry: false` for that row; a second retry run finds zero rows to retry, writes another forwarded artifact, exits 0. After a `retry_failed`, the row retains `needs_status_retry: true` and a subsequent retry will attempt it again — one attempt per invocation, operator decides when to stop. `retry_item_gone` is terminal (no `needs_status_retry` re-set).

**`sync-lifecycle` idempotency (precedence rule — D5):** the precedence rule is the idempotency spine of `sync-lifecycle`. For each item, `sync-lifecycle` compares `current_board_status` (from the step-3 snapshot) against `last_written_status` (the `final_status` field in the existing `project-sync.json`). If they differ, the item was externally touched — record `outcome: "lifecycle_skipped_externally_set"`, no write. If equal, the skill still owns the value — compute `target_status` from the governing PR; write only when `target_status ≠ current_board_status`. Re-running `sync-lifecycle` is therefore safe: once an item reaches the target Status, a second run finds `target_status == current_board_status` and is a no-op for that item. Items a human pinned to any Status stay pinned permanently unless the operator manually restores the skill-expected value.

**Webhook-mode idempotency under double delivery (D8):** GitHub delivers webhooks at-least-once; the same event can fire twice. The `item-add` path is already idempotent via the step-3 board snapshot — if the issue is already on the board it is recorded as `already_on_board` and no add is attempted. For Status flips (`item-edit`) triggered by webhook events, the rule is: **if the item's `currentStatusName` (from the snapshot) already matches the transition target, no `item-edit` call is made** and the outcome is recorded as `already_on_board`. This means a second delivery of the same `pull_request.closed merged=true` event produces zero mutations and exits 0 with all items as `already_on_board`.

**`reconcile` idempotency:** read-only mode is trivially idempotent (no mutations). `--repair-additive` is idempotent (same contract as v1 normal-run — add-only, no Status overwrites). `--repair-aggressive` **explicitly overrides the v1 Hard Guarantee** that "we never overwrite a Status changed externally." In aggressive mode, labels are the source of truth: if `status:blocked` is in `labels[]`, the board Status is set to `Blocked` regardless of what a human previously set. Operators must confirm this override interactively or pass `--yes-i-know`. This override applies only to the drift cases repaired in this run; it does not change v1 normal-run behavior. Re-running reconcile after a partial repair: items repaired in a prior run will appear `clean` in the next snapshot. Items where repair failed will still appear as drift and can be retried.

## NEVER

- **NEVER use `GH_ENTERPRISE_TOKEN`.** Authentication is always via `gh auth login --hostname <host>`. The `GH_ENTERPRISE_TOKEN` env var bypasses the token store and is incompatible with the `project` OAuth scope flow.
- **NEVER pass `--insecure` or set `GH_TLS_SKIP_VERIFY`.** Self-signed CA? Install it in the system trust store. The skill does not weaken TLS.
- **NEVER log the configured `host` value in log lines that also contain issue content, project node IDs, or user data** — enterprise hostnames are internal infrastructure. The `[issue-to-project]` prefix lines may log `host` in isolation (e.g. pre-flight messages) but must not concatenate it with sensitive values.
- **NEVER remove an item from the board.** v1 only adds or status-edits.
- **NEVER overwrite a Status that was changed externally.** The re-run guard (step 3 snapshot) exempts already-on-board items from status writes entirely — even if `status:blocked` is still on the issue's labels. **Amendment for `ready_queue_mode: "autonomous"` (v2.7.0):** in autonomous mode, items whose current board Status is `Todo` (or absent — new-add) may be promoted to `Ready` by `auto_promote_to_ready()`. This is the **only** narrowing of the v1 re-run guard: items at `Ready`, `In progress`, `Blocked`, `In review`, or `Done` are still never overwritten by the skill. Manual mode is entirely unchanged.
- **NEVER call `gh project view` on every run to validate cached IDs** — that defeats the cache point. Trust the cache; the stale-`project_node_id` heuristic in step 4 handles drift. Exception: Pre-flight check 5 (verify-on-first-call) is explicitly designed to call `gh project view` once per normal-sync run as a board-ID freshness probe; it is a deliberate exception to this rule and is skippable via `ITP_SKIP_VERIFY=1`.
- **NEVER query labels from the GitHub issue directly.** `labels[]` on `created-issues.json` is the only signal for status routing. Decouples this skill from human relabeling between `to-issues` and `issue-to-project`.
- **NEVER overwrite an existing `project-sync.json` non-atomically.** Always write to `<path>.tmp` first, then `os.replace`. No half-written file is observable.
- **NEVER prompt the user in normal-run.** Only `--init` is interactive.
- **NEVER use `:warn` or `:info` log prefixes.** Bare `[issue-to-project]` with `WARN:` or `ERROR:` in the body is the convention. `[issue-to-project:auto]` is reserved for v2 inference.
- **NEVER skip schema validation of the audit artifact** — a malformed `project-sync.json` would silently break downstream consumers. Fail loud with HALT `AUDIT_SCHEMA_FAILED`.
- **NEVER snapshot the board during `--retry-blocked-edits`** — the prior artifact's `project_item_id` is the only board reference needed. A 404 from `item-edit` is the sufficient deletion signal (routed to `retry_item_gone`).
- **NEVER retry `add_failed` rows via `--retry-blocked-edits`** — those rows have no `project_item_id` cached. A normal re-run handles them naturally (the item is absent from the next snapshot).
- **NEVER write `schema_version: "1"` from this skill version** — v1.2 emits `"1.2"` for both normal-run and `--retry-blocked-edits`. The `"1"` and `"1.1"` enum values exist in the schema purely so the retry verb can ingest prior artifacts from older skill versions.
- **NEVER loop auto-re-init more than once per run.** If the new IDs resolved by auto-re-init are themselves stale, halt immediately with `STALE_CONFIG_PERSISTENT`. Retrying in a loop risks an infinite cycle on a corrupted board state; manual `--init` is always the correct next step.
- **NEVER use `[issue-to-project:auto]` as a log prefix outside autonomous-mode inference paths.** The `[issue-to-project:auto]` prefix is reserved exclusively for inference decisions made by the skill without an explicit user-set signal — in v2.7.0, that means `ready_queue_mode: "autonomous"` auto-promotion decisions only. Auto-re-init progress and PR-label stamping use the plain `[issue-to-project]` prefix (they are scripted/event-driven paths, not inference). Manual-mode runs emit zero `:auto` lines.
- **NEVER remove the `PR` repo label from an issue once stamped.** The label is a permanent historical record that a PR existed for the issue. `sync-lifecycle` and `--from-webhook` stamp it additively via `gh issue edit --add-label`; neither the skill nor any sub-path ever calls `--remove-label` for the PR label. Operators who want to remove it must do so manually.
