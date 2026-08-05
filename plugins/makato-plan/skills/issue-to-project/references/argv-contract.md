<!-- markdownlint-disable MD013 -->
# Argv & flag contract

Full flag and subcommand reference for `issue-to-project`. Pre-flight checks 1–6 from SKILL.md run first; this contract governs Step 0 arg-parse. Load this reference when validating unusual flag combinations, checking mutex exclusivity rules, or looking up the exact exit-1 message for a mutual-exclusion violation.

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
