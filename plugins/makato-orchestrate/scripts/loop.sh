#!/usr/bin/env bash
# loop.sh — autonomous polling driver for the PO-agent (GAP-007 / #33).
#
# Polls a GitHub Projects v2 board for items whose Status equals the
# configured "ready" option (default "Ready"). For each board item not
# already tracked (no in-flight `workflow-state.json` for the issue),
# dispatches the PO-agent serially.
#
# Single-threaded: at most one PO-agent runs at a time; the next item is
# not picked up until the current workflow-state's `current_phase` is
# `done` or the loop exits on a HALT.
#
# The queue source is the **board**, not labels. The repo's label set has
# no `status:ready` label (the `status:*` taxonomy is dormant per
# `to-issues` v3.2.0 — `issue-to-project` writes Status on the board
# instead). `loop` reads `.claude/config.json` → `github_project` to
# resolve the project owner/number/status-option, then polls
# `gh project item-list` and filters by the resolved Status text.
#
# Subcommands:
#   run [--status <NAME>] [--interval <S>] [--dry-run] [--once]
#       Long-running poll loop. Default Status: the option labelled
#       "Ready" in github_project.fields.status (or override via
#       MAKATO_LOOP_STATUS).
#
#   poll [STATUS_NAME]
#       Print the queue as JSON: a flat array of {issue, repository,
#       title, url, status, labels} for board items matching STATUS_NAME.
#
#   next [STATUS_NAME]
#       Print the issue_number of the first untracked open issue, or
#       empty string if the queue is empty or fully in-flight.
#
#   status
#       Pretty-print `.claude/state/loop-status.json` (or `{}` if missing).
#
#   dispatch <ISSUE_NUMBER> [--dry-run]
#       Dispatch one issue. Writes loop-status.json with active_workflow,
#       execs `$MAKATO_CLAUDE_BIN --dangerously-skip-permissions -p "<po-agent delegation prompt>"`
#       (or echoes the planned command under --dry-run), clears
#       active_workflow on return.
#
#   check-halt
#       Exit 0 if `~/.claude/HALT` (or `$MAKATO_HALT_FILE`) is absent,
#       exit 1 otherwise. Mirrors hooks/check-halt.sh's contract.
#
#   remove-worktrees
#       Remove local worktrees under .claude/worktrees/ whose branch has a
#       MERGED PR (#265). Skips the main checkout, dirty, locked, retained,
#       detached, and nested worktrees. Also run as a pre-poll pass inside
#       `run`. One-shot cleanup: MAKATO_LOOP_REAP_INTERVAL=0 loop.sh
#       remove-worktrees (add MAKATO_LOOP_REAP_DRYRUN=1 to inspect first).
#
# Environment variables:
#   MAKATO_LOOP_INTERVAL       Poll interval in seconds (default 300).
#   MAKATO_LOOP_STATUS         Default Status name override
#                              (CLI flag wins). Default: "Ready".
#   MAKATO_LOOP_DISPATCH_REPO  Target repo in owner/repo form. Required
#                              for all dispatch operations. Set by
#                              cmd_run from the board-poll item; must be
#                              set explicitly (or via --repo flag) when
#                              calling `dispatch` directly.
#   MAKATO_LOOP_CONFIG         Override path to .claude/config.json
#                              (tests only).
#   MAKATO_CLAUDE_BIN          Path to claude binary (default: `claude`).
#                              Tests stub this.
#   MAKATO_HALT_FILE           HALT-file path override
#                              (default ~/.claude/HALT).
#   MAKATO_LOOP_STATE_DIR      Override `.claude/state/` location
#                              (tests only).
#   MAKATO_LOOP_DRY_DISPATCH=1 Internal test hook: instead of execing
#                              claude, write `last_dispatch_issue` to
#                              loop-status.json and return 0. Used by
#                              smoke tests so they exercise the full
#                              code path without a real subprocess.
#   MAKATO_LOOP_GH_OVERRIDE    Tests only: path to a JSON file holding
#                              the pre-canned `gh project item-list`
#                              result. When set, `cmd_poll` reads this
#                              file instead of invoking `gh`. Keeps
#                              smoke tests fully offline.
#   MAKATO_LOOP_ISSUE_BODY_OVERRIDE
#                              Tests only: path to a file whose content is
#                              used as the issue body by
#                              `_derive_key_for_issue` instead of invoking
#                              `gh issue view`. Keeps the T25 KEY-derivation
#                              smoke test offline.
#   MAKATO_LOOP_STALL_WARN     Seconds of no PO-agent stdout/stderr
#                              before the liveness watchdog stamps
#                              `active_workflow.stalled = true` in
#                              loop-status.json (default 900 = 15 min).
#                              Warn-only; no signal to the child. See
#                              #164 for the design.
#   MAKATO_LOOP_STALL_KILL     Seconds of no output before the watchdog
#                              SIGTERMs the PO-agent (and SIGKILLs 30 s
#                              later if still alive). Stamps
#                              `killed_by_watchdog: true` on the
#                              preserved `last_watchdog_kill` snapshot
#                              (default 3600 = 60 min).
#   MAKATO_LOOP_STALL_DISABLE  Set to `1` to skip the watchdog entirely
#                              (debug-session escape hatch). No log
#                              capture, no background poller, no status
#                              stamps.
#   MAKATO_LOOP_STALL_POLL     Watchdog poll cadence in seconds
#                              (default 60). Tests set a small value to
#                              exercise WARN/KILL in seconds instead of
#                              minutes.
#   MAKATO_LOOP_PIDFILE        Override path to the run-mutex pidfile
#                              (default $STATE_DIR/loop.pid). See #172 —
#                              guards against a second loop.sh instance
#                              starting concurrently against the same
#                              state directory (e.g. plugin-cache copy
#                              vs. working-tree copy).
#   MAKATO_LOOP_FORCE_GRACE    Seconds between SIGTERM and SIGKILL when
#                              `run --force` reclaims a live instance
#                              (default 10).
#
# --- Merged-worktree reaper (#265) ---
#   MAKATO_LOOP_REAP_ON_POLL   Set to `0` to disable the reaper entirely
#                              (default 1). When on, `run` reaps merged
#                              worktrees before each poll.
#   MAKATO_LOOP_REAP_INTERVAL  Minimum seconds between reap passes
#                              (default 3600). The pass is invoked every
#                              tick but no-ops until the window elapses.
#                              Set 0 to run every call (one-shot cleanup /
#                              tests).
#   MAKATO_LOOP_REAP_DRYRUN    Set to `1` to log intended removals
#                              (`reap would remove …`) without running
#                              `git worktree remove`.
#   MAKATO_LOOP_REAP_REPO      Override owner/repo for `gh pr list`
#                              (default: MAKATO_LOOP_DISPATCH_REPO, else
#                              parsed from `git remote get-url origin`).
#   MAKATO_LOOP_REAP_GH_OVERRIDE
#                              Tests only: path to a JSON map
#                              {"<branch>": "<pr#>"} read instead of
#                              calling `gh pr list`. Keeps the reap smoke
#                              tests offline.
#   MAKATO_LOOP_REAP_WT_OVERRIDE
#                              Tests only: path to a file with canned
#                              `git worktree list --porcelain` output,
#                              read instead of invoking git.
#
# --- Stale-worktree reaper (#320) ---
#   MAKATO_LOOP_REAP_STALE_AGE Seconds a worktree must be on-disk
#                              (measured by directory mtime) before the
#                              stale-reaper considers it (default 86400 =
#                              24 h).  Worktrees younger than this are
#                              always skipped even when the owning pid is
#                              gone.  Set 0 to bypass the age guard
#                              (tests / emergency cleanup).
#   MAKATO_LOOP_REAP_STALE_FORCE
#                              Set to `1` to allow reaping a stale
#                              worktree that has unpushed commits.
#                              Default 0 — unpushed commits block reaping
#                              without this flag (un-landed work guard).
#
# --- Orphaned specs/ folder pruning ---
#   MAKATO_LOOP_REAP_SPECS     Set to `0` to disable orphaned-specs
#                              pruning (default 1). When on, local
#                              specs/<slug>/ folders for done/closed
#                              issues are removed in the same reap pass as
#                              merged worktrees. Only FULLY-UNTRACKED
#                              folders are ever removed — tracked specs
#                              (consumer repos) are managed by
#                              archive-spec.sh via `git mv` and never
#                              touched here.
#   MAKATO_LOOP_REAP_SPECS_GH_OVERRIDE
#                              Tests only: path to a JSON map
#                              {"<issue_number>": "open|closed"} read
#                              instead of calling `gh issue view`. Keeps
#                              the specs-prune smoke tests fully offline.
#
# --- Sleep-wake guard (#171) ---
#   MAKATO_LOOP_SLEEP_MAX_STEP Max seconds per raw `sleep` call inside
#                              `_guarded_sleep` (default 30). The outer
#                              cmd_run loop calls `_guarded_sleep
#                              "$interval"` instead of `sleep "$interval"`
#                              so a macOS suspend/resume that makes the
#                              raw sleep return early cannot bypass the
#                              full polling interval. Tests set a small
#                              value to exercise the re-entry path.
#   MAKATO_LOOP_MIN_DISPATCH_GAP
#                              Seconds since `active_workflow.started_at`
#                              during which a re-dispatch of the SAME
#                              issue is refused as a silent no-op
#                              (default 30). Predicate A of the
#                              idempotent-dispatch guard — see the
#                              `_within_dispatch_guard` docstring.
#   MAKATO_LOOP_LAST_DISPATCH_GAP
#                              Seconds since `.last_dispatch_at` during
#                              which a re-dispatch of the SAME issue is
#                              refused as a silent no-op (default 30).
#                              Predicate B of the guard. Distinct from
#                              MIN_DISPATCH_GAP because active_workflow
#                              is cleared once cmd_dispatch returns;
#                              this covers the "just cleared, don't
#                              immediately re-fire" case where the
#                              PO-agent's state write races with the
#                              next poll.
#   MAKATO_LOOP_SLEEP_CMD      Tests only: override the raw sleep
#                              command inside `_guarded_sleep`. Setting
#                              to `sleep 0.1` simulates the macOS
#                              early-return behaviour so smoke tests can
#                              verify the wall-clock guarantee in
#                              seconds instead of the full interval.
#
# --- Dispatch gate (#318/#355) ---
#   MAKATO_LOOP_GATE_DISABLE   Set to `1` to disable the dispatch gate
#                              entirely and restore pre-#318 behaviour
#                              (no checks, no stamp, no counter). Default 0.
#   MAKATO_LOOP_GATE_LABELS_OVERRIDE
#                              Tests only: path to a JSON file with
#                              `gh issue view --json labels,title` output
#                              read instead of calling `gh`. Keeps gate
#                              smoke tests offline.
#
# --- Thin-body reconciliation (#371, epic #367 S3) ---
#   MAKATO_LOOP_RECONCILE_JSONL_DIR
#                              Tests only: override SPECS_DIR root for
#                              locating specs/<key>/orchestrate.jsonl in
#                              _auto_seed_reconcile_thin_body. Keeps smoke
#                              tests offline.
#   MAKATO_LOOP_RECONCILE_LABEL_FILE
#                              Tests only: path to a newline-separated list
#                              of label names used as the issue's current
#                              labels instead of calling `gh issue view
#                              --json labels` in the label-backstop signal.
#
# --- Auto-seed pass toggle (#373, epic #367 S5) ---
#   MAKATO_LOOP_AUTOSEED_ON_POLL
#                              Set to `0` to disable the pre-poll auto-seed
#                              pass entirely (no candidate query, no seed or
#                              block action). Default on (unset or `1`).
#
# --- Reshape pass (#350, epic #319) ---
#   MAKATO_LOOP_RESHAPE_ENABLED
#                              Set to `1` to enable the pre-poll reshape pass.
#                              Default off (`0`). When enabled, _reshape_pass
#                              runs before auto-seed each poll tick.
#   MAKATO_MAX_RESHAPE_CYCLES  Maximum reshape attempts per issue before
#                              HALT-013 fires and needs-human-review is
#                              applied. Default 2.
#   MAKATO_LOOP_RESHAPE_TEST_CMD
#                              Tests only: command string eval'd in place of
#                              the real Claude dispatch for both decompose and
#                              to-issues steps. Must exit 0 for success path.
#   MAKATO_LOOP_RESHAPE_OVERRIDE
#                              Tests only: path to a JSON file holding
#                              [{"number":<N>,"key":"<KEY>"}] used as the
#                              Needs Planning candidate queue instead of the
#                              real board poll.
#
# --- Session-safety guard (#743) ---
#   MAKATO_LOOP_ALLOW_BG_SESSION
#                              Set to `1` to bypass the bg-session ancestry
#                              guard in cmd_run. For headless CI where external
#                              SIGTERM protection is provided by the caller.
#                              Default off (guard active).
#   MAKATO_LOOP_SESSION_SAFETY_TEST_PPID
#                              Tests only: starting ppid for the ancestry walk
#                              instead of $PPID (offline tests, no bg-spare).
#   MAKATO_LOOP_SESSION_SAFETY_PS_OVERRIDE
#                              Tests only: path to a file whose contents stand
#                              in for `ps -o args= -p <ppid>` on the first
#                              ancestry level, supplying fake ancestry output.
#
# Conventions: matches scripts/context-handoff.sh (POSIX-ish bash, `set
# -euo pipefail`, python3 for ISO-8601 millisecond timestamps, jq for
# JSON work).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# Allow tests to override SPECS_DIR (e.g. a temp dir) via the env; the
# script-level default applies only when the env variable is not already set.
SPECS_DIR="${SPECS_DIR:-$REPO_ROOT/specs}"
STATE_DIR="${MAKATO_LOOP_STATE_DIR:-$REPO_ROOT/.claude/state}"
STATUS_FILE="$STATE_DIR/loop-status.json"
HALT_FILE="${MAKATO_HALT_FILE:-$HOME/.claude/HALT}"
CLAUDE_BIN="${MAKATO_CLAUDE_BIN:-claude}"
CONFIG_FILE="${MAKATO_LOOP_CONFIG:-$REPO_ROOT/.claude/config.json}"
DEFAULT_INTERVAL="${MAKATO_LOOP_INTERVAL:-300}"
DEFAULT_STATUS="${MAKATO_LOOP_STATUS:-Ready}"
MAKATO_LOOP_ALLOW_TODO="${MAKATO_LOOP_ALLOW_TODO:-}"

# #516 — adaptive idle backoff bounds. When the queue is empty tick after tick,
# the effective poll interval grows by IDLE_BACKOFF_FACTOR up to
# IDLE_BACKOFF_MAX, then resets to the base interval the moment work appears.
# Defaults: double each idle tick (300->600->1200->1800), cap at 30 minutes.
# Set MAKATO_LOOP_IDLE_FACTOR=1 to disable backoff entirely (constant cadence).
IDLE_BACKOFF_MAX="${MAKATO_LOOP_IDLE_MAX:-1800}"
IDLE_BACKOFF_FACTOR="${MAKATO_LOOP_IDLE_FACTOR:-2}"
# Floor guards: a non-numeric or <1 factor would freeze or shrink the interval;
# a max below the base would clamp active polling. Fall back to safe defaults.
if [[ ! "$IDLE_BACKOFF_FACTOR" =~ ^[0-9]+$ ]] || (( IDLE_BACKOFF_FACTOR < 1 )); then
  IDLE_BACKOFF_FACTOR=2
fi
if [[ ! "$IDLE_BACKOFF_MAX" =~ ^[0-9]+$ ]] || (( IDLE_BACKOFF_MAX < DEFAULT_INTERVAL )); then
  IDLE_BACKOFF_MAX="$DEFAULT_INTERVAL"
fi

# Assign-on-dispatch (#33 board-lifecycle-sync). Just before spawning the
# PO-agent, the loop assigns the issue to an actor via `gh issue edit
# --add-assignee`. That fires the `issues.assigned` webhook, which the
# `project-board-sync.yml` GHA moves Ready → In progress on the board. The
# loop itself stays strictly read-only against the *board* (issue-to-project
# owns Status writes) — assigning an issue is a repo mutation, not a board
# mutation, and the assign is the trigger the board sync listens for.
#   - MAKATO_LOOP_ASSIGN_ON_DISPATCH=0 disables it entirely (default on).
#   - MAKATO_LOOP_ASSIGNEE overrides the assignee login (default "@me",
#     i.e. the authenticated `gh` user driving the loop).
# A failed assign is logged but never blocks dispatch — the board sync is
# best-effort telemetry, not a gate on getting work done.
ASSIGN_ON_DISPATCH="${MAKATO_LOOP_ASSIGN_ON_DISPATCH:-1}"
ASSIGNEE="${MAKATO_LOOP_ASSIGNEE:-@me}"

# --- Board-poll resilience (#289) ---
# The board poll (`gh project item-list`) is the loop's single point of contact
# with the GitHub API. A 429 (rate-limit) or transient 5xx returns non-zero;
# before #289 every caller degraded that to `echo '{"items":[]}'`, which the
# queue filter then read as an EMPTY QUEUE — so a rate-limited loop logged
# "queue empty" and idled while Ready work sat undispatched. `_gh_project_item_list`
# retries with exponential backoff and distinguishes "poll failed" from "queue
# empty" so a read failure can never silently masquerade as no-work-to-do.
#   MAKATO_LOOP_POLL_RETRIES       Total poll attempts before giving up
#                                  (default 3).
#   MAKATO_LOOP_POLL_BACKOFF_BASE  Base seconds for exponential backoff between
#                                  attempts (default 2 → waits 2s, 4s, …). Reuses
#                                  MAKATO_LOOP_SLEEP_CMD so tests stay offline.
#   MAKATO_LOOP_POLL_ERROR_BACKOFF Seconds cmd_run sleeps after a failed poll
#                                  before the next tick (default: --interval).
#   MAKATO_LOOP_POLL_TEST_CMD      Tests only: command string eval'd in place of
#                                  the real `gh` call, so smoke tests can simulate
#                                  N failures then a success without a network hit.
#
# --- Critical-call REST fallback (#447) ---
# Beyond the board poll, the other critical GitHub reads (KEY derivation's
# `issue view --json body`/`title`, the dispatch-gate `issue view --json
# labels,title`, and the issue-type routing `issue view --json labels`) went
# straight through `gh` with `|| true`. An auth glitch, a CLI bug, or an
# unparseable JSON body (a truncated write or an HTML error page) degraded
# silently: `jq` failed and the result was indistinguishable from an empty
# one, so the tick proceeded on bad data. `_gh_with_fallback` wraps those
# reads — it retries the primary `gh` call, falls back to the REST `gh api`
# equivalent, and treats jq-unparseable output as a failure (not an empty
# result), so a broken read can never masquerade as "no provenance" / "no
# labels". Non-critical best-effort calls (assign, label create, comment
# post, board item-add) keep their fail-open `|| true` behaviour.
#   MAKATO_LOOP_FALLBACK_RETRIES       REST fallback attempts after the primary
#                                      fails (default 2; floored at 1).
#   MAKATO_LOOP_FALLBACK_BACKOFF_BASE  Base seconds for exponential backoff
#                                      between fallback attempts (default 2 →
#                                      waits 2s, 4s, …). Reuses
#                                      MAKATO_LOOP_SLEEP_CMD so tests stay offline.
#   MAKATO_LOOP_FALLBACK_TEST_CMD      Tests only: command string eval'd in place
#                                      of BOTH the primary and REST calls,
#                                      receiving the attempt number via
#                                      MAKATO_LOOP_FALLBACK_ATTEMPT (0 = primary,
#                                      1..N = fallback attempts).

# --- GraphQL rate-limit guard (#556) ---
# The GraphQL board poll consumes rate-limit points per page. When the
# per-hour `resources.graphql.remaining` budget drops below the configured
# floor, the guard proactively sleeps until the reset epoch rather than
# burning the last tokens and forcing GitHub to reject the next request
# mid-poll with a hard 429. This prevents the board poll from degrading to
# the costlier `item-list` fallback path or emitting false `poll_healthy:false`
# states while the limit recovers.
#   MAKATO_LOOP_GRAPHQL_MIN_REMAINING  Remaining budget floor (default 500).
#                                      When `resources.graphql.remaining` drops
#                                      below this value, the guard sleeps until
#                                      `resources.graphql.reset` and skips the
#                                      poll tick, stamping
#                                      `poll_skipped_rate_budget:true` in state.
#   MAKATO_LOOP_RATE_GUARD             Set to 0 to disable the guard entirely
#                                      (default 1 = enabled).
#   MAKATO_LOOP_GRAPHQL_TEST_CMD       Tests only: command string eval'd in place
#                                      of `gh api rate_limit`, receiving canned
#                                      fixture JSON so smoke tests stay offline.
#   MAKATO_LOOP_BOARD_LIMIT            Item count ceiling for the `item-list`
#                                      fallback path (default 500). Replaces the
#                                      hard-coded `--limit 9999` in
#                                      `_gh_project_item_list` and
#                                      `_reconcile_orphaned_in_progress`.

# Synchronous board claim (#259 — cross-worktree double-dispatch). All three
# single-thread guarantees are worktree-local: the run-mutex pidfile is
# $STATE_DIR-scoped, the in-flight filter is specs/-scoped, and the only
# cross-session signal — the board Status — is moved Ready→In progress by the
# ASYNCHRONOUS assign→`project-board-sync.yml` webhook path. Between session
# A's assign and the webhook landing, session B (a second `loop run` in a
# different worktree on the same host) polls, still sees Ready, and dispatches
# a SECOND PO-agent against the same issue. That async gap IS the race window.
#
# The claim closes it by making the loop write the board itself, synchronously,
# immediately before spawn (compare-and-set):
#   1. Re-poll the target issue's board Status (close the TOCTOU window as far
#      as the API allows).
#   2. Only if it is still "Ready", `gh project item-edit` it to "In progress"
#      (the same mutation seed-issue / issue-to-project use; field + option IDs
#      cached in .claude/config.json).
#   3. If the re-poll shows Status != Ready, another session already claimed
#      the card — treat the issue as in-flight and SKIP it (cmd_dispatch
#      returns 0 without spawning).
# This makes the board the shared *lock*, not just the shared *queue*, and
# intentionally revises the prior "loop is strictly read-only against the
# board" invariant. Ownership split with issue-to-project sync-lifecycle is
# preserved: the loop now owns the Ready→In progress claim; sync-lifecycle
# still owns In review / Done. The claim is forward-only (it only ever writes
# FROM Ready, so it can never roll a card back from In review / Done) and
# best-effort (a `gh` outage or missing config logs a WARN and DISPATCHES
# anyway — degrading to the pre-#259 assign-only behaviour is strictly safer
# than blocking real work; the residual race is exactly today's).
#   - MAKATO_LOOP_CLAIM_ON_DISPATCH=0 disables the claim (default on). With it
#     off, the async assign→webhook path is the only board move and the
#     cross-worktree race re-opens — leave enabled in multi-worktree setups.
#   - MAKATO_LOOP_CLAIM_TEST_FILE (test-only) records the intended claim/skip
#     decision to a file instead of calling `gh`; the fixture Status is read
#     from MAKATO_LOOP_CLAIM_STATUS_OVERRIDE.
CLAIM_ON_DISPATCH="${MAKATO_LOOP_CLAIM_ON_DISPATCH:-1}"

# Dispatch gate (#318/#355) — read-only pre-dispatch guard that refuses to
# dispatch an issue whose PR has already merged or whose workflow-state is
# non-done (stale board). The gate is a total no-op when GATE_DISABLE=1.
#   - MAKATO_LOOP_GATE_DISABLE=1 fully restores pre-#318 dispatch (no checks,
#     no stamp, no counter). Default off.
#   - MAKATO_LOOP_GATE_LABELS_OVERRIDE (test-only): path to a JSON file with
#     `gh issue view --json labels,title` output used instead of a live gh call.
GATE_DISABLE="${MAKATO_LOOP_GATE_DISABLE:-0}"

# Watchdog defaults — see #164. Values are seconds of no-output on the
# combined stdout+stderr log before the watchdog escalates. Operators can
# override via env; tests use small values (STALL_POLL=1) to exercise
# state transitions in seconds.
STALL_WARN_SECS="${MAKATO_LOOP_STALL_WARN:-900}"
STALL_KILL_SECS="${MAKATO_LOOP_STALL_KILL:-3600}"
STALL_POLL_SECS="${MAKATO_LOOP_STALL_POLL:-60}"
# Grace period between SIGTERM and SIGKILL. Exposed for tests so the
# smoke suite doesn't have to wait 30 real seconds to observe the kill
# path close out.
STALL_TERM_GRACE_SECS="${MAKATO_LOOP_STALL_TERM_GRACE:-30}"
# Stall-recovery config (#444). Distinct from the watchdog WARN/KILL
# thresholds above — used by the classifier to trigger a bounded restart
# sequence before escalating to a full watchdog kill.
#   STALL_THRESHOLD_SECS — no-output window that triggers stall
#     classification (default 300 s, below the 900 s WARN threshold).
#   MAX_STALL_RESTARTS   — ceiling on restart attempts per dispatch;
#     when exceeded the watchdog takes over.
#   STALL_BACKOFF_BASE_SECS — base interval for exponential backoff
#     between restart attempts.
# All defaults leave existing behavior unchanged when the vars are unset.
STALL_THRESHOLD_SECS="${MAKATO_LOOP_STALL_THRESHOLD:-300}"
MAX_STALL_RESTARTS="${MAKATO_MAX_STALL_RESTARTS:-3}"
STALL_BACKOFF_BASE_SECS="${MAKATO_STALL_BACKOFF_BASE:-60}"

# --- Headless CLI resilience (follow-on: #531, #532) --------------------
# The loop's watchdog + stall-recovery (#164 / #444) only catch a PO-agent
# that HANGS with no output — the watchdog reaps it and _stall_restart
# re-dispatches. They do NOT catch a transient API error that terminates
# the `claude -p` subprocess cleanly. The most common such error,
# "API Error: Response stalled mid-stream. The response above may be
# incomplete." (after output has started streaming), is NOT retried by the
# CLI: the partial turn is kept and the process exits 0 — so a mid-build
# story silently ends half-done. The CLI's own retry/timeout machinery is
# the first line of defence, but it is OFF by default. Turning it on here
# lets transient errors self-heal INSIDE a single dispatch, before the
# process ever exits (which the loop cannot observe — cmd_run ignores the
# dispatch rc, loop.sh:4711). Detecting an already-exited-incomplete run
# and resuming it via `claude --resume` (#531), and an external supervisor
# for a dead loop.sh (#532), are the follow-ons; this block is the cheap,
# zero-risk first fix.
#
# All three are exported so every `claude -p` subprocess this script spawns
# inherits them: the two cmd_dispatch invocations (stream-json + text
# opt-out paths) plus the refine / decompose / to-issues dispatches. Each
# honours an existing operator-set value via `:-`, so nothing here
# overrides a deliberate environment override.
#
#   CLAUDE_CODE_RETRY_WATCHDOG=1
#     Unattended/CI resilience switch. Retries 429/529 indefinitely and
#     raises the transient-error retry budget to ~300 attempts (~3 h of
#     backoff), removing the default 15-attempt cap. This is the primary
#     defence against transient stream/API errors.
#   API_TIMEOUT_MS
#     Per-request timeout before a request is abandoned (CLI default
#     600000 = 10 min). Raised to 20 min headroom for slow tool turns /
#     proxied gateways; still bounded so a genuinely dead request fails
#     rather than hanging past the loop's own STALL_KILL watchdog.
#   API_FORCE_IDLE_TIMEOUT
#     The CLI's 5-min stream-idle watchdog. Left ON by default (empty);
#     operators behind a slow proxy/gateway can set 0 to disable it.
export CLAUDE_CODE_RETRY_WATCHDOG="${CLAUDE_CODE_RETRY_WATCHDOG:-1}"
export API_TIMEOUT_MS="${API_TIMEOUT_MS:-1200000}"
if [[ -n "${API_FORCE_IDLE_TIMEOUT:-}" ]]; then
  export API_FORCE_IDLE_TIMEOUT
fi

# Run-mutex pidfile — the layer-1 defence against #172 (a second
# loop.sh instance running unnoticed in parallel against the same
# state dir). Default lives alongside loop-status.json so the pidfile
# and the audit surface share a lifecycle; tests can point it
# elsewhere via MAKATO_LOOP_PIDFILE.
PIDFILE="${MAKATO_LOOP_PIDFILE:-$STATE_DIR/loop.pid}"
# Grace between SIGTERM and SIGKILL when `run --force` reclaims a
# live pidfile. Small enough that operators aren't left staring at
# the shell, large enough that the target's EXIT trap gets to clean up.
FORCE_GRACE_SECS="${MAKATO_LOOP_FORCE_GRACE:-10}"

# Merged- and stale-worktree reaper (#265, #320). Worktrees under
# .claude/worktrees/ pile up on the operator's local disk: the per-issue
# `worktree.sh cleanup` only fires for a fully-autonomous run that reaches merge
# inside its own session, but most worktrees are hand-created (EnterWorktree) or
# orphaned by a dead session and carry no workflow-state, so nothing ever removes
# them.  The reaper is a name-agnostic pre-poll sweep with two removal paths:
#
#   Path A (merged-branch) — branch has a MERGED PR or HEAD is already an
#     ancestor of the base ref.  Always safe; no owning-pid check needed.
#
#   Path B (stale-crash) — branch has NOT landed, but the owning loop.sh
#     process (recorded in <worktree>/.loop-owner.pid by worktree.sh) is dead
#     AND the worktree is older than REAP_STALE_AGE_SECS (default 24 h).
#     Catches hard-crashed runs that leave a worktree behind indefinitely.
#     Blocked by unpushed commits unless MAKATO_LOOP_REAP_STALE_FORCE=1.
#
# Both paths skip dirty, locked, retained, detached, nested, and main-checkout
# worktrees (guard stack in _reap_merged_worktrees).  Runs on the operator's
# machine because that is where the worktrees physically live.  Best-effort:
# any gh/git failure logs a WARN and never blocks the tick.
#   - MAKATO_LOOP_REAP_ON_POLL=0 disables the reaper entirely (default on).
#   - MAKATO_LOOP_REAP_INTERVAL throttles the pass to at most once per N seconds
#     (default 3600 = 1h); the function is called every tick but no-ops until
#     the window elapses. Set 0 to run every call (tests / one-shot cleanup).
REAP_ON_POLL="${MAKATO_LOOP_REAP_ON_POLL:-1}"
REAP_INTERVAL_SECS="${MAKATO_LOOP_REAP_INTERVAL:-3600}"
# Orphaned-In-progress reconciliation (#368).
RECONCILE_ON_POLL="${MAKATO_LOOP_RECONCILE_ON_POLL:-1}"
RECONCILE_DRYRUN="${MAKATO_LOOP_RECONCILE_DRYRUN:-0}"
# Orphaned-stale in-flight detection (#616) — a present, non-done
# workflow-state whose owning process is dead AND whose updated_at is older
# than ORPHAN_STALE_SECS is a dead orphan; route it to Blocked +
# needs-human-review (the file-present gap the #368 reconciler explicitly
# skips). Default 3600 s (60 min); opt-out via MAKATO_ORPHAN_DETECT_DISABLE=1.
ORPHAN_STALE_SECS="${MAKATO_ORPHAN_STALE_SECS:-3600}"
ORPHAN_DETECT_DISABLE="${MAKATO_ORPHAN_DETECT_DISABLE:-0}"
# Stale-worktree reap thresholds (#320).
REAP_STALE_AGE_SECS="${MAKATO_LOOP_REAP_STALE_AGE:-86400}"
REAP_STALE_FORCE="${MAKATO_LOOP_REAP_STALE_FORCE:-0}"
# Orphaned specs/ folder pruning — default on, opt-out via =0.
REAP_SPECS="${MAKATO_LOOP_REAP_SPECS:-1}"

# --- workflow-state prune pass (#597) ---
# Optional pass that removes done+stale workflow-state-*.json files after
# each reap pass. Off by default; opt-in via MAKATO_LOOP_PRUNE_ON_RUN=1.
# Never runs under --dry-run (REAP_ON_POLL guard already skips the sibling
# reap; the same convention applies here).
#   MAKATO_LOOP_PRUNE_ON_RUN=1   Enable the prune pass (default off).
#   MAKATO_LOOP_PRUNE_AGE_DAYS   Age threshold in days (default 30).
MAKATO_LOOP_PRUNE_ON_RUN="${MAKATO_LOOP_PRUNE_ON_RUN:-0}"
MAKATO_LOOP_PRUNE_AGE_DAYS="${MAKATO_LOOP_PRUNE_AGE_DAYS:-30}"

# --- Sleep-wake guard (#171) --------------------------------------------
# After a macOS host suspend/resume, `sleep $interval` in the outer
# `cmd_run` loop can return early — the parent shell then tight-loops
# through poll+dispatch and forks N zombie subprocesses against the same
# in-flight issue in one wall-clock second (issue #171 observed 35× in a
# single second). Two independent guards below defend the loop:
#
#   1. _guarded_sleep — wall-clock-guaranteed sleep. Re-enters raw
#      `sleep` in <= SLEEP_MAX_STEP chunks until `$(date +%s)` has
#      advanced far enough. Prevents Fix 2 from design.md.
#
#   2. Idempotent-dispatch guard in cmd_dispatch — refuses re-dispatch
#      of the same issue while it is still in flight (active_workflow
#      pointing at it, age < MIN_DISPATCH_GAP) OR was JUST dispatched
#      (last_dispatch_at within LAST_DISPATCH_GAP seconds). Prevents
#      Fix 1 from design.md.
#
# Both guards use *time since a stamped timestamp*, never a boolean,
# so a crashed dispatch (that never cleared active_workflow) reclaims
# after the guard window elapses — no permanent-refuse state.
SLEEP_MAX_STEP_SECS="${MAKATO_LOOP_SLEEP_MAX_STEP:-30}"
MIN_DISPATCH_GAP_SECS="${MAKATO_LOOP_MIN_DISPATCH_GAP:-30}"
LAST_DISPATCH_GAP_SECS="${MAKATO_LOOP_LAST_DISPATCH_GAP:-30}"
# Board-poll resilience (#289) — see the doc block near ASSIGNEE above.
POLL_RETRIES="${MAKATO_LOOP_POLL_RETRIES:-3}"
POLL_BACKOFF_BASE_SECS="${MAKATO_LOOP_POLL_BACKOFF_BASE:-2}"
# Guard against non-numeric / non-positive overrides that would make the
# retry loop misbehave (mirrors the SLEEP_MAX_STEP_SECS floor below).
if [[ ! "$POLL_RETRIES" =~ ^[0-9]+$ ]] || [[ "$POLL_RETRIES" -lt 1 ]]; then
  POLL_RETRIES=1
fi
if [[ ! "$POLL_BACKOFF_BASE_SECS" =~ ^[0-9]+$ ]]; then
  POLL_BACKOFF_BASE_SECS=2
fi
# GraphQL rate-limit guard (#556) — see the doc block near ASSIGNEE above.
GRAPHQL_MIN_REMAINING="${MAKATO_LOOP_GRAPHQL_MIN_REMAINING:-1000}"
RATE_GUARD="${MAKATO_LOOP_RATE_GUARD:-1}"
RATE_SKIP_THRESHOLD="${MAKATO_LOOP_RATE_SKIP_THRESHOLD:-3}"
RATE_SKIP_BACKOFF="${MAKATO_LOOP_RATE_SKIP_BACKOFF:-600}"
BOARD_LIMIT="${MAKATO_LOOP_BOARD_LIMIT:-500}"
# Critical-call REST fallback (#447) — see the doc block near ASSIGNEE above.
FALLBACK_RETRIES="${MAKATO_LOOP_FALLBACK_RETRIES:-2}"
FALLBACK_BACKOFF_BASE_SECS="${MAKATO_LOOP_FALLBACK_BACKOFF_BASE:-2}"
# Same floor guards as POLL_RETRIES: a non-numeric or < 1 retry count would
# skip the fallback loop entirely; a non-numeric backoff would break the
# arithmetic in _gh_with_fallback.
if [[ ! "$FALLBACK_RETRIES" =~ ^[0-9]+$ ]] || [[ "$FALLBACK_RETRIES" -lt 1 ]]; then
  FALLBACK_RETRIES=1
fi
if [[ ! "$FALLBACK_BACKOFF_BASE_SECS" =~ ^[0-9]+$ ]]; then
  FALLBACK_BACKOFF_BASE_SECS=2
fi
# Floor SLEEP_MAX_STEP_SECS at 1. Values ≤ 0 (whether accidentally
# unset-then-defaulted, or explicitly overridden by an operator) would
# make _guarded_sleep's inner cap `step=$SLEEP_MAX_STEP_SECS` deliver
# `sleep 0` (or `sleep -N`, which errors on GNU coreutils and is
# swallowed by `|| true`) every iteration — the outer while loop would
# then spin at 100% CPU for the full interval, defeating the sleep
# entirely. `-lt 1` also catches non-numeric values (bash arithmetic
# treats them as 0).
if [[ ! "$SLEEP_MAX_STEP_SECS" =~ ^[0-9]+$ ]] || [[ "$SLEEP_MAX_STEP_SECS" -lt 1 ]]; then
  SLEEP_MAX_STEP_SECS=1
fi

mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------------------
# ISO-8601 timestamp with milliseconds (UTC). Matches workflow-state.sh.
# ---------------------------------------------------------------------------
_now() {
  python3 -c "from datetime import datetime, timezone
n = datetime.now(timezone.utc)
print(n.strftime('%Y-%m-%dT%H:%M:%S.') + f'{n.microsecond // 1000:03d}Z')"
}

# ---------------------------------------------------------------------------
# _guarded_sleep <seconds> — wall-clock-guaranteed sleep against early wake.
#
# `sleep N` can return before N wall-clock seconds have elapsed after a
# macOS host suspend/resume (issue #171): the process is resumed with the
# alarm signal already fired or the kernel timer collapsed. Naive
# `sleep $interval` in the outer poll loop then re-enters immediately and
# the outer `cmd_run` bursts N dispatches in seconds.
#
# This wrapper is bounded above by SLEEP_MAX_STEP_SECS per raw `sleep`
# call and re-enters until `$(date +%s)` has advanced by the requested
# total. The inner `sleep` command can be overridden via
# MAKATO_LOOP_SLEEP_CMD (test hook) to simulate the early-return
# behaviour deterministically.
#
# Args: integer seconds to burn. cmd_run passes an integer $interval;
# non-integer input trips the bash arithmetic in the deadline calc,
# which is fine — this helper is not a general-purpose API. Zero and
# negative inputs fall through the first iteration of the while loop
# (`remaining <= 0`) and return immediately.
# ---------------------------------------------------------------------------
_guarded_sleep() {
  local target="${1:?_guarded_sleep: target seconds required}"
  local deadline
  deadline=$(( $(date +%s) + target ))
  # Cap each raw-sleep step at SLEEP_MAX_STEP_SECS so a wake event never
  # loses more than one step's worth of wall-clock time (raw sleep of
  # 300 s that returns instantly is still guarded, but polls are
  # bounded — safer than trusting a single long sleep).
  local sleep_cmd="${MAKATO_LOOP_SLEEP_CMD:-sleep}"
  while :; do
    local now_epoch remaining step
    now_epoch=$(date +%s)
    remaining=$(( deadline - now_epoch ))
    if [[ $remaining -le 0 ]]; then
      return 0
    fi
    step=$remaining
    if [[ $step -gt $SLEEP_MAX_STEP_SECS ]]; then
      step=$SLEEP_MAX_STEP_SECS
    fi
    # shellcheck disable=SC2086
    $sleep_cmd $step 2>/dev/null || true
  done
}

# ---------------------------------------------------------------------------
# Read .claude/config.json → github_project. Outputs a JSON object with the
# four fields the loop needs: {owner, number, host, status_field_name}.
# `status_field_name` is hardcoded to "Status" (the GitHub Projects v2
# default — sibling `issue-to-project` makes the same assumption).
#
# Exits with a clear error if the file is missing or malformed. Tests can
# substitute via MAKATO_LOOP_CONFIG.
# ---------------------------------------------------------------------------
_read_project_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "loop: .claude/config.json not found at $CONFIG_FILE — run \`issue-to-project --init\` first" >&2
    return 65
  fi
  local owner number host
  owner="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE")"
  number="$(jq -r '.github_project.number // empty' "$CONFIG_FILE")"
  host="$(jq -r '.github_project.host // "github.com"' "$CONFIG_FILE")"
  if [[ -z "$owner" || -z "$number" ]]; then
    echo "loop: github_project.owner / github_project.number missing in $CONFIG_FILE — run \`issue-to-project --init\`" >&2
    return 65
  fi
  jq -n --arg owner "$owner" --arg number "$number" --arg host "$host" \
    '{owner: $owner, number: ($number|tonumber), host: $host}'
}

# ---------------------------------------------------------------------------
# _gh_project_item_list <host> <number> <owner> (#289) — bounded-retry wrapper
# around the ONE `gh` API call the loop depends on. Prints the raw JSON board
# payload to stdout on success and returns 0. On failure of every attempt it
# prints NOTHING to stdout and returns non-zero — the caller MUST distinguish
# this from a successful poll that happened to yield an empty item set.
#
# Why this exists (#289): a 429 rate-limit or transient 5xx makes `gh` exit
# non-zero. The previous `gh … || echo '{"items":[]}'` idiom turned that into
# an empty-looking payload, which the queue filter read as "no work to do" —
# a rate-limited loop then logged "queue empty" and idled while Ready issues
# sat undispatched, with the audit showing a healthy idle loop. Retrying with
# exponential backoff rides out a transient blip; propagating the failure (not
# masking it as `{"items":[]}`) lets callers surface a distinct transient-error
# state instead of a false empty queue.
#
# Retry budget: POLL_RETRIES attempts (default 3), backoff POLL_BACKOFF_BASE_SECS
# * 2^(attempt-1) seconds between them (2s, 4s, …), using the same overridable
# sleep command as _guarded_sleep so smoke tests stay offline and fast. Test
# hook MAKATO_LOOP_POLL_TEST_CMD replaces the real `gh` invocation with an
# eval'd command string so failure/success sequences can be simulated.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# BOARD_QUERY — the GraphQL document _board_via_graphql pages through.
#
# Why raw GraphQL instead of `gh project item-list --limit 9999` (#516):
# `gh project item-list` charges roughly one GraphQL *point* per board item
# (measured: 203 points for a 197-item board), while a hand-written
# `items(first:100)` query costs a flat 1 point per 100-item page (measured:
# 2 points for the same board) — a ~100x reduction. The board poll is the
# loop's single hottest API call (every tick, every reconcile/reap/promote
# pass reads it), so this dominates the loop's hourly GraphQL budget.
#
# The query requests ONLY the fields downstream consumers read (see the
# _board_via_graphql jq remap for the full contract): item id, the Status
# single-select value (name + optionId), and content number/title/url/state/
# repository/labels for Issues and PullRequests. DraftIssues carry no number
# and are dropped by the remap (cmd_poll filters to Issue anyway).
# ---------------------------------------------------------------------------
BOARD_QUERY='query($pid:ID!,$cursor:String){
  rateLimit { cost remaining }
  node(id:$pid){ ... on ProjectV2 {
    items(first:100, after:$cursor){
      pageInfo{ hasNextPage endCursor }
      nodes{ id
        fieldValueByName(name:"Status"){ ... on ProjectV2ItemFieldSingleSelectValue{ name optionId } }
        content{ __typename
          ... on Issue{ number title url state repository{nameWithOwner} labels(first:20){nodes{name}} }
          ... on PullRequest{ number title url state repository{nameWithOwner} labels(first:20){nodes{name}} } } } } } } }'

# ---------------------------------------------------------------------------
# _board_via_graphql <host> <project_node_id> — page the board via raw GraphQL
# and emit `{"items":[...]}` in the SAME shape `gh project item-list --format
# json` produces, so every downstream jq filter is unchanged. Prints the
# assembled payload to stdout and returns 0 on success; returns non-zero (and
# prints nothing) on any page failure or unparseable response, so the
# _gh_project_item_list retry/backoff wrapper treats it exactly like a failed
# `gh` call — never as an empty queue (#289 contract).
#
# Field remap (GraphQL -> item-list shape):
#   .id                              -> .id
#   .fieldValueByName.name           -> .status
#   .fieldValueByName.optionId       -> .status_option_id
#   .content.__typename              -> .content.type   (Issue|PullRequest)
#   .content.number|title|url|state  -> .content.number|title|url|state
#   .content.repository.nameWithOwner-> .content.repository  (owner/name string)
#   [.content.labels.nodes[].name]   -> .labels
# ---------------------------------------------------------------------------
_board_via_graphql() {
  local host="$1" pid="$2"
  local cursor="" acc='[]' resp page has_next
  while :; do
    if [[ -n "${MAKATO_LOOP_GRAPHQL_TEST_CMD:-}" ]]; then
      # Offline test hook: the command string is eval'd in place of the real
      # `gh api graphql` call. It receives the current cursor via
      # MAKATO_LOOP_GRAPHQL_CURSOR ("" on the first page) and must echo a
      # GraphQL-shaped response so the remap + pagination logic can be
      # exercised without touching the network.
      resp="$(MAKATO_LOOP_GRAPHQL_CURSOR="$cursor" eval "$MAKATO_LOOP_GRAPHQL_TEST_CMD" 2>/dev/null)" || return 1
    elif [[ -n "$cursor" ]]; then
      resp="$(GH_HOST="$host" gh api graphql -F pid="$pid" -F cursor="$cursor" \
        -f query="$BOARD_QUERY" 2>/dev/null)" || return 1
    else
      resp="$(GH_HOST="$host" gh api graphql -F pid="$pid" \
        -f query="$BOARD_QUERY" 2>/dev/null)" || return 1
    fi
    # A truncated / HTML-error / partial response is NOT an empty page — bail
    # so the retry wrapper re-attempts rather than consuming garbage as data.
    _gh_json_valid "$resp" || return 1
    # #492-style label cap guard: labels(first:20) truncates issues with >20
    # labels. Log once per page if any node hit the cap; the loop only reads a
    # handful of status:* labels so truncation is benign, but silence is not.
    if jq -e '[.data.node.items.nodes[]?.content.labels.nodes // [] | length] | any(. >= 20)' \
        >/dev/null 2>&1 <<<"$resp"; then
      echo "loop: WARN — board poll: an item has >=20 labels; labels(first:20) may be truncated" >&2
    fi
    page="$(jq -c '[.data.node.items.nodes[]?
      | select(.content.__typename == "Issue" or .content.__typename == "PullRequest")
      | {
          id: .id,
          status: (.fieldValueByName.name // null),
          status_option_id: (.fieldValueByName.optionId // null),
          labels: [ (.content.labels.nodes // [])[].name ],
          content: {
            type: .content.__typename,
            number: .content.number,
            title: .content.title,
            url: .content.url,
            state: .content.state,
            repository: (.content.repository.nameWithOwner // null)
          }
        }]' <<<"$resp" 2>/dev/null)" || return 1
    acc="$(jq -c --argjson p "$page" '. + $p' <<<"$acc" 2>/dev/null)" || return 1
    has_next="$(jq -r '.data.node.items.pageInfo.hasNextPage' <<<"$resp" 2>/dev/null)"
    [[ "$has_next" == "true" ]] || break
    cursor="$(jq -r '.data.node.items.pageInfo.endCursor' <<<"$resp" 2>/dev/null)"
    [[ -n "$cursor" && "$cursor" != "null" ]] || break
  done
  jq -nc --argjson items "$acc" '{items: $items}'
}

# ---------------------------------------------------------------------------
# _project_item_id_for_issue <host> <owner> <repo> <issue> <project_node_id>
#
# Resolve the ProjectV2 item id for a single issue in ONE cheap GraphQL call
# (~1 point), instead of `gh project item-list --limit 9999` which charges
# ~1 point PER board item and, on a large board, exhausts the GraphQL budget
# just to find one id (incident 2026-08-06: parking 24 issues drained the
# budget mid-run). Queries the issue's own `projectItems` connection and
# filters to the item whose `project.id` matches the target board — an issue
# may sit on several boards, so the project_node_id filter is required.
#
# Prints the item id to stdout and returns 0 on success; prints nothing and
# returns non-zero when the issue is not on the board, the response is
# unparseable, or the call fails (caller falls back to item-add / item-list).
#
# Offline test hook: MAKATO_LOOP_ITEM_ID_TEST_CMD, when set, is eval'd in
# place of the real `gh api graphql` call and must echo a GraphQL-shaped
# response (same contract as MAKATO_LOOP_GRAPHQL_TEST_CMD).
# ---------------------------------------------------------------------------
_ITEM_ID_QUERY='query($owner:String!,$repo:String!,$num:Int!){
  repository(owner:$owner,name:$repo){
    issue(number:$num){
      projectItems(first:20){ nodes{ id project{ id } } }
    }
  }
}'

_project_item_id_for_issue() {
  local host="$1" owner="$2" repo="$3" issue="$4" pid="$5"
  [[ -n "$owner" && -n "$repo" && -n "$issue" && -n "$pid" ]] || return 1

  # Strip an "owner/name" repo into just the name for the GraphQL `name:` arg.
  local repo_name="${repo##*/}"

  local resp
  if [[ -n "${MAKATO_LOOP_ITEM_ID_TEST_CMD:-}" ]]; then
    resp="$(eval "$MAKATO_LOOP_ITEM_ID_TEST_CMD" 2>/dev/null)" || return 1
  else
    resp="$(GH_HOST="$host" gh api graphql \
      -F owner="$owner" -F repo="$repo_name" -F num="$issue" \
      -f query="$_ITEM_ID_QUERY" 2>/dev/null)" || return 1
  fi
  _gh_json_valid "$resp" || return 1

  local item_id
  item_id="$(jq -r --arg pid "$pid" \
    '.data.repository.issue.projectItems.nodes[]?
      | select(.project.id == $pid) | .id' <<<"$resp" 2>/dev/null | head -1)" || return 1
  [[ -n "$item_id" && "$item_id" != "null" ]] || return 1
  printf '%s\n' "$item_id"
}

# ---------------------------------------------------------------------------
# _check_graphql_rate_budget <host> (#556) — proactive GraphQL rate-limit guard.
#
# When RATE_GUARD=1 (default), queries `gh api rate_limit` and compares
# `resources.graphql.remaining` against GRAPHQL_MIN_REMAINING (default 500).
# If the budget is healthy, returns 0 (caller proceeds). If the budget is
# below the floor, logs an INFO line, sleeps until the reset epoch, then
# returns exit code 2 — the caller reads exit 2 as "skip this poll tick"
# and stamps `poll_skipped_rate_budget:true` in state rather than treating it
# as a poll failure.
#
# Degradation: if `gh api rate_limit` itself exits non-zero (auth issue,
# network blip), or if the JSON does not carry the expected fields, the
# function logs a warning and returns 0 (guard degrades gracefully — the
# poll is never blocked by a guard failure).
#
# RATE_GUARD=0 is a complete no-op: function returns 0 immediately.
# MAKATO_LOOP_GRAPHQL_TEST_CMD: tests-only fixture override; evaluated in
#   place of `gh api rate_limit` so smoke tests stay offline.
# ---------------------------------------------------------------------------
_check_graphql_rate_budget() {
  local host="${1:-}"
  [[ "${RATE_GUARD:-1}" == "1" ]] || return 0

  local sleep_cmd="${MAKATO_LOOP_SLEEP_CMD:-sleep}"
  local rate_json remaining reset_epoch rc

  rc=0
  if [[ -n "${MAKATO_LOOP_GRAPHQL_TEST_CMD:-}" ]]; then
    rate_json="$(eval "$MAKATO_LOOP_GRAPHQL_TEST_CMD" 2>/dev/null)" || rc=$?
  else
    rate_json="$(GH_HOST="${host}" gh api rate_limit 2>/dev/null)" || rc=$?
  fi

  if [[ $rc -ne 0 || -z "$rate_json" ]]; then
    echo "loop: WARN — _check_graphql_rate_budget: gh api rate_limit failed (rc=$rc); skipping guard (#556)" >&2
    return 0
  fi

  remaining="$(jq -r '.resources.graphql.remaining // empty' <<<"$rate_json" 2>/dev/null || true)"
  reset_epoch="$(jq -r '.resources.graphql.reset // empty' <<<"$rate_json" 2>/dev/null || true)"

  if [[ -z "$remaining" || ! "$remaining" =~ ^[0-9]+$ ]]; then
    echo "loop: WARN — _check_graphql_rate_budget: could not parse remaining from rate_limit response; skipping guard (#556)" >&2
    return 0
  fi

  if (( remaining >= GRAPHQL_MIN_REMAINING )); then
    return 0
  fi

  # Budget below floor — sleep until reset, then return 2 (caller skips tick).
  echo "loop: INFO — poll_skipped_rate_budget remaining=$remaining < $GRAPHQL_MIN_REMAINING; sleeping until reset (#556)" >&2
  if [[ -n "$reset_epoch" && "$reset_epoch" =~ ^[0-9]+$ ]]; then
    local now_epoch
    now_epoch="$(date +%s 2>/dev/null || echo 0)"
    local wait_secs=$(( reset_epoch - now_epoch ))
    (( wait_secs > 0 )) && $sleep_cmd "$wait_secs" 2>/dev/null || true
  fi
  return 2
}

_gh_project_item_list() {
  local host="$1" number="$2" owner="$3"
  local sleep_cmd="${MAKATO_LOOP_SLEEP_CMD:-sleep}"
  local attempt=1 out rc

  # Proactive GraphQL rate-limit guard (#556). Check before the first attempt —
  # if the budget is already below the floor, sleeping now is cheaper than
  # burning remaining tokens and triggering a hard 429 mid-poll.
  # Exit code 2 from the guard means "skip this tick"; propagate as 76
  # (distinct from 75 = transient-poll-failure) so cmd_poll and cmd_run can
  # stamp poll_skipped_rate_budget:true rather than poll_healthy:false.
  #
  # Guard is bypassed when MAKATO_LOOP_POLL_TEST_CMD is set: that hook
  # completely replaces the real `gh` poll (including GraphQL), so a
  # rate-limit check against the real API is irrelevant and would interfere
  # with offline smoke tests whose live budget may be zero (#556).
  if [[ "${RATE_GUARD:-1}" == "1" && -z "${MAKATO_LOOP_POLL_TEST_CMD:-}" ]]; then
    local _rg_rc=0
    _check_graphql_rate_budget "$host" || _rg_rc=$?
    if [[ $_rg_rc -eq 2 ]]; then
      return 76
    fi
  fi

  while (( attempt <= POLL_RETRIES )); do
    # Guard the command-substitution assignment with `|| rc=$?`: under
    # `set -e` a bare `out="$(failing-cmd)"` would abort the function on the
    # first non-zero exit, defeating the retry loop entirely. The `||` keeps
    # the failure local so we can inspect rc and back off.
    rc=0
    if [[ -n "${MAKATO_LOOP_POLL_TEST_CMD:-}" ]]; then
      out="$(MAKATO_LOOP_POLL_ATTEMPT="$attempt" eval "$MAKATO_LOOP_POLL_TEST_CMD" 2>/dev/null)" || rc=$?
    elif [[ "${MAKATO_LOOP_BOARD_MODE:-graphql}" == "item-list" ]]; then
      # Emergency rollback path — the pre-#516 `gh project item-list` call.
      # ~100x more expensive per poll; kept behind an env flag so an operator
      # can fall back instantly if the GraphQL path regresses.
      out="$(GH_HOST="$host" gh project item-list "$number" \
        --owner "$owner" --format json --limit "$BOARD_LIMIT" 2>/dev/null)" || rc=$?
    else
      # Default path (#516): raw GraphQL, ~1 point/page vs ~1 point/item.
      # Resolve the project node id from config; without it we cannot issue the
      # node(id:) query, so fall back to the item-list call for this attempt.
      local pid=""
      [[ -f "$CONFIG_FILE" ]] && pid="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE" 2>/dev/null)"
      if [[ -n "$pid" ]]; then
        out="$(_board_via_graphql "$host" "$pid")" || rc=$?
      else
        echo "loop: WARN — github_project.project_node_id missing in config; using costlier item-list path (#516)" >&2
        out="$(GH_HOST="$host" gh project item-list "$number" \
          --owner "$owner" --format json --limit "$BOARD_LIMIT" 2>/dev/null)" || rc=$?
      fi
    fi
    if [[ $rc -eq 0 ]]; then
      printf '%s' "$out"
      return 0
    fi
    if (( attempt < POLL_RETRIES )); then
      local wait=$(( POLL_BACKOFF_BASE_SECS * (1 << (attempt - 1)) ))
      echo "loop: WARN — board poll attempt $attempt/$POLL_RETRIES failed (gh exit $rc); retrying in ${wait}s (#289)" >&2
      $sleep_cmd "$wait" 2>/dev/null || true
    else
      echo "loop: ERROR — board poll failed after $POLL_RETRIES attempts (gh exit $rc); NOT treating as empty queue (#289)" >&2
    fi
    attempt=$(( attempt + 1 ))
  done
  return 1
}

# ---------------------------------------------------------------------------
# _gh_json_valid <json-string> (#447) — shared parseability predicate.
# Returns 0 when the input parses as JSON (`jq -e .` succeeds), 1 otherwise.
# _gh_with_fallback uses this to distinguish "got parseable JSON" from "got
# garbage that happens not to be empty" — a malformed `gh` response (truncated
# body, an HTML error page, a partial write) is NOT an empty result and must
# trigger the REST fallback rather than be consumed as valid data.
# Note: `jq -e .` on a JSON `null`/`false` returns non-zero by design; that is
# acceptable here because every wrapped critical call returns an object.
# ---------------------------------------------------------------------------
_gh_json_valid() {
  local json="$1"
  [[ -n "$json" ]] || return 1
  jq -e . >/dev/null 2>&1 <<<"$json"
}

# ---------------------------------------------------------------------------
# _gh_with_fallback <context> <primary gh args...> -- <rest gh args...> (#447)
# Bounded-retry wrapper with a `gh api` / REST fallback for the loop's CRITICAL
# read paths (KEY derivation, dispatch-gate label fetch, issue-type routing).
# Mirrors _gh_project_item_list's contract: prints the raw JSON payload to
# stdout and returns 0 on success; on exhaustion prints NOTHING to stdout and
# returns non-zero — callers MUST distinguish this from an empty-but-valid
# result.
#
# Why this exists (#447): every GitHub call outside the board poll went straight
# through `gh` with `|| true`, silently degrading on an auth glitch, a CLI bug,
# or an unparseable JSON body. A malformed response made `jq` fail and was
# indistinguishable from an empty result, so a broken KEY derivation or gate
# read looked like "no provenance" / "no labels" and the tick proceeded on bad
# data. This wrapper retries the primary `gh` path, then falls back to the REST
# API, and treats jq-unparseable output as a failure (not an empty result).
#
# Argument split: everything before the literal `--` is the PRIMARY invocation
# (`gh <primary…>`); everything after is the REST fallback (`gh <rest…>`, i.e.
# `gh api …`). Callers pass the raw-JSON form of BOTH (no `--jq` filter) so
# _gh_json_valid is meaningful and both paths return the same shape; the caller
# applies its own `jq` extraction to the stdout payload. The `--` and REST
# tail are optional — with no REST tail the fallback re-tries the primary args
# (a bounded retry with no REST escalation).
#
# Retry budget: FALLBACK_RETRIES fallback attempts (default 2) after the primary
# fails, backoff FALLBACK_BACKOFF_BASE_SECS * 2^(attempt-1) seconds between them,
# using the same overridable MAKATO_LOOP_SLEEP_CMD as _gh_project_item_list so
# smoke tests stay offline and fast.
#
# Test hook: MAKATO_LOOP_FALLBACK_TEST_CMD — when set, its value is eval'd in
# place of BOTH the primary `gh` call and the REST `gh api` call, receiving the
# current attempt number via MAKATO_LOOP_FALLBACK_ATTEMPT (0 = primary, 1..N =
# fallback attempts). Lets the smoke suite simulate failure/success sequences
# without a network hit.
# ---------------------------------------------------------------------------
_gh_with_fallback() {
  local context="$1"; shift
  local sleep_cmd="${MAKATO_LOOP_SLEEP_CMD:-sleep}"
  local test_cmd="${MAKATO_LOOP_FALLBACK_TEST_CMD:-}"

  # Split argv on the literal `--` into primary and REST arg vectors.
  local -a primary_args=() rest_args=()
  local seen_sep=0
  local a
  for a in "$@"; do
    if [[ "$seen_sep" -eq 0 && "$a" == "--" ]]; then
      seen_sep=1
      continue
    fi
    if [[ "$seen_sep" -eq 0 ]]; then
      primary_args+=("$a")
    else
      rest_args+=("$a")
    fi
  done
  # No REST tail supplied → fall back to re-trying the primary args.
  if [[ "${#rest_args[@]}" -eq 0 ]]; then
    rest_args=("${primary_args[@]}")
  fi

  local out rc

  # --- Primary attempt: `gh <primary_args>`. -----------------------------
  rc=0
  if [[ -n "$test_cmd" ]]; then
    out="$(MAKATO_LOOP_FALLBACK_ATTEMPT=0 eval "$test_cmd" 2>/dev/null)" || rc=$?
  else
    out="$(gh "${primary_args[@]}" 2>/dev/null)" || rc=$?
  fi
  if [[ $rc -eq 0 ]] && _gh_json_valid "$out"; then
    printf '%s' "$out"
    return 0
  fi

  # Primary failed (non-zero exit) OR returned unparseable JSON. Both are
  # equally "do not trust this payload" — fall back to REST.
  local reason
  if [[ $rc -ne 0 ]]; then
    reason="gh exit $rc"
  else
    reason="unparseable JSON"
  fi
  echo "loop: WARN — ${context} primary gh failed (${reason}); using REST fallback (#447)" >&2

  local attempt=1
  while (( attempt <= FALLBACK_RETRIES )); do
    rc=0
    if [[ -n "$test_cmd" ]]; then
      out="$(MAKATO_LOOP_FALLBACK_ATTEMPT="$attempt" eval "$test_cmd" 2>/dev/null)" || rc=$?
    else
      out="$(gh "${rest_args[@]}" 2>/dev/null)" || rc=$?
    fi
    if [[ $rc -eq 0 ]] && _gh_json_valid "$out"; then
      printf '%s' "$out"
      return 0
    fi
    if (( attempt < FALLBACK_RETRIES )); then
      local wait=$(( FALLBACK_BACKOFF_BASE_SECS * (1 << (attempt - 1)) ))
      echo "loop: WARN — ${context} REST fallback attempt ${attempt}/${FALLBACK_RETRIES} failed; retrying in ${wait}s (#447)" >&2
      $sleep_cmd "$wait" 2>/dev/null || true
    else
      echo "loop: ERROR — ${context} failed after primary + ${FALLBACK_RETRIES} REST fallback attempts; NOT masking as empty result (#447)" >&2
    fi
    attempt=$(( attempt + 1 ))
  done
  return 1
}

# ---------------------------------------------------------------------------
# Read the loop-status file, or echo `{}` if missing.
# ---------------------------------------------------------------------------
_read_status() {
  if [[ -f "$STATUS_FILE" ]]; then
    cat "$STATUS_FILE"
  else
    echo '{}'
  fi
}

# ---------------------------------------------------------------------------
# Atomic write to STATUS_FILE. Stamps updated_at automatically.
# Uses a same-directory mktemp so mv is a same-filesystem rename(2) — each
# write is all-or-nothing with no torn-read window. Matches the
# _atomic_write pattern in shared/workflow-state.sh.
# Args: JSON object string
# ---------------------------------------------------------------------------
_write_status() {
  local payload="$1"
  local now
  now="$(_now)"
  local stamped
  stamped="$(jq --arg ts "$now" '. + {updated_at: $ts}' <<<"$payload")"
  local tmp
  tmp="$(mktemp "${STATUS_FILE}.XXXXXX")"
  printf '%s\n' "$stamped" >"$tmp"
  mv "$tmp" "$STATUS_FILE"
}

# ---------------------------------------------------------------------------
# Patch a single jq path in the status file. Args: <path> <value-json>
# Initialises the file with an empty object if missing.
# ---------------------------------------------------------------------------
_patch_status() {
  local path="$1"
  local value="$2"
  local current
  current="$(_read_status)"
  local merged
  merged="$(jq "$path = $value" <<<"$current")"
  _write_status "$merged"
}

# ---------------------------------------------------------------------------
# _increment_poll_skip_count / _reset_poll_skip_count — track consecutive
# rate-budget skip ticks for the circuit-breaker (#683).
# ---------------------------------------------------------------------------
_increment_poll_skip_count() {
  local cur
  cur="$(_read_status | jq -r '.poll_skip_count // 0')"
  _patch_status '.poll_skip_count' "$((cur + 1))"
}
_reset_poll_skip_count() {
  _patch_status '.poll_skip_count' '0'
}

# ---------------------------------------------------------------------------
# _increment_gate_skips — read-increment-write gate_skips_total in the status
# file. Initialises to 0 if absent. Called by every dispatch-gate skip path
# (exclusion-label veto, merged-PR, in-flight). NOT called on read failures
# (proceed path) or GATE_DISABLE=1.
# ---------------------------------------------------------------------------
_increment_gate_skips() {
  local cur
  cur="$(_read_status | jq -r '.gate_skips_total // 0')"
  _patch_status '.gate_skips_total' "$((cur + 1))"
}

# ---------------------------------------------------------------------------
# _increment_orphan_dispatches — read-increment-write orphan_dispatches in the
# status file. Initialises to 0 if absent. Called once per orphan dispatch that
# proceeds (after tiers 1+2 pass). Session-scoped — reset to 0 at cmd_run start.
# ---------------------------------------------------------------------------
_increment_orphan_dispatches() {
  local cur
  cur="$(_read_status | jq -r '.orphan_dispatches // 0')"
  _patch_status '.orphan_dispatches' "$((cur + 1))"
}

# ---------------------------------------------------------------------------
# _is_orphan_issue <issue_number> — return 0 (orphan) when no created-issues.json
# in any specs/ folder references this issue number. Returns 1 (not orphan) when
# a valid created-issues.json contains a matching issue_number entry.
#
# A missing, zero-byte, or malformed created-issues.json counts as orphan (D11).
# The scan uses SPECS_DIR (default: $REPO_ROOT/specs) so tests can inject a
# fixture directory via env.
#
# Exit 0 = orphan (no authoritative record found)
# Exit 1 = not orphan (created-issues.json with matching entry found)
# ---------------------------------------------------------------------------
_is_orphan_issue() {
  local issue="$1"
  local spec_root="${SPECS_DIR:-${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}/specs}"
  [[ -d "$spec_root" ]] || return 0  # no specs dir → orphan

  local f
  while IFS= read -r -d '' f; do
    # Skip zero-byte files (D11)
    [[ -s "$f" ]] || continue
    # Attempt jq parse; skip malformed files (D11)
    local matched
    matched="$(jq -r --argjson n "$issue" \
      '[.issues[]? | select(.issue_number == $n)] | length' \
      "$f" 2>/dev/null || echo "0")"
    if [[ "$matched" -gt 0 ]]; then
      return 1  # found — not an orphan
    fi
  done < <(find "$spec_root" -maxdepth 2 -name "created-issues.json" -print0 2>/dev/null)

  return 0  # no referencing file found → orphan
}

# ---------------------------------------------------------------------------
# _label_board_conflict <labels_json> <board_status> — tier 3/4 gate (#356).
# Returns 0 (conflict detected) when a status:* label in the candidate's label
# list contradicts the observed board Status. Returns 1 (no conflict / aligned).
#
# Conflict conditions (AC-5: status:ready-for-dev exemption removed):
#   - Board is Ready AND issue carries ANY status:* label (no exemptions).
#   - Board is NOT Ready AND issue carries any status:* label that contradicts it.
#   - `needs-human-review` present → vetoed by _PROMOTE_EXCLUSION_LABELS upstream.
#
# Aligned (no conflict):
#   - No status:* label at all (board is authoritative).
#
# Args:
#   $1 — JSON string: {"labels":[{"name":"..."},...], ...}
#   $2 — board Status string observed by the CAS re-poll (e.g. "Ready")
#
# Reads MAKATO_LOOP_DISPATCH_STATUS (default "Ready") as the reference status.
# ---------------------------------------------------------------------------
_label_board_conflict() {
  local labels_json="$1"
  local board_status="$2"
  local dispatch_status="${MAKATO_LOOP_DISPATCH_STATUS:-Ready}"

  # Extract status:* labels from the candidates JSON.
  local status_labels
  status_labels="$(jq -r '[.labels[].name | select(startswith("status:"))] | .[]' \
    <<<"$labels_json" 2>/dev/null || true)"

  # No status:* labels at all — board is authoritative; no conflict.
  [[ -z "$status_labels" ]] && return 1

  # Any status:* label present when the board says dispatch_status → conflict.
  # The former "status:ready-for-dev is aligned" exemption is removed (AC-5).
  if [[ "$board_status" == "$dispatch_status" ]]; then
    return 0  # conflict — any status:* label contradicts the board-only authority
  fi

  # Board is NOT at dispatch_status. Any status:* label present is a conflict.
  return 0
}

# ---------------------------------------------------------------------------
# _post_halt_comment <HALT_CODE> <ISSUE_NUMBER> <REPO> [--reason <text>]
#   [--what-to-fix <text>]
#
# Best-effort wrapper: delegate to shared/post-halt-comment.sh.
# A non-zero exit is swallowed and logged as a WARN — never a hard error.
# Honour MAKATO_POST_HALT_COMMENT_DISABLE to skip all comment posting.
# ---------------------------------------------------------------------------
_post_halt_comment() {
  local halt_code="${1:-}"
  local issue="${2:-}"
  local repo="${3:-}"
  shift 3 2>/dev/null || true

  # Derive repo when the caller passed an empty arg. Every call site passes
  # "${MAKATO_LOOP_DISPATCH_REPO:-}", which is empty in a bare loop process
  # (only GH_HOST is exported). The helper HARD-fails on an empty REPO (exit 1)
  # while the paired `gh issue edit --add-label` derives its repo from the cwd
  # git remote — so the label landed but the comment silently no-op'd every
  # time. Reuse _derive_reap_repo (env override → git remote) to close that
  # asymmetry once for all ~15 call sites (#744 fixed only the script path).
  if [[ -z "$repo" ]]; then
    repo="$(_derive_reap_repo 2>/dev/null || true)"
  fi

  # Resolve the helper next to this script first (plugin cache / marketplace —
  # where it always ships), falling back to the consumer repo-mirror. The prior
  # $REPO_ROOT-only path silently no-op'd in consumer repos (e.g. sagibeast),
  # which vendor the other shared/ scripts as symlinks but not this one, so the
  # needs-human-review comment was never posted (#744).
  local phc_script
  phc_script="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/shared/post-halt-comment.sh"
  if [[ ! -x "$phc_script" ]]; then
    phc_script="$REPO_ROOT/plugins/makato-orchestrate/shared/post-halt-comment.sh"
  fi
  [[ -x "$phc_script" ]] || return 0

  bash "$phc_script" "$halt_code" "$issue" "$repo" "$@" 2>/dev/null || \
    echo "loop: WARN — post-halt-comment failed for #${issue} (${halt_code}); proceeding (best-effort)" >&2
}

# ---------------------------------------------------------------------------
# _reconcile_situation <spec_folder> <issue> <phase> <age_secs>
#
# Build a compact one-line **Situation** string for the HALT-015 comment
# posted by the two reconcilers. Surfaces the runtime facts that make an
# orphaned card actionable — the phase it died in, how long it has been
# stale, the last orchestrate.jsonl event, and the last meaningful line of
# the dispatch log (where the session actually died) — plus a pointer to the
# spec folder's audit trail. Every arg is optional: an empty/absent value is
# omitted, so the same helper serves both the stale reconciler (full context
# from workflow-state) and the in-progress reconciler (issue number only).
#
# Best-effort: any read failure yields a shorter string, never a hard error.
# ---------------------------------------------------------------------------
_reconcile_situation() {
  local spec_folder="${1:-}" issue="${2:-}" phase="${3:-}" age="${4:-}"
  local -a parts=()

  [[ -n "$phase" && "$phase" != "null" ]] && parts+=("phase \`${phase}\`")

  if [[ -n "$age" ]]; then
    # Humanise seconds → "~2h 15m" so the operator reads staleness at a glance.
    local _h=$(( age / 3600 )) _m=$(( (age % 3600) / 60 ))
    if (( _h > 0 )); then
      parts+=("stale ~${_h}h ${_m}m (${age}s)")
    else
      parts+=("stale ~${_m}m (${age}s)")
    fi
  fi

  # Last orchestrate.jsonl event (step/status) — the last thing the loop logged.
  if [[ -n "$spec_folder" && -f "$spec_folder/orchestrate.jsonl" ]]; then
    local _last_evt
    _last_evt="$(tail -n 1 "$spec_folder/orchestrate.jsonl" 2>/dev/null \
      | jq -r '"\(.step // "?")/\(.status // "?")"' 2>/dev/null || true)"
    [[ -n "$_last_evt" && "$_last_evt" != "?/?" ]] && parts+=("last event \`${_last_evt}\`")
  fi

  # Last meaningful line of the dispatch log (where the session died). Cap at
  # 200 chars so a giant stack trace cannot blow up the comment body.
  local _disp_log="$STATE_DIR/dispatch-${issue}.log"
  if [[ -n "$issue" && -f "$_disp_log" ]]; then
    local _last_log
    _last_log="$(grep -v '^[[:space:]]*$' "$_disp_log" 2>/dev/null | tail -n 1 | cut -c1-200 || true)"
    [[ -n "$_last_log" ]] && parts+=("dispatch died at: \`${_last_log}\`")
  fi

  # Pointer to the spec folder's audit trail.
  [[ -n "$spec_folder" ]] && parts+=("audit trail in \`specs/$(basename "$spec_folder")/\`")

  # Join with "; " (manual join — IFS-based join collapses the space). The
  # `${parts[@]+…}` guard keeps this safe under `set -u` on bash 3.2 (macOS),
  # where an empty-array expansion is otherwise an "unbound variable" error.
  local _out="" _p
  for _p in ${parts[@]+"${parts[@]}"}; do
    if [[ -z "$_out" ]]; then _out="$_p"; else _out="$_out; $_p"; fi
  done
  echo "$_out"
}

# ---------------------------------------------------------------------------
# _label_conflict_stamp <ISSUE_NUMBER> — best-effort idempotent label stamp.
# Applies the needs-human-review label on a label-board conflict skip (D11,
# #356). A non-zero gh exit logs a WARN and is swallowed — never a hard error.
# Test hook: MAKATO_LOOP_LABEL_TEST_FILE — append "label #N needs-human-review"
#   instead of calling gh (mirrors the existing stamp paths).
# ---------------------------------------------------------------------------
_label_conflict_stamp() {
  local issue="$1"
  local -a repo_flag=()
  [[ -n "${MAKATO_LOOP_DISPATCH_REPO:-}" ]] && repo_flag=(--repo "${MAKATO_LOOP_DISPATCH_REPO}")

  if [[ -n "${MAKATO_LOOP_LABEL_TEST_FILE:-}" ]]; then
    echo "label #${issue} needs-human-review" >>"$MAKATO_LOOP_LABEL_TEST_FILE"
    _post_halt_comment "HALT-006" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
    return 0
  fi

  # Ensure the label exists (idempotent create, best-effort).
  if ! gh label list "${repo_flag[@]}" 2>/dev/null | grep -q "^needs-human-review"; then
    gh label create "needs-human-review" "${repo_flag[@]}" \
      --color "E4E669" --description "Requires human review" >/dev/null 2>&1 || true
  fi

  if gh issue edit "$issue" "${repo_flag[@]}" --add-label "needs-human-review" >/dev/null 2>&1; then
    echo "loop: label-conflict — applied 'needs-human-review' to #$issue" >&2
  else
    echo "loop: WARN — label-conflict — could not stamp needs-human-review on #$issue; proceeding (best-effort, D11)" >&2
  fi
  _post_halt_comment "HALT-006" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
}

# ---------------------------------------------------------------------------
# check-halt — exit 0 if HALT_FILE absent, exit 1 if present.
# ---------------------------------------------------------------------------
cmd_check_halt() {
  if [[ -e "$HALT_FILE" ]]; then
    echo "loop: HALT file present at $HALT_FILE — exiting cleanly" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# poll [STATUS_NAME] — emit board items at the requested Status.
# STATUS_NAME may be a comma-separated list (e.g. "Ready,Todo") — items
# matching ANY listed status are included; ordering follows list position
# (items for the first listed status appear before items for the second, etc.).
#
# Output shape (JSON array, one entry per matching open Issue):
#   [{"issue": 33, "repository": "macatocz/makato",
#     "title": "...", "url": "...",
#     "status": "Ready", "labels": ["enhancement", ...]}]
#
# Closed issues, PRs, and DraftIssue items are filtered out.
# ---------------------------------------------------------------------------
cmd_poll() {
  local status_name="${1:-$DEFAULT_STATUS}"
  local raw
  if [[ -n "${MAKATO_LOOP_GH_OVERRIDE:-}" ]]; then
    raw="$(cat "$MAKATO_LOOP_GH_OVERRIDE")"
  else
    local cfg
    cfg="$(_read_project_config)" || return 65
    local owner number host
    owner="$(jq -r '.owner' <<<"$cfg")"
    number="$(jq -r '.number' <<<"$cfg")"
    host="$(jq -r '.host' <<<"$cfg")"
    # `gh project item-list` has no host flag — the `gh` CLI resolves the
    # host via `GH_HOST` (auth context) and `--owner`. A bare
    # `gh --hostname …` at this subcommand position fails with
    # `unknown flag: --hostname` and previously left the queue silently
    # empty (issue #156). Route host through the env var instead.
    # `--limit 9999` mirrors plugins/makato-plan/.../board-audit.md — same
    # ceiling, same WARN-on-truncation contract.
    #
    # #289: the poll now goes through _gh_project_item_list, which retries on
    # rate-limit / transient failure and returns non-zero on exhaustion. We
    # return 75 (EX_TEMPFAIL) for any transient failure so cmd_run can stamp
    # poll_healthy:false — a failed poll must NOT read as an empty queue.
    # #556: exit 76 from _gh_project_item_list means the rate-limit guard
    # triggered; propagate as 76 so cmd_run can distinguish "rate-budget skip"
    # from "transient poll error" and stamp poll_skipped_rate_budget:true.
    local _item_list_rc=0
    raw="$(_gh_project_item_list "$host" "$number" "$owner")" || _item_list_rc=$?
    if [[ $_item_list_rc -eq 76 ]]; then
      return 76
    elif [[ $_item_list_rc -ne 0 ]]; then
      return 75
    fi
  fi
  # Build a list of accepted status names from the comma-separated input.
  # For a single value ("Ready") this is a one-element list and the behaviour
  # is identical to before. For "Ready,Todo" the filter includes both, with
  # list-position ordering preserved by sorting on the index of the status.
  local -a status_list=()
  IFS=',' read -r -a status_list <<<"$status_name"

  # jq: collect all matching items preserving list-position order.
  # Build the accepted-statuses JSON array for the filter.
  local statuses_json
  statuses_json="$(printf '%s\n' "${status_list[@]}" | jq -R . | jq -sc .)"

  jq --argjson statuses "$statuses_json" \
    '[.items[]
      | select(.content.type == "Issue")
      | select(.status as $s | $statuses | index($s) != null)
      | {
          issue: .content.number,
          repository: .content.repository,
          title: .content.title,
          url: .content.url,
          status: .status,
          labels: (.labels // []),
          _sort_key: (.status as $s | $statuses | index($s))
        }]
    | sort_by(._sort_key)
    | map(del(._sort_key))' <<<"$raw"
}

# ---------------------------------------------------------------------------
# in_flight_issues — emit a set (one issue_number per line) of issues
# whose `workflow-state.json` exists and is NOT in `current_phase: "done"`.
# These must NOT be re-dispatched.
# ---------------------------------------------------------------------------
in_flight_issues() {
  [[ -d "$SPECS_DIR" ]] || return 0
  # One jq invocation per file but only one (not two): extract both fields
  # in a single pass and filter in jq rather than running two greps' worth
  # of forks per file. Per-file error handling preserved — malformed JSON
  # in one workflow-state.json must not crash the whole poll.
  # Glob widened to workflow-state-*.json (#173) so per-issue files under a
  # shared spec folder are all picked up. Legacy workflow-state.json files
  # are read by the -o clause below until their next write triggers migration.
  find "$SPECS_DIR" -maxdepth 2 \
    \( -name 'workflow-state-*.json' -o -name 'workflow-state.json' \) \
    -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
      jq -r 'select(.current_phase != "done") | (.issue_number // empty)' \
        "$f" 2>/dev/null || true
    done | sort -u
}

# ---------------------------------------------------------------------------
# _compute_vcr — Verified-to-Completed Rate for the loop-status.json .vcr
# field.
#
# "Verified" is defined SOLELY as current_phase == "done" in a
# workflow-state JSON file. This is intentionally decoupled from
# ac_verdicts / issue #568; the VCR is a dispatch-throughput metric, not
# an acceptance-test pass rate.
#
# Scans $SPECS_DIR for workflow-state-*.json and legacy workflow-state.json
# files — the same glob used by in_flight_issues above.
#
# Output: compact JSON {"activated":<n>,"verified":<n>,"rate":<f>}
# When $SPECS_DIR does not exist, returns {"activated":0,"verified":0,"rate":0.0}.
# ---------------------------------------------------------------------------
_compute_vcr() {
  if [[ ! -d "$SPECS_DIR" ]]; then
    echo '{"activated":0,"verified":0,"rate":0.0}'
    return 0
  fi
  local activated=0 verified=0
  while IFS= read -r -d '' f; do
    activated=$(( activated + 1 ))
    local phase
    phase="$(jq -r '.current_phase // empty' "$f" 2>/dev/null || true)"
    if [[ "$phase" == "done" ]]; then
      verified=$(( verified + 1 ))
    fi
  done < <(find "$SPECS_DIR" -maxdepth 2 \
    \( -name 'workflow-state-*.json' -o -name 'workflow-state.json' \) \
    -print0 2>/dev/null)
  local rate
  if [[ "$activated" -eq 0 ]]; then
    rate="0.0"
  else
    rate="$(python3 -c "print('%.2f' % ($verified / $activated))")"
  fi
  echo "{\"activated\":${activated},\"verified\":${verified},\"rate\":${rate}}"
}

# ---------------------------------------------------------------------------
# _dependency_order — emit a wave-ordered, newline-separated list of issue
# numbers for the loop's next-issue selection.
#
# Calls `promote-ready.sh plan --json` (the --json mode added by #548 T1)
# against the current workspace and extracts .ready[] entries ordered by
# .wave ascending (wave 0 first), preserving FIFO order within each wave.
# Emits nothing and exits 0 on any failure so the caller always falls back
# to the original FIFO head -1 selection.
#
# The function MUST NOT mutate the board. It is read-only (plan --json never
# contacts gh for board writes).
#
# MAKATO_PROMOTE_PATH overrides the resolved path to promote-ready.sh for
# testing (inject a stub or a different binary without PATH manipulation).
# ---------------------------------------------------------------------------
_dependency_order() {
  local pr_bin="${MAKATO_PROMOTE_PATH:-}"
  if [[ -z "$pr_bin" ]]; then
    # Locate promote-ready.sh relative to this script so it works regardless
    # of PATH (the scripts/ directory may not be on PATH in CI).
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    pr_bin="$script_dir/promote-ready.sh"
  fi

  if [[ ! -x "$pr_bin" ]]; then
    # promote-ready.sh absent or non-executable — degrade to FIFO silently.
    return 0
  fi

  local plan_json
  # Suppress stderr (warnings about missing graph files are expected in repos
  # with no specs directory); exit non-zero is treated as empty list.
  # Thread MAKATO_PROMOTE_SPECS_DIR = SPECS_DIR so promote-ready.sh reads the
  # same graph files as the loop (critical for test isolation where SPECS_DIR
  # is overridden via env). MAKATO_PROMOTE_SPECS_DIR already set → honour it;
  # unset → inherit the loop's SPECS_DIR.
  plan_json="$(MAKATO_PROMOTE_SPECS_DIR="${MAKATO_PROMOTE_SPECS_DIR:-$SPECS_DIR}" \
    "$pr_bin" plan --json 2>/dev/null)" || return 0

  # Validate JSON before jq; an empty string or non-JSON output exits 0 (FIFO).
  if ! jq empty <<<"$plan_json" 2>/dev/null; then
    return 0
  fi

  # Extract issues ordered by wave index (wave 0 = index 0, wave 1 = index 1,
  # …). .waves is an array of arrays; the outer array index IS the wave number.
  # FIFO order within each wave is preserved (jq preserves insertion order).
  # Issues in .ready[] are always wave-0 candidates already eligible for
  # promotion — they form the same set as .waves[0] when the graph is fresh.
  # However, issues already at Status=Ready on the board appear in .waves but
  # NOT in .ready[] (the forward-only filter skips them). We want all issues
  # the graph considers unblocked/wave-ordered regardless of current board
  # status, so we walk .waves directly.
  jq -r '
    .waves
    | to_entries
    | sort_by(.key)
    | .[].value[]
    | .issue
  ' <<<"$plan_json" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _check_pending_handoffs — HALT-007B liveness watchdog sweep (#284).
#
# The HALT-007B self-restart (scripts/context-handoff.sh) forks a detached
# `claude --resume` subprocess and exits the old session. If that subprocess
# dies after the fork, nothing detects it: the state is stranded with
# handoff_reason="context_ceiling" and no PR. This pre-poll pass walks every
# per-issue state file and, for any with a pending handoff (handoff_reason ==
# context_ceiling AND spawned_pid set), calls `context-handoff.sh check-pid`.
# check-pid clears the pid on a healthy resume (fresh resume_ack), keeps
# waiting while the subprocess is booting inside the ack timeout, or fires the
# HALT-007 fallback (restart_failed=true, needs-human-review applied) when the
# pid is dead or the ack never arrived.
#
# Best-effort: any error is swallowed so a single bad state file never blocks
# the tick. Mirrors in_flight_issues' scan (glob + per-file jq tolerance).
# ---------------------------------------------------------------------------
_check_pending_handoffs() {
  [[ -d "$SPECS_DIR" ]] || return 0
  local handoff_script="$REPO_ROOT/plugins/makato-orchestrate/scripts/context-handoff.sh"
  [[ -x "$handoff_script" ]] || return 0
  find "$SPECS_DIR" -maxdepth 2 \
    \( -name 'workflow-state-*.json' -o -name 'workflow-state.json' \) \
    -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
      local handoff_reason spawned_pid issue key
      handoff_reason="$(jq -r '.handoff_reason // "null"' "$f" 2>/dev/null || echo null)"
      spawned_pid="$(jq -r '.spawned_pid // "null"' "$f" 2>/dev/null || echo null)"
      [[ "$handoff_reason" == "context_ceiling" && "$spawned_pid" != "null" ]] || continue
      issue="$(jq -r '.issue_number // empty' "$f" 2>/dev/null || true)"
      [[ -n "$issue" ]] || continue
      # KEY is the spec-folder basename (workflow-state.sh resolves it to this
      # exact dir); e.g. specs/284-halt-007b-silent-fork/workflow-state-284.json.
      key="$(basename "$(dirname "$f")")"
      echo "loop: check-pid #$issue (HALT-007B handoff pending, spawned_pid=$spawned_pid)" >&2
      "$handoff_script" check-pid "$key" "$issue" 2>&1 | sed 's/^/loop:   /' >&2 || true
    done
}

# ---------------------------------------------------------------------------
# _reconcile_orphaned_in_progress — pre-poll pass (#368).
#
# Polls the board for all "In progress" cards. For each card that has NO live
# (non-done) workflow-state.json locally, the card is treated as orphaned —
# the session that claimed it died without cleanup. Orphaned cards are moved
# to Blocked and labelled needs-human-review so the operator can triage.
#
# Guards:
#   RECONCILE_ON_POLL == "0"  → skip entirely (toggle-off).
#   RECONCILE_DRYRUN == "1"   → log intended action, no mutation.
#   MAKATO_LOOP_RECONCILE_GH_OVERRIDE  → read "In progress" items from
#     this JSON fixture instead of calling gh (test hook).
#   MAKATO_LOOP_RECONCILE_TEST_FILE    → append "reconcile #N" instead of
#     calling gh project item-edit (test hook).
#   MAKATO_LOOP_RECONCILE_LABEL_TEST_FILE → append "label #N needs-human-review"
#     instead of calling gh issue edit (test hook).
#   MAKATO_LOOP_RECONCILE_SPECS_DIR → override SPECS_DIR for the in-flight scan
#     (test hook — avoids polluting the real specs/ tree with fixture files).
#
# Best-effort: any per-candidate gh failure logs a WARN and the pass
# returns 0; it never blocks the tick.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _reconcile_issue_closed — terminal-state guard shared by both reconcile
# passes (#616 follow-up).
#
# A reconcile pass fires on a workflow-state whose `current_phase != "done"`.
# But a PO-agent dispatch that merged its PR and closed the issue WITHOUT
# writing `current_phase: "done"` (e.g. killed by a Stream idle timeout right
# after the merge) leaves exactly that: a non-done state whose issue is
# already CLOSED. Without this guard the stale/in-progress reconcilers keep
# flipping such a card back to Blocked + needs-human-review on every tick —
# an issue that is Done and closed gets perpetually re-blocked. `reap-specs`
# already treats CLOSED as a terminal (prune) signal; this mirrors that so the
# reconcilers agree: a closed issue is finished work, never a dead orphan.
#
# Returns 0 (is closed → caller must skip) when the issue is CLOSED; returns 1
# (open or unknown) otherwise. On an unknown/unreachable state it returns 1
# (do NOT skip) — the staleness + dead-owner gates still apply, so a genuinely
# orphaned open issue is still recovered; we only ever ADD a skip, never mask a
# real orphan.
#
# Offline test hook: MAKATO_LOOP_RECONCILE_ISSUE_STATE_OVERRIDE points at a
# JSON object mapping "<issue>" → "OPEN"|"CLOSED" (same shape convention as
# MAKATO_LOOP_REAP_SPECS_GH_OVERRIDE), consulted instead of a live gh call.
#   $1 issue number   $2 repo (may be empty → derive)
# ---------------------------------------------------------------------------
_reconcile_issue_closed() {
  local issue="$1" repo="${2:-}"
  [[ -n "$issue" ]] || return 1

  local state=""
  if [[ -n "${MAKATO_LOOP_RECONCILE_ISSUE_STATE_OVERRIDE:-}" ]]; then
    state="$(jq -r --arg n "$issue" '.[$n] // empty' \
      "$MAKATO_LOOP_RECONCILE_ISSUE_STATE_OVERRIDE" 2>/dev/null \
      | tr '[:lower:]' '[:upper:]' || true)"
  else
    [[ -n "$repo" ]] || repo="$(_derive_reap_repo 2>/dev/null || true)"
    local -a repo_flag=()
    [[ -n "$repo" ]] && repo_flag=(--repo "$repo")
    state="$(gh issue view "$issue" "${repo_flag[@]}" --json state --jq '.state' 2>/dev/null \
      | tr '[:lower:]' '[:upper:]' || true)"
  fi

  [[ "$state" == "CLOSED" ]] && return 0
  return 1
}

# ---------------------------------------------------------------------------
# _reconcile_has_human_review_label — dedup guard for the stale reconciler.
#
# The stale reconciler (_reconcile_orphaned_stale) scans workflow-state files
# directly, NOT board status. It never deletes the state file (keeps the audit
# trail), so a dead orphan that has already been reconciled re-satisfies every
# gate (dead owner, stale age, non-done phase) on EVERY subsequent tick — and
# without this guard it re-posts an identical needs-human-review comment each
# time (the 6-8× duplicate-comment bug, #786). Once the label is present the
# operator has already been notified; skip the whole candidate.
#
# (The in-progress reconciler does NOT need this: it moves the card OUT of
# "In progress" to Blocked, so its status-based candidate filter stops
# matching on the next tick — it is self-limiting.)
#
# Returns 0 (label present → caller must skip) when needs-human-review is set;
# returns 1 (absent or unknown) otherwise. On an unreachable state it returns 1
# (do NOT skip) — we only ever ADD a skip, never mask a real orphan.
#
# Offline test hook: MAKATO_LOOP_RECONCILE_LABELS_OVERRIDE points at a JSON
# object mapping "<issue>" → ["label", …], consulted instead of a live gh call.
#   $1 issue number   $2 repo (may be empty → derive)
# ---------------------------------------------------------------------------
_reconcile_has_human_review_label() {
  local issue="$1" repo="${2:-}"
  [[ -n "$issue" ]] || return 1

  local labels=""
  if [[ -n "${MAKATO_LOOP_RECONCILE_LABELS_OVERRIDE:-}" ]]; then
    labels="$(jq -r --arg n "$issue" '(.[$n] // []) | .[]' \
      "$MAKATO_LOOP_RECONCILE_LABELS_OVERRIDE" 2>/dev/null || true)"
  else
    [[ -n "$repo" ]] || repo="$(_derive_reap_repo 2>/dev/null || true)"
    local -a repo_flag=()
    [[ -n "$repo" ]] && repo_flag=(--repo "$repo")
    labels="$(gh issue view "$issue" "${repo_flag[@]}" --json labels \
      --jq '.labels[].name' 2>/dev/null || true)"
  fi

  grep -qx "needs-human-review" <<<"$labels" && return 0
  return 1
}

_reconcile_orphaned_in_progress() {
  [[ "$RECONCILE_ON_POLL" != "0" ]] || return 0
  [[ -n "${MAKATO_LOOP_TEST_HOOK:-}" ]] || {
    local cfg
    cfg="$(_read_project_config 2>/dev/null)" || {
      echo "loop: reconcile-orphaned — no project config, skipping" >&2
      return 0
    }
  }

  # Fetch "In progress" items from the board (or a test fixture).
  local raw
  if [[ -n "${MAKATO_LOOP_RECONCILE_GH_OVERRIDE:-}" ]]; then
    raw="$(cat "$MAKATO_LOOP_RECONCILE_GH_OVERRIDE")" || {
      echo "loop: WARN — reconcile-orphaned: could not read fixture ${MAKATO_LOOP_RECONCILE_GH_OVERRIDE}" >&2
      return 0
    }
  else
    local cfg owner number host
    cfg="$(_read_project_config 2>/dev/null)" || return 0
    owner="$(jq -r '.owner' <<<"$cfg")"
    number="$(jq -r '.number' <<<"$cfg")"
    host="$(jq -r '.host' <<<"$cfg")"
    # #516: read the board via the cheap raw-GraphQL poll (~1-2 points/board)
    # instead of a raw `gh project item-list --limit BOARD_LIMIT` (~1 point per
    # item, ~200 for a large board). The old raw call was itself a top
    # contributor to draining the shared token's GraphQL budget every tick, and
    # once drained it failed with gh's masked "unknown owner type" (a
    # graphql_rate_limit hit during --owner resolution) — silently leaving
    # orphaned "In progress" cards unreconciled.
    #
    # We deliberately DO NOT route through _gh_project_item_list here: that
    # wrapper's #556 rate-limit guard sleeps until the reset epoch on a low
    # budget, which is correct for the main poll (the loop must wait for budget)
    # but wrong for this pre-poll best-effort pass — a reconcile tick must never
    # block. On a drained budget _board_via_graphql simply fails fast and we
    # skip, exactly like the old raw call did.
    local _recon_rc=0 pid=""
    [[ -f "$CONFIG_FILE" ]] && pid="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE" 2>/dev/null)"
    if [[ -n "$pid" ]]; then
      raw="$(_board_via_graphql "$host" "$pid")" || _recon_rc=$?
    else
      # No node id cached — fall back to the (costlier) item-list call so the
      # pass still works, but never through the sleeping guard.
      raw="$(GH_HOST="$host" gh project item-list "$number" \
        --owner "$owner" --format json --limit "$BOARD_LIMIT" 2>/dev/null)" || _recon_rc=$?
    fi
    if [[ "$_recon_rc" -ne 0 ]]; then
      echo "loop: WARN — reconcile-orphaned: board poll failed (rc=$_recon_rc), skipping" >&2
      return 0
    fi
  fi

  # Filter to Issue items at "In progress".
  local candidates
  candidates="$(jq -r \
    '[.items[]
      | select(.content.type == "Issue")
      | select(.status == "In progress")
      | .content.number] | .[]' \
    <<<"$raw" 2>/dev/null)" || {
    echo "loop: WARN — reconcile-orphaned: jq parse failed" >&2
    return 0
  }

  [[ -n "$candidates" ]] || return 0

  # Build the current in-flight set once (to avoid repeated scans).
  # MAKATO_LOOP_RECONCILE_SPECS_DIR overrides SPECS_DIR for the in-flight scan
  # in tests so the fixture workflow-state files are found without polluting
  # the real specs/ tree.
  local reconcile_specs_dir="${MAKATO_LOOP_RECONCILE_SPECS_DIR:-$SPECS_DIR}"
  local in_flight
  in_flight="$(SPECS_DIR="$reconcile_specs_dir" in_flight_issues 2>/dev/null || true)"

  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue

    # Skip if a live (non-done) workflow-state exists for this issue.
    if echo "$in_flight" | grep -qx "$n"; then
      echo "loop: reconcile-orphaned — #$n has live workflow-state, skipping" >&2
      continue
    fi

    # Terminal-state guard (#616 follow-up): a CLOSED issue is finished work,
    # never a dead orphan. Skip so a Done+closed card is not re-Blocked forever.
    if _reconcile_issue_closed "$n" "${MAKATO_LOOP_DISPATCH_REPO:-}"; then
      echo "loop: reconcile-orphaned — #$n is CLOSED, skipping (terminal state, not an orphan)" >&2
      continue
    fi

    if [[ "${RECONCILE_DRYRUN:-0}" == "1" ]]; then
      echo "loop: reconcile-orphaned — would reconcile #$n → Blocked + needs-human-review (dry-run)" >&2
      continue
    fi

    echo "loop: reconcile-orphaned — #$n orphaned (In progress but no live workflow-state) → Blocked + needs-human-review" >&2

    # Move the board card to Blocked.
    # board_edit_ok=1 only when the edit actually lands; label stamp is gated on it
    # to prevent infinite oscillation where label keeps being reapplied every tick
    # while the board card stays "In progress" because item-edit silently failed.
    local board_edit_ok=0
    {
      if [[ -n "${MAKATO_LOOP_RECONCILE_TEST_FILE:-}" ]]; then
        echo "reconcile #${n}" >>"$MAKATO_LOOP_RECONCILE_TEST_FILE"
        board_edit_ok=1
      else
        local cfg item_id blocked_id proj_owner proj_number proj_host field_id proj_node_id
        cfg="$(_read_project_config 2>/dev/null)" || { echo "loop: WARN — reconcile-orphaned #$n: no config for board edit" >&2; true; }
        proj_owner="$(jq -r '.owner' <<<"$cfg")"
        proj_number="$(jq -r '.number' <<<"$cfg")"
        proj_host="$(jq -r '.host' <<<"$cfg")"
        # #492: read field/option ids from $CONFIG_FILE with the full
        # `.github_project.` prefix — the same shape the proven call sites at
        # ~1880 / ~2520 use. _read_project_config only emits {owner,number,host},
        # so reading these ids from $cfg always yielded empty and the board
        # write silently no-op'd on every invocation.
        field_id="$(jq -r '.github_project.fields.status.id // .github_project.status_field_id // empty' "$CONFIG_FILE")"
        blocked_id="$(jq -r '.github_project.fields.status.options.blocked // (.github_project.options.blocked // empty)' "$CONFIG_FILE")"
        proj_node_id="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE" 2>/dev/null)"
        if [[ -z "$field_id" || -z "$blocked_id" || -z "$proj_node_id" ]]; then
          echo "loop: WARN — reconcile-orphaned #$n: missing field_id, blocked option id, or project_node_id in config" >&2
        else
          # Resolve the project item-id from the board payload already fetched
          # above ($raw) instead of issuing a second `gh project item-list
          # --limit 9999` per candidate. That per-candidate call was the second
          # GraphQL-budget drain in this pass (one full board scan for every
          # orphan); $raw already carries every item's .id in the same shape.
          # `// empty` collapses a missing/null .id to no output (rather than
          # the literal string "null", which would pass the -n test below and
          # send `--id null` to gh).
          item_id="$(jq -r --argjson n "$n" \
            '.items[] | select(.content.type == "Issue" and .content.number == $n) | (.id // empty)' \
            <<<"$raw" 2>/dev/null | head -1)" || true
          if [[ -n "$item_id" ]]; then
            if GH_HOST="$proj_host" gh project item-edit \
              --id "$item_id" \
              --project-id "$proj_node_id" \
              --field-id "$field_id" \
              --single-select-option-id "$blocked_id" \
              >/dev/null 2>&1; then
              board_edit_ok=1
            else
              echo "loop: WARN — reconcile-orphaned #$n: gh project item-edit failed" >&2
            fi
          else
            echo "loop: WARN — reconcile-orphaned #$n: could not resolve board item-id" >&2
          fi
        fi
      fi
    } || true

    # Apply needs-human-review label only when board edit succeeded.
    # Stamping the label without moving the card causes infinite oscillation:
    # the card stays "In progress" on the next tick and gets reconciled again.
    [[ "$board_edit_ok" -eq 1 ]] || { echo "loop: WARN — reconcile-orphaned #$n: skipping label stamp (board edit did not succeed)" >&2; continue; }
    # HALT-015 (orphaned card, dead session) — this reconciler fires on an
    # In-progress card with NO live workflow-state, i.e. the session died
    # before/without persisting state. Only the dispatch log can locate where
    # it died, so the Situation carries the issue number alone (#786).
    local _ro_situation
    _ro_situation="$(_reconcile_situation "" "$n" "" "" 2>/dev/null || true)"
    {
      local repo_flag=()
      if [[ -n "${MAKATO_LOOP_DISPATCH_REPO:-}" ]]; then
        repo_flag=(--repo "$MAKATO_LOOP_DISPATCH_REPO")
      fi
      if [[ -n "${MAKATO_LOOP_RECONCILE_LABEL_TEST_FILE:-}" ]]; then
        echo "label #${n} needs-human-review" >>"$MAKATO_LOOP_RECONCILE_LABEL_TEST_FILE"
        _post_halt_comment "HALT-015" "$n" "${MAKATO_LOOP_DISPATCH_REPO:-}" \
          --situation "$_ro_situation" || true
      else
        if ! gh label list "${repo_flag[@]}" 2>/dev/null | grep -q "^needs-human-review"; then
          gh label create "needs-human-review" "${repo_flag[@]}" \
            --color "e4e669" --description "Needs human attention before autonomous dispatch" \
            >/dev/null 2>&1 || true
        fi
        if ! gh issue edit "$n" "${repo_flag[@]}" \
            --add-label "needs-human-review" >/dev/null 2>&1; then
          echo "loop: WARN — reconcile-orphaned #$n: could not apply needs-human-review label" >&2
        else
          echo "loop: reconcile-orphaned — applied 'needs-human-review' label to #$n" >&2
        fi
        _post_halt_comment "HALT-015" "$n" "${MAKATO_LOOP_DISPATCH_REPO:-}" \
          --situation "$_ro_situation" || true
      fi
    } || true
  done <<<"$candidates"

  return 0
}

# ---------------------------------------------------------------------------
# cmd_reconcile_orphaned — standalone subcommand: run one reconciliation pass
# and exit.
# ---------------------------------------------------------------------------
cmd_reconcile_orphaned() {
  _reconcile_orphaned_in_progress
}

# ---------------------------------------------------------------------------
# _reconcile_orphaned_stale — per-tick pass (#616).
#
# The #368 reconciler (_reconcile_orphaned_in_progress) recovers a card only
# when NO workflow-state file exists. It explicitly SKIPS a card whose
# workflow-state file is present with current_phase != "done", treating it as
# a live run. But a dispatch killed by `Stream idle timeout` (or any hard
# crash) leaves exactly that: a present, non-done workflow-state with no live
# process. Both the reconciler and the in-flight gate then block the issue
# forever with no automatic recovery. This pass closes that gap.
#
# For each workflow-state-<N>.json with current_phase != "done", an issue is a
# dead orphan when BOTH hold:
#   1. Its owning loop.sh process is dead — <worktree_path>/.loop-owner.pid
#      fails `kill -0` (reuses _reap_owner_pid_alive). A live owner ALWAYS
#      short-circuits to skip — this is the load-bearing guard against
#      false-firing on a legitimately long-running task.
#   2. Its updated_at is older than ORPHAN_STALE_SECS.
# Dead orphans are routed to Blocked + needs-human-review — the same
# operator-gated outcome the #368 reconciler uses. The workflow-state file is
# NOT deleted or reset (avoids a crash-loop on an unrecoverable task and keeps
# the audit trail for the operator).
#
# Guards:
#   ORPHAN_DETECT_DISABLE == "1" → skip entirely.
#   RECONCILE_DRYRUN == "1"      → log intended action, no mutation.
#   MAKATO_LOOP_RECONCILE_TEST_FILE       → board-edit test hook (shared).
#   MAKATO_LOOP_RECONCILE_LABEL_TEST_FILE → label test hook (shared).
#   MAKATO_LOOP_RECONCILE_SPECS_DIR       → override SPECS_DIR for the scan.
#
# Best-effort: any per-candidate failure logs a WARN and the pass returns 0.
# ---------------------------------------------------------------------------
_reconcile_orphaned_stale() {
  [[ "$ORPHAN_DETECT_DISABLE" != "1" ]] || return 0

  local scan_specs_dir="${MAKATO_LOOP_RECONCILE_SPECS_DIR:-$SPECS_DIR}"
  [[ -d "$scan_specs_dir" ]] || return 0

  local now_epoch
  now_epoch="$(_reap_epoch_of_iso "$(_now)" 2>/dev/null || echo "")"

  local f
  while IFS= read -r -d '' f; do
    [[ -f "$f" ]] || continue

    # Read phase, issue number, worktree_path, updated_at in one pass.
    local phase issue_n wt updated_at
    phase="$(jq -r '.current_phase // "null"' "$f" 2>/dev/null || echo "null")"
    [[ "$phase" != "done" && "$phase" != "null" ]] || continue
    issue_n="$(jq -r '.issue_number // empty' "$f" 2>/dev/null || true)"
    [[ -n "$issue_n" ]] || continue
    local _rs_repo=""
    _rs_repo="$(jq -r '.repo // empty' "$f" 2>/dev/null || true)"
    wt="$(jq -r '.worktree_path // ""' "$f" 2>/dev/null || true)"
    updated_at="$(jq -r '.updated_at // ""' "$f" 2>/dev/null || true)"

    # Liveness gate — a live owner is always skipped (never touch a running
    # dispatch). When worktree_path is absent/null the owner pid file cannot
    # exist, so the owner is treated as dead (correct: no isolated worktree
    # means no live po-agent for this run).
    if [[ -n "$wt" && "$wt" != "null" ]] && _reap_owner_pid_alive "$wt"; then
      echo "loop: reconcile-stale — #$issue_n owner pid alive, skipping" >&2
      continue
    fi

    # Terminal-state guard (#616 follow-up): a CLOSED issue is finished work,
    # never a dead orphan. A dispatch that merged its PR and closed the issue
    # without writing current_phase=done leaves a non-done state whose issue is
    # already CLOSED; without this the pass re-Blocks a Done card every tick.
    if _reconcile_issue_closed "$issue_n" "$_rs_repo"; then
      echo "loop: reconcile-stale — #$issue_n is CLOSED, skipping (terminal state, not an orphan)" >&2
      continue
    fi

    # Dedup guard (#786): the state file is never deleted, so an already-
    # reconciled dead orphan re-satisfies every gate below on each tick. Once
    # needs-human-review is present the operator has been notified — skip so we
    # do not re-Block the card and re-post an identical comment every tick.
    if _reconcile_has_human_review_label "$issue_n" "$_rs_repo"; then
      echo "loop: reconcile-stale — #$issue_n already needs-human-review, skipping (already reconciled)" >&2
      continue
    fi

    # Staleness gate — updated_at older than ORPHAN_STALE_SECS.
    local age=""
    if [[ -n "$updated_at" && -n "$now_epoch" ]]; then
      local upd_epoch
      upd_epoch="$(_reap_epoch_of_iso "$updated_at" 2>/dev/null || echo "")"
      if [[ -n "$upd_epoch" ]]; then
        age=$(( now_epoch - upd_epoch ))
        (( age < 0 )) && age=0
      fi
    fi
    if [[ -z "$age" ]]; then
      # Unparseable timestamp — be conservative, do not fire.
      echo "loop: reconcile-stale — #$issue_n unparseable updated_at, skipping" >&2
      continue
    fi
    if (( age < ORPHAN_STALE_SECS )); then
      echo "loop: reconcile-stale — #$issue_n fresh (${age}s < ${ORPHAN_STALE_SECS}s), skipping" >&2
      continue
    fi

    if [[ "${RECONCILE_DRYRUN:-0}" == "1" ]]; then
      echo "loop: reconcile-stale — would reconcile #$issue_n (phase=$phase) → Blocked + needs-human-review (dead owner, age ${age}s, dry-run)" >&2
      continue
    fi

    # reap-and-resume: if phase=pr with a live PR, route to _stall_resume instead
    # of escalating — the po-agent was killed after PR creation but before CI poll.
    if [[ "${MAKATO_LOOP_PR_RESUME_DISABLE:-0}" != "1" && "$phase" == "pr" ]]; then
      local pr_num=""
      pr_num="$(jq -r '.github_pr_number // empty' "$f" 2>/dev/null || true)"
      if [[ -n "$pr_num" && "$pr_num" != "null" ]]; then
        # Dispatch guard (#171): returns 0 when the guard FIRES (same issue
        # dispatched within the window) → defer the reap to the next cycle.
        # Returns 1 when clear → proceed. Matches the cmd_dispatch call site
        # (`if _within_dispatch_guard; then skip`); no `!` inversion here.
        if _within_dispatch_guard "$issue_n" 2>/dev/null; then
          echo "loop: reconcile-stale — #$issue_n dispatch guard active, deferring reap-resume to next cycle" >&2
          continue
        fi
        # Lookup PR state via test hook or gh API.
        local pr_state=""
        if [[ -n "${MAKATO_LOOP_PR_STATE_OVERRIDE:-}" && -f "$MAKATO_LOOP_PR_STATE_OVERRIDE" ]]; then
          pr_state="$(jq -r --arg n "$pr_num" '.[$n] // empty' "$MAKATO_LOOP_PR_STATE_OVERRIDE" 2>/dev/null || true)"
        elif [[ -n "$_rs_repo" ]]; then
          pr_state="$(GH_HOST="${GH_HOST:-github.com}" gh pr view "$pr_num" \
            --repo "$_rs_repo" --json state --jq '.state' 2>/dev/null || true)"
        fi
        local spec_dir
        spec_dir="$(dirname "$f")"
        local key_for_resume
        key_for_resume="$(basename "$spec_dir")"
        local now_ts_r
        now_ts_r="$(_now)"
        local orch_log_r="$spec_dir/orchestrate.jsonl"
        if [[ "$pr_state" == "OPEN" ]]; then
          echo "loop: reconcile-stale — #$issue_n phase=pr, PR #${pr_num} OPEN, dead owner → reap-and-resume" >&2
          echo "{\"ts\":\"$now_ts_r\",\"skill\":\"loop\",\"issue\":$issue_n,\"step\":\"reap-and-resume\",\"status\":\"attempt\",\"data\":{\"pr_num\":$pr_num,\"phase\":\"$phase\",\"age_secs\":$age}}" \
            >>"$orch_log_r" 2>/dev/null || true
          _stall_resume "$issue_n" "$key_for_resume" "$spec_dir" "" || true
          continue
        elif [[ "$pr_state" == "MERGED" ]]; then
          echo "loop: reconcile-stale — #$issue_n phase=pr, PR #${pr_num} MERGED out-of-band → patching done" >&2
          jq '.current_phase = "done"' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f" || true
          echo "{\"ts\":\"$now_ts_r\",\"skill\":\"loop\",\"issue\":$issue_n,\"step\":\"reap-done-ooband\",\"status\":\"ok\",\"data\":{\"pr_num\":$pr_num,\"phase_was\":\"$phase\"}}" \
            >>"$orch_log_r" 2>/dev/null || true
          continue
        elif [[ "$pr_state" == "CLOSED" ]]; then
          echo "loop: reconcile-stale — #$issue_n phase=pr, PR #${pr_num} CLOSED (not merged) → falling through to escalation" >&2
          echo "{\"ts\":\"$now_ts_r\",\"skill\":\"loop\",\"issue\":$issue_n,\"step\":\"reap-closed-fallthrough\",\"status\":\"warn\",\"data\":{\"pr_num\":$pr_num,\"phase\":\"$phase\"}}" \
            >>"$orch_log_r" 2>/dev/null || true
          # fall through to existing escalation
        elif [[ -z "$pr_state" ]]; then
          echo "loop: WARN — reconcile-stale #$issue_n: could not determine PR #${pr_num} state → falling through to escalation" >&2
          # fall through to existing escalation
        fi
      fi
    fi

    echo "loop: reconcile-stale — #$issue_n orphaned (phase=$phase, owner dead, age ${age}s) → Blocked + needs-human-review" >&2

    # Build the runtime-context Situation string BEFORE emitting the escalate
    # entry below — otherwise `_reconcile_situation`'s "last event" read would
    # pick up this pass's own reconcile-orphaned-stale line instead of the last
    # thing the *dispatch* logged (#786). This is HALT-015 (dead session /
    # orphaned card), NOT HALT-014 (semantic stall ceiling): the reconciler
    # fires when a session died mid-run leaving a stale In-progress card, which
    # is an infra failure, not a dead loop.
    local _rs_situation
    _rs_situation="$(_reconcile_situation "$(dirname "$f")" "$issue_n" "$phase" "$age" 2>/dev/null || true)"

    # Emit orchestrate.jsonl escalate entry (best-effort).
    {
      local orch_log
      orch_log="$(dirname "$f")/orchestrate.jsonl"
      local now_ts
      now_ts="$(_now)"
      echo "{\"ts\":\"$now_ts\",\"skill\":\"loop\",\"issue\":$issue_n,\"step\":\"reconcile-orphaned-stale\",\"status\":\"escalate\",\"data\":{\"phase\":\"$phase\",\"age_secs\":$age,\"orphan_stale_secs\":$ORPHAN_STALE_SECS}}" \
        >>"$orch_log" 2>/dev/null || true
    } || true

    # Move the board card to Blocked (shared pattern with #368 reconciler).
    # board_edit_ok=1 only when the edit actually lands; label stamp is gated on it
    # to prevent infinite oscillation on repeated ticks.
    local board_edit_ok=0
    {
      if [[ -n "${MAKATO_LOOP_RECONCILE_TEST_FILE:-}" ]]; then
        echo "reconcile #${issue_n}" >>"$MAKATO_LOOP_RECONCILE_TEST_FILE"
        board_edit_ok=1
      else
        local cfg proj_owner proj_number proj_host field_id blocked_id item_id proj_node_id
        cfg="$(_read_project_config 2>/dev/null)" || { echo "loop: WARN — reconcile-stale #$issue_n: no config for board edit" >&2; true; }
        proj_owner="$(jq -r '.owner' <<<"$cfg")"
        proj_number="$(jq -r '.number' <<<"$cfg")"
        proj_host="$(jq -r '.host' <<<"$cfg")"
        field_id="$(jq -r '.github_project.fields.status.id // .github_project.status_field_id // empty' "$CONFIG_FILE" 2>/dev/null)"
        blocked_id="$(jq -r '.github_project.fields.status.options.blocked // (.github_project.options.blocked // empty)' "$CONFIG_FILE" 2>/dev/null)"
        proj_node_id="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE" 2>/dev/null)"
        if [[ -z "$field_id" || -z "$blocked_id" || -z "$proj_node_id" ]]; then
          echo "loop: WARN — reconcile-stale #$issue_n: missing field_id, blocked option id, or project_node_id in config" >&2
        else
          # Rate-budget pre-check (#683): skip item-id lookup if budget is low.
          # _check_graphql_rate_budget sleeps until reset when budget < floor —
          # acceptable here since reconcile-stale runs infrequently.
          if [[ "${RATE_GUARD:-1}" == "1" ]]; then
            local _rs_rg_rc=0
            _check_graphql_rate_budget "$proj_host" || _rs_rg_rc=$?
            if [[ $_rs_rg_rc -eq 2 ]]; then
              echo "loop: WARN — reconcile-stale #$issue_n: rate budget low; skipping board item-id lookup this tick (#683)" >&2
              continue
            fi
          fi
          local _rs_item_cmd_out=""
          item_id=""
          if [[ -n "${MAKATO_LOOP_STALE_REAP_TEST_CMD:-}" ]]; then
            _rs_item_cmd_out="$(eval "$MAKATO_LOOP_STALE_REAP_TEST_CMD" 2>/dev/null)" || true
          elif [[ -n "$_rs_repo" ]]; then
            # Cheap single-issue lookup (~1 GraphQL point) instead of paging the
            # whole board via item-list --limit 9999 (~1 point per item).
            item_id="$(_project_item_id_for_issue "$proj_host" "$proj_owner" "$_rs_repo" "$issue_n" "$proj_node_id" || true)"
          fi
          if [[ -z "$item_id" ]]; then
            if [[ -z "$_rs_item_cmd_out" && -z "${MAKATO_LOOP_STALE_REAP_TEST_CMD:-}" ]]; then
              _rs_item_cmd_out="$(GH_HOST="$proj_host" gh project item-list "$proj_number" \
                --owner "$proj_owner" --format json --limit 9999 2>/dev/null)" || true
            fi
            item_id="$(jq -r --argjson n "$issue_n" \
              '.items[] | select(.content.type == "Issue" and .content.number == $n) | .id' \
              <<<"$_rs_item_cmd_out" 2>/dev/null | head -1)" || true
          fi
          if [[ -n "$item_id" ]]; then
            if GH_HOST="$proj_host" gh project item-edit \
              --id "$item_id" \
              --project-id "$proj_node_id" \
              --field-id "$field_id" \
              --single-select-option-id "$blocked_id" \
              >/dev/null 2>&1; then
              board_edit_ok=1
            else
              echo "loop: WARN — reconcile-stale #$issue_n: gh project item-edit failed" >&2
            fi
          else
            echo "loop: WARN — reconcile-stale #$issue_n: could not resolve board item-id" >&2
          fi
        fi
      fi
    } || true

    # Apply needs-human-review label only when board edit succeeded.
    [[ "$board_edit_ok" -eq 1 ]] || { echo "loop: WARN — reconcile-stale #$issue_n: skipping label stamp (board edit did not succeed)" >&2; continue; }
    # (_rs_situation was computed above, before the escalate entry was emitted.)
    # Apply needs-human-review label (shared pattern with #368 reconciler).
    {
      local repo_flag=()
      if [[ -n "${MAKATO_LOOP_DISPATCH_REPO:-}" ]]; then
        repo_flag=(--repo "$MAKATO_LOOP_DISPATCH_REPO")
      fi
      if [[ -n "${MAKATO_LOOP_RECONCILE_LABEL_TEST_FILE:-}" ]]; then
        echo "label #${issue_n} needs-human-review" >>"$MAKATO_LOOP_RECONCILE_LABEL_TEST_FILE"
        _post_halt_comment "HALT-015" "$issue_n" "${MAKATO_LOOP_DISPATCH_REPO:-}" \
          --situation "$_rs_situation" || true
      else
        if ! gh issue edit "$issue_n" "${repo_flag[@]}" \
            --add-label "needs-human-review" >/dev/null 2>&1; then
          echo "loop: WARN — reconcile-stale #$issue_n: could not apply needs-human-review label" >&2
        else
          echo "loop: reconcile-stale — applied 'needs-human-review' label to #$issue_n" >&2
        fi
        _post_halt_comment "HALT-015" "$issue_n" "${MAKATO_LOOP_DISPATCH_REPO:-}" \
          --situation "$_rs_situation" || true
      fi
    } || true
  done < <(find "$scan_specs_dir" -maxdepth 2 \
    \( -name 'workflow-state-*.json' -o -name 'workflow-state.json' \) \
    -print0 2>/dev/null)

  return 0
}

# ---------------------------------------------------------------------------
# cmd_reconcile_stale — standalone subcommand: run one stale-orphan pass and
# exit.
# ---------------------------------------------------------------------------
cmd_reconcile_stale() {
  _reconcile_orphaned_stale
}

# ---------------------------------------------------------------------------
# next [STATUS_NAME] — first untracked open issue at the requested Status,
# or empty.
# ---------------------------------------------------------------------------
cmd_next() {
  local status_name="${1:-$DEFAULT_STATUS}"
  local queue
  queue="$(cmd_poll "$status_name")"
  local in_flight
  in_flight="$(in_flight_issues)"
  jq -r --argjson in_flight \
    "$(jq -R . <<<"$in_flight" | jq -sc 'map(select(length>0))')" \
    '.[] | .issue as $n
      | select(($in_flight | index($n|tostring) | not)) | $n' \
    <<<"$queue" | head -1
}

# ---------------------------------------------------------------------------
# status — pretty-print the status file.
# ---------------------------------------------------------------------------
cmd_status() {
  local s
  s="$(_read_status)"
  # Pretty-print with vcr alongside other top-level fields.
  jq 'if .vcr then
    . | to_entries
    | sort_by(
        if .key == "vcr" then 1
        elif .key == "updated_at" then 2
        else 0 end)
    | from_entries
  else . end' <<<"$s"
}

# ---------------------------------------------------------------------------
# _wd_owns_active <issue> — watchdog ownership CAS (#312). Returns 0 iff the
# live status file still names <issue> as the active workflow. Every watchdog
# write to active_workflow.* is gated on this so an ORPHANED watchdog (its
# parent cmd_dispatch was TERM'd mid-`wait`, reparenting the poll to init)
# cannot write against a loop-status.json that a LATER dispatch already
# cleared to active_workflow=null. Without the guard, jq's null-path
# autovivification (`.active_workflow.killed_by_watchdog = true` on a null
# node → {active_workflow:{killed_by_watchdog:true}}) resurrects the key —
# the T30 loop-smoke flake. File-scope (not nested in _watchdog_poll) so the
# smoke suite can exercise it deterministically via the _test-wd-owns hook.
# ---------------------------------------------------------------------------
_wd_owns_active() {
  local issue="$1"
  local cur
  cur="$(_read_status | jq -r '.active_workflow.issue // empty' 2>/dev/null || echo "")"
  [[ "$cur" == "$issue" ]]
}

# ---------------------------------------------------------------------------
# _watchdog_poll — background helper spawned by cmd_dispatch. Polls the
# dispatch log's mtime every $STALL_POLL_SECS seconds. When mtime has not
# advanced for STALL_WARN_SECS, stamps active_workflow.stalled=true and
# active_workflow.stalled_since. When it has not advanced for
# STALL_KILL_SECS, SIGTERM's the tracked child, waits STALL_TERM_GRACE_SECS,
# then SIGKILL's if it's still alive. Stamps last_watchdog_kill (a preserved
# snapshot survives the active_workflow=null clear that cmd_dispatch does
# on return) and exits.
#
# Terminates when its own parent (cmd_dispatch) exits, or when the tracked
# PID no longer exists — no signalling from the parent is required.
#
# Args: <log-file> <child-pid> <issue-number>
# ---------------------------------------------------------------------------
_watchdog_poll() {
  local log_file="$1"
  local child_pid="$2"
  local issue="$3"

  local warn_stamped=0
  local killed=0

  # Ownership guard (#312): only stamp active_workflow.* when the live status
  # file still shows THIS issue as the active workflow. See _wd_owns_active
  # (file-scope) for the full rationale — this makes a stale/orphaned watchdog
  # a no-op regardless of whether it was reaped in time.

  # `stat -c` on Linux, `stat -f` on macOS. Detect once.
  local stat_cmd
  if stat -c '%Y' "$log_file" >/dev/null 2>&1; then
    stat_cmd='stat -c %Y'
  else
    stat_cmd='stat -f %m'
  fi

  while :; do
    # If the tracked PID is gone, cmd_dispatch has already reaped it —
    # nothing left to guard. Exit quietly so we don't stamp a stale
    # active_workflow that the parent is about to clear.
    if ! kill -0 "$child_pid" 2>/dev/null; then
      return 0
    fi

    # If the log has been removed (parent cleanup) bail out defensively.
    if [[ ! -e "$log_file" ]]; then
      return 0
    fi

    local mtime now_epoch idle
    mtime="$($stat_cmd "$log_file" 2>/dev/null || echo 0)"
    now_epoch="$(date +%s)"
    idle=$((now_epoch - mtime))

    if [[ $killed -eq 0 && $idle -ge $STALL_KILL_SECS ]]; then
      # Orphan guard: a stale watchdog must not resurrect a cleared
      # active_workflow. If we no longer own the active slot, still kill the
      # tracked child (that is always safe and correct — a runaway process
      # should die) but do NOT write active_workflow.* against foreign state.
      local own_kill=1
      _wd_owns_active "$issue" || own_kill=0
      # Snapshot the kill audit BEFORE signalling — active_workflow will
      # be nulled by cmd_dispatch shortly, but last_watchdog_kill is a
      # sibling field that survives.
      # Classify stall cause (#444): read halt_code from the issue's
      # workflow-state file; read stall_restart_count from loop-status.
      local stall_cause
      local _wf_halt_code=""
      local _wf_file
      _wf_file="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
        -name "workflow-state-${issue}.json" 2>/dev/null | head -1)"
      if [[ -f "$_wf_file" ]]; then
        _wf_halt_code="$(jq -r '(.halt_audit // []) | last | .code // empty' "$_wf_file" 2>/dev/null || true)"
      fi
      local _restart_count=0
      _restart_count="$(_read_status | jq -r '.stall_restart_count // 0' 2>/dev/null || echo 0)"
      if [[ -n "$_wf_halt_code" ]]; then
        stall_cause="halt_emitted"
      elif [[ "$_restart_count" -ge "$MAX_STALL_RESTARTS" ]]; then
        stall_cause="no_progress"
      else
        stall_cause="transient"
      fi
      local kill_stamp
      kill_stamp="$(_now)"
      local audit
      audit="$(jq -n --argjson issue "$issue" \
        --arg stamped_at "$kill_stamp" \
        --argjson idle "$idle" \
        --argjson kill_secs "$STALL_KILL_SECS" \
        --arg stall_cause "$stall_cause" \
        '{issue: $issue, killed_at: $stamped_at, idle_seconds: $idle, stall_kill_seconds: $kill_secs, stall_cause: $stall_cause}')"
      if [[ $own_kill -eq 1 ]]; then
        _patch_status '.last_watchdog_kill' "$audit"
        _patch_status '.active_workflow.killed_by_watchdog' 'true'
      fi
      echo "loop: watchdog SIGTERM'ing PO-agent pid=$child_pid (issue #$issue, idle=${idle}s ≥ ${STALL_KILL_SECS}s)" >&2
      kill -TERM "$child_pid" 2>/dev/null || true
      # Grace period, then hard-kill if the child hasn't exited.
      local waited=0
      while [[ $waited -lt $STALL_TERM_GRACE_SECS ]] && kill -0 "$child_pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
      done
      if kill -0 "$child_pid" 2>/dev/null; then
        echo "loop: watchdog SIGKILL'ing PO-agent pid=$child_pid (still alive after ${STALL_TERM_GRACE_SECS}s)" >&2
        kill -KILL "$child_pid" 2>/dev/null || true
      fi
      killed=1
      return 0
    fi

    if [[ $warn_stamped -eq 0 && $idle -ge $STALL_WARN_SECS ]]; then
      # Same orphan guard as the kill path: never stamp stalled against a
      # loop-status.json we no longer own (would resurrect a cleared key).
      if _wd_owns_active "$issue"; then
        local warn_stamp
        warn_stamp="$(_now)"
        _patch_status '.active_workflow.stalled' 'true'
        _patch_status '.active_workflow.stalled_since' "\"$warn_stamp\""
        echo "loop: watchdog WARN — PO-agent idle for ${idle}s ≥ ${STALL_WARN_SECS}s (issue #$issue)" >&2
        warn_stamped=1
      fi
    fi

    sleep "$STALL_POLL_SECS"
  done
}

# ---------------------------------------------------------------------------
# _stall_restart <issue> <spec-folder> <log-file>
#
# Called by cmd_dispatch after a watchdog kill. Reads last_watchdog_kill
# .stall_cause from loop-status.json and routes:
#   halt_emitted → skip (po-agent HALTed itself; restart would re-enter a
#                        HALT state — let the HALT classification path handle
#                        the issue instead). Emits step:stall-classify
#                        status:skip to orchestrate.jsonl. Returns 0.
#   transient    → bounded restart. Computes exponential backoff, sleeps,
#                  increments stall_restart_count, re-dispatches. Emits
#                  step:stall-restart status:attempt. Returns 0.
#   no_progress  → escalate. Emits step:stall-restart status:escalate with
#                  halt_code:HALT-014, appends halt to workflow-state, labels
#                  the issue needs-human-review. Returns 1.
#   (absent/unknown) → treated as transient (safe default).
#
# Guard: MAKATO_LOOP_STALL_DISABLE=1 → immediate return 0 (legacy path).
# (#444)
# ---------------------------------------------------------------------------
_stall_restart() {
  local issue="$1"
  local spec_folder="${2:-}"
  local log_file="${3:-}"

  # Opt-out guard — must mirror the watchdog opt-out.
  if [[ "${MAKATO_LOOP_STALL_DISABLE:-0}" == "1" ]]; then
    return 0
  fi

  # Resolve orchestrate.jsonl path (best-effort: spec_folder hint first,
  # then scan; emit is non-fatal when not found).
  local orch_log=""
  if [[ -n "$spec_folder" && -f "$spec_folder/orchestrate.jsonl" ]]; then
    orch_log="$spec_folder/orchestrate.jsonl"
  elif [[ -n "$spec_folder" ]]; then
    orch_log="$spec_folder/orchestrate.jsonl"
  else
    orch_log="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
      -name "orchestrate.jsonl" 2>/dev/null | head -1)"
  fi

  local stall_cause
  stall_cause="$(_read_status | jq -r '.last_watchdog_kill.stall_cause // "transient"' 2>/dev/null || echo "transient")"

  local now_ts
  now_ts="$(_now)"

  _orch_append() {
    local entry="$1"
    if [[ -n "$orch_log" ]]; then
      echo "$entry" >> "$orch_log" 2>/dev/null || true
    fi
  }

  case "$stall_cause" in
    halt_emitted)
      # po-agent already HALTed — do not restart; let the HALT path own it.
      _orch_append "{\"ts\":\"$now_ts\",\"skill\":\"loop\",\"issue\":$issue,\"step\":\"stall-classify\",\"status\":\"skip\",\"data\":{\"stall_cause\":\"halt_emitted\",\"reason\":\"po-agent emitted a HALT code before stalling\"}}"
      return 0
      ;;
    no_progress)
      # Stall_restart_count exhausted or cause resolved to no_progress.
      local restart_count
      restart_count="$(_read_status | jq -r '.stall_restart_count // 0' 2>/dev/null || echo 0)"
      _orch_append "{\"ts\":\"$now_ts\",\"skill\":\"loop\",\"issue\":$issue,\"step\":\"stall-restart\",\"status\":\"escalate\",\"data\":{\"stall_cause\":\"no_progress\",\"halt_code\":\"HALT-014\",\"stall_restart_count\":$restart_count}}"
      # Append HALT-014 to workflow-state (best-effort).
      local _wf_sh
      _wf_sh="$(dirname "$(dirname "$0")")/shared/workflow-state.sh"
      if [[ -x "$_wf_sh" ]]; then
        # Derive KEY from spec_folder basename if available.
        local _key=""
        if [[ -n "$spec_folder" ]]; then
          _key="$(basename "$spec_folder")"
        fi
        if [[ -n "$_key" ]]; then
          "$_wf_sh" append-halt "$_key" "$issue" HALT-014 '{"origin":"stall"}' 2>/dev/null || true
        fi
      fi
      # Apply needs-human-review label (best-effort, non-fatal).
      local _repo="${MAKATO_LOOP_DISPATCH_REPO:-}"
      if [[ -n "$_repo" ]]; then
        gh issue edit "$issue" --add-label needs-human-review --repo "$_repo" 2>/dev/null || true
      fi
      _post_halt_comment "HALT-014" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
      return 1
      ;;
    *)
      # transient (or absent/unknown) — bounded restart.
      local restart_count
      restart_count="$(_read_status | jq -r '.stall_restart_count // 0' 2>/dev/null || echo 0)"
      # Exponential backoff: base * 2^count. Cap at STALL_KILL_SECS so we
      # don't wait longer than the watchdog threshold.
      local backoff=$(( STALL_BACKOFF_BASE_SECS * (1 << restart_count) ))
      if [[ $backoff -gt $STALL_KILL_SECS ]]; then
        backoff=$STALL_KILL_SECS
      fi

      # Read resume_point from workflow-state file (best-effort).
      local resume_pt="null"
      local _wf_file
      _wf_file="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
        -name "workflow-state-${issue}.json" 2>/dev/null | head -1)"
      if [[ -f "$_wf_file" ]]; then
        resume_pt="$(jq -r '.resume_point // "null"' "$_wf_file" 2>/dev/null || echo "null")"
      fi

      _orch_append "{\"ts\":\"$now_ts\",\"skill\":\"loop\",\"issue\":$issue,\"step\":\"stall-restart\",\"status\":\"attempt\",\"data\":{\"stall_cause\":\"transient\",\"backoff_secs\":$backoff,\"resume_point\":\"$resume_pt\",\"stall_restart_count\":$restart_count}}"

      # Increment stall_restart_count before the sleep so a kill during
      # backoff still records the attempt.
      local new_count=$(( restart_count + 1 ))
      _patch_status '.stall_restart_count' "$new_count"

      # Backoff sleep (honour STALL_POLL_SECS as the minimum tick unit).
      sleep "$backoff" 2>/dev/null || true
      return 0
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _parse_dispatch_result <log-file>
#
# Classifies the outcome of a `claude -p --output-format stream-json`
# dispatch by inspecting its log for the terminal {"type":"result",...}
# line. Returns one of three values on stdout:
#   complete   — terminal result line present and is_error is false/absent
#   errored    — terminal result line present and is_error: true
#   incomplete — terminal result line absent (process exited without it)
#
# Guard: MAKATO_LOOP_STALL_DISABLE=1 → returns "complete" immediately,
# preserving legacy opt-out behaviour (no classification, no resume).
#
# When log-file path is empty or the file does not exist, returns
# "incomplete" (safe default — triggers resume path). (#531)
# ---------------------------------------------------------------------------
_parse_dispatch_result() {
  local log_file="${1:-}"

  # Opt-out guard.
  if [[ "${MAKATO_LOOP_STALL_DISABLE:-0}" == "1" ]]; then
    echo "complete"
    return 0
  fi

  # Missing or empty log file → safe default.
  if [[ -z "$log_file" || ! -f "$log_file" ]]; then
    echo "incomplete"
    return 0
  fi

  # Scan for the terminal {"type":"result",...} line. stream-json emits one
  # per session; the last one wins (defensive against multi-line tails).
  local result_line=""
  while IFS= read -r line; do
    local t
    t="$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null || true)"
    if [[ "$t" == "result" ]]; then
      result_line="$line"
    fi
  done <"$log_file"

  if [[ -z "$result_line" ]]; then
    echo "incomplete"
    return 0
  fi

  local is_error
  is_error="$(printf '%s' "$result_line" | jq -r '.is_error // false' 2>/dev/null || echo "false")"
  if [[ "$is_error" == "true" ]]; then
    echo "errored"
  else
    echo "complete"
  fi
}

# ---------------------------------------------------------------------------
# _stall_resume <issue> <key> <spec-folder> <log-file>
#
# Called by cmd_dispatch when the child exited WITHOUT a watchdog kill but
# _parse_dispatch_result returned "incomplete" or "errored" — meaning the
# claude process exited before writing its terminal result line (crashed,
# OOM'd, or SIGKILL'd by the kernel). Re-enters the session via
#   claude --dangerously-skip-permissions --resume "$key" -p "<prompt>"
# from the issue's worktree directory, mirroring context-handoff.sh:211.
#
# Budget: reads and shares stall_restart_count from loop-status.json with
# _stall_restart — a single counter for both restart paths, so the two
# mechanisms cannot double the budget.
#
# Backoff: STALL_BACKOFF_BASE_SECS * (1 << stall_restart_count), capped at
# STALL_KILL_SECS (same formula as _stall_restart).
#
# On budget exhaustion (stall_restart_count >= MAX_STALL_RESTARTS):
#   emits step:stall-resume status:escalate halt_code:HALT-014 to
#   orchestrate.jsonl, appends HALT-014 to workflow-state, applies
#   needs-human-review (best-effort), returns 1.
#
# Guard: MAKATO_LOOP_STALL_DISABLE=1 → emits step:stall-resume
# status:skip and returns 0 (no claude invocation). (#531)
# ---------------------------------------------------------------------------
_stall_resume() {
  local issue="$1"
  local key="${2:-}"
  local spec_folder="${3:-}"
  local log_file="${4:-}"

  # Opt-out guard.
  if [[ "${MAKATO_LOOP_STALL_DISABLE:-0}" == "1" ]]; then
    # Resolve orch_log for the skip emit.
    local orch_log=""
    if [[ -n "$spec_folder" ]]; then
      orch_log="$spec_folder/orchestrate.jsonl"
    fi
    local now_ts
    now_ts="$(_now)"
    if [[ -n "$orch_log" ]]; then
      echo "{\"ts\":\"$now_ts\",\"skill\":\"loop\",\"issue\":$issue,\"step\":\"stall-resume\",\"status\":\"skip\",\"data\":{\"reason\":\"MAKATO_LOOP_STALL_DISABLE=1\"}}" \
        >> "$orch_log" 2>/dev/null || true
    fi
    return 0
  fi

  # Resolve orchestrate.jsonl path (same pattern as _stall_restart).
  local orch_log=""
  if [[ -n "$spec_folder" && -f "$spec_folder/orchestrate.jsonl" ]]; then
    orch_log="$spec_folder/orchestrate.jsonl"
  elif [[ -n "$spec_folder" ]]; then
    orch_log="$spec_folder/orchestrate.jsonl"
  else
    orch_log="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
      -name "orchestrate.jsonl" 2>/dev/null | head -1)"
  fi

  _orch_append() {
    local entry="$1"
    if [[ -n "$orch_log" ]]; then
      echo "$entry" >> "$orch_log" 2>/dev/null || true
    fi
  }

  local now_ts
  now_ts="$(_now)"

  # Read shared restart counter.
  local restart_count
  restart_count="$(_read_status | jq -r '.stall_restart_count // 0' 2>/dev/null || echo 0)"

  # Budget check — mirrors _stall_restart's no_progress branch.
  if [[ "$restart_count" -ge "$MAX_STALL_RESTARTS" ]]; then
    _orch_append "{\"ts\":\"$now_ts\",\"skill\":\"loop\",\"issue\":$issue,\"step\":\"stall-resume\",\"status\":\"escalate\",\"data\":{\"halt_code\":\"HALT-014\",\"stall_restart_count\":$restart_count,\"max_stall_restarts\":$MAX_STALL_RESTARTS}}"
    # Append HALT-014 to workflow-state (best-effort).
    local _wf_sh
    _wf_sh="$(dirname "$(dirname "$0")")/shared/workflow-state.sh"
    if [[ -x "$_wf_sh" ]]; then
      local _key_for_halt="${key:-}"
      if [[ -z "$_key_for_halt" && -n "$spec_folder" ]]; then
        _key_for_halt="$(basename "$spec_folder")"
      fi
      if [[ -n "$_key_for_halt" ]]; then
        "$_wf_sh" append-halt "$_key_for_halt" "$issue" HALT-014 '{"origin":"stall-resume"}' 2>/dev/null || true
      fi
    fi
    # Apply needs-human-review label (best-effort, non-fatal).
    local _repo="${MAKATO_LOOP_DISPATCH_REPO:-}"
    if [[ -n "${MAKATO_LOOP_LABEL_TEST_FILE:-}" ]]; then
      echo "label #${issue} needs-human-review" >> "$MAKATO_LOOP_LABEL_TEST_FILE" 2>/dev/null || true
      _post_halt_comment "HALT-014" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
    elif [[ -n "$_repo" ]]; then
      gh issue edit "$issue" --add-label needs-human-review --repo "$_repo" 2>/dev/null || true
      _post_halt_comment "HALT-014" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
    fi
    return 1
  fi

  # Compute exponential backoff (same formula as _stall_restart).
  local backoff=$(( STALL_BACKOFF_BASE_SECS * (1 << restart_count) ))
  if [[ $backoff -gt $STALL_KILL_SECS ]]; then
    backoff=$STALL_KILL_SECS
  fi

  # Resolve the worktree directory from workflow-state (best-effort).
  local worktree_dir=""
  local _wf_file
  _wf_file="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
    -name "workflow-state-${issue}.json" 2>/dev/null | head -1)"
  if [[ -f "$_wf_file" ]]; then
    worktree_dir="$(jq -r '.worktree_path // ""' "$_wf_file" 2>/dev/null || true)"
  fi
  # Fall back to REPO_ROOT when worktree_path is absent or null.
  if [[ -z "$worktree_dir" || "$worktree_dir" == "null" ]]; then
    worktree_dir="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  fi

  # #616: read the persisted Claude session UUID. `claude --resume` requires a
  # session UUID, NOT the spec KEY or issue number — passing the KEY was the
  # root cause of #616 (resume silently failed, orphaning the in-flight run).
  # cmd_dispatch persists last_session_id after every dispatch; if it is
  # absent (hard crash before the terminal result line, or a legacy state
  # file), there is no session to resume into — skip the resume entirely and
  # let the orphan-liveness detection pass recover the run on a later tick.
  # Skipping BEFORE the counter increment + backoff avoids wasting a restart
  # budget slot on a resume that cannot run.
  local _resume_sid=""
  if [[ -f "$_wf_file" ]]; then
    _resume_sid="$(jq -r '.last_session_id // ""' "$_wf_file" 2>/dev/null || true)"
  fi
  if [[ -z "$_resume_sid" || "$_resume_sid" == "null" ]]; then
    _orch_append "{\"ts\":\"$now_ts\",\"skill\":\"loop\",\"issue\":$issue,\"step\":\"stall-resume\",\"status\":\"skip\",\"data\":{\"reason\":\"no_session_id\"}}"
    return 0
  fi

  # Increment shared restart counter before the sleep (mirrors _stall_restart
  # convention: a kill during backoff still records the attempt).
  local new_count=$(( restart_count + 1 ))
  _patch_status '.stall_restart_count' "$new_count"

  _orch_append "{\"ts\":\"$now_ts\",\"skill\":\"loop\",\"issue\":$issue,\"step\":\"stall-resume\",\"status\":\"attempt\",\"data\":{\"key\":\"${key:-}\",\"backoff_secs\":$backoff,\"worktree_dir\":\"$worktree_dir\",\"stall_restart_count\":$restart_count}}"

  # Backoff sleep.
  local sleep_cmd="${MAKATO_LOOP_SLEEP_CMD:-sleep}"
  $sleep_cmd "$backoff" 2>/dev/null || true

  # Resume the session from the worktree directory.
  local resume_prompt="Use the Task tool to dispatch the makato-orchestrate:po-agent subagent to resume driving GitHub issue #${issue} to a merged PR. The po-agent owns the outer loop, workflow-state, and all makato-build --autonomous dispatch; do not invoke makato-build or makato-plan skills directly from this session. Return the po-agent's final R1 envelope verbatim."
  (
    cd "$worktree_dir" 2>/dev/null || true
    MAKATO_HEADLESS=1 "$CLAUDE_BIN" --dangerously-skip-permissions \
      --output-format stream-json --verbose \
      --resume "$_resume_sid" \
      -p "$resume_prompt" >>"$log_file" 2>&1 || true
  )
  return 0
}

# ---------------------------------------------------------------------------
# _seconds_since <iso8601-timestamp>
#
# Emits seconds elapsed between the argument and now, or a large number
# (999999) if the argument is empty / unparseable. Used by the #171
# guard checks to reason about the age of active_workflow.started_at
# and .last_dispatch_at. The "999999 on unparseable" convention makes
# the guard predicate "younger than GAP" naturally false on missing
# data, so the caller does not need to special-case null timestamps.
# ---------------------------------------------------------------------------
_seconds_since() {
  local ts="${1:-}"
  if [[ -z "$ts" || "$ts" == "null" ]]; then
    echo 999999
    return 0
  fi
  # python3 is already a hard dependency (`_now`); reuse it for parsing
  # so the calendar arithmetic handles month/year boundaries correctly.
  python3 -c "
import sys, datetime
try:
    ts = sys.argv[1].replace('Z', '+00:00')
    then = datetime.datetime.fromisoformat(ts)
    if then.tzinfo is None:
        then = then.replace(tzinfo=datetime.timezone.utc)
    delta = datetime.datetime.now(datetime.timezone.utc) - then
    print(int(delta.total_seconds()))
except Exception:
    print(999999)
" "$ts" 2>/dev/null || echo 999999
}

# ---------------------------------------------------------------------------
# _within_dispatch_guard <issue-number>
#
# The #171 idempotent-dispatch guard. Returns 0 (guard fires — refuse
# dispatch, truthy under `if _within_dispatch_guard`) or 1 (guard
# clear — proceed). Two independent predicates, either firing refuses:
#
#   A) active_workflow.issue == <issue> AND age of started_at <
#      MIN_DISPATCH_GAP_SECS — the same issue is still in flight from
#      a prior dispatch. This is the exact 35× sleep-wake burst
#      scenario from #171 where cmd_run re-enters within seconds of
#      the prior cmd_dispatch and finds active_workflow still
#      pointing at #145 because the prior dispatch is still winding
#      down. Unparseable / missing started_at yields _seconds_since
#      == 999999, which fails-open — the crashed-dispatch reclaim
#      guarantee below.
#
#   B) .last_dispatch_issue == <issue> AND age of .last_dispatch_at
#      < LAST_DISPATCH_GAP_SECS — the same issue was JUST dispatched
#      (active_workflow may have been cleared, but the completion was
#      moments ago). Prevents cmd_run from immediately re-picking the
#      same issue if the PO-agent's workflow-state.json write races
#      with the next poll.
#
# Both predicates fail-open when the timestamp is stale enough — no
# permanent refuse state. A crashed dispatch that never cleared
# active_workflow reclaims after MIN_DISPATCH_GAP elapses.
# ---------------------------------------------------------------------------
_within_dispatch_guard() {
  local issue="$1"
  local status
  status="$(_read_status)"
  # Predicate A — same-issue still in flight, fresh started_at.
  local active_issue active_started_at
  active_issue="$(jq -r '.active_workflow.issue // empty' <<<"$status")"
  active_started_at="$(jq -r '.active_workflow.started_at // empty' <<<"$status")"
  if [[ "$active_issue" == "$issue" ]]; then
    local age_a
    age_a="$(_seconds_since "$active_started_at")"
    if [[ "$age_a" -lt "$MIN_DISPATCH_GAP_SECS" ]]; then
      return 0
    fi
  fi
  # Predicate B — same-issue just-dispatched, fresh last_dispatch_at.
  local last_issue last_ts
  last_issue="$(jq -r '.last_dispatch_issue // empty' <<<"$status")"
  last_ts="$(jq -r '.last_dispatch_at // empty' <<<"$status")"
  if [[ "$last_issue" == "$issue" ]]; then
    local age_b
    age_b="$(_seconds_since "$last_ts")"
    if [[ "$age_b" -lt "$LAST_DISPATCH_GAP_SECS" ]]; then
      return 0
    fi
  fi
  return 1
}

# ---------------------------------------------------------------------------
# _derive_key_for_issue <ISSUE_NUMBER> [<REPO>]
#
# Derives the spec KEY (feature slug) for an issue by reading its body and
# extracting the provenance the `to-issues` skill writes into every
# generated issue. Two sources, both from the issue-template:
#   1. Footer:   *Feature slug: `<slug>` — produced by to-issues v3.x.*
#   2. Fallback: the top-of-body line `specs/<slug>/stories.json`
#   3. Third fallback (#232): when NEITHER provenance marker is present (a
#      hand-filed or auto-filed testbox/CI issue), derive
#      `<issue-number>-<normalized-title>` — the exact seed-issue SLUG
#      convention — so the loop no longer needs a manual seed-issue run to
#      produce a dispatchable KEY. Reached only when 1 and 2 both miss, so
#      to-issues-provenance issues are unchanged.
#
# The slug becomes KEY in the po-agent dispatch bundle; the po-agent
# resolves the spec folder via `specs/<KEY>-*/` prefix-match. When the
# spec folder does not exist locally the po-agent HALTs with HALT-006 —
# the correct documented failure path, not a regression (before this the
# dispatch failed one step earlier at `missing input: KEY`).
#
# On success: prints the sanitised slug to stdout, returns 0.
# On failure (gh error / empty body AND empty title): prints nothing,
# returns 1 — the caller logs a WARN and dispatches with an empty KEY so the
# po-agent surfaces the input-validation failure with a clear audit.
#
# Test hooks (keep the T25/T27 smoke tests fully offline):
#   MAKATO_LOOP_ISSUE_BODY_OVERRIDE  — file used as the issue body instead of
#                                      invoking `gh issue view --json body`.
#   MAKATO_LOOP_ISSUE_TITLE_OVERRIDE — string used as the issue title instead
#                                      of `gh issue view --json title` (#232).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _slug_truncate_wb <normalized-slug> — truncate a hyphen-normalized slug to
# 40 chars with word-boundary backoff (#721, FM-KEY-CUT).
#
# The seed-issue SKILL.md Step 4 algorithm truncates a title-slug to 40 chars
# on a WORD boundary — it never cuts mid-word. Two loop.sh call sites
# (`_derive_key_for_issue` third-fallback and `_auto_seed_block_full`
# title-slug fallback) previously used a bare `cut -c1-40 | sed 's/-+$//'`,
# which cuts at byte 40 regardless of word boundaries, so a KEY derived here
# for a title crossing 40 chars mid-word mismatched the folder seed-issue
# created (e.g. `…-verificatio` vs `…-verification`), silently killing the
# po-agent on input validation.
#
# This helper reproduces the word-boundary rule: cut to 40, strip a trailing
# hyphen; then if the result is exactly 40 chars AND still contains a hyphen
# (i.e. the cut landed mid-word, not on a boundary), drop the trailing partial
# word. sed -E with basic classes only (macOS + GNU safe).
# ---------------------------------------------------------------------------
_slug_truncate_wb() {
  local s="$1"
  s="$(printf '%s' "$s" | cut -c1-40 | sed -E 's/-+$//')"
  if [[ "${#s}" -eq 40 && "$s" == *-* ]]; then
    # Mid-word cut: strip the trailing partial word (everything after the last
    # hyphen), then any hyphen the strip exposes.
    s="$(printf '%s' "$s" | sed -E 's/-[^-]*$//')"
  fi
  printf '%s' "$s"
}

_derive_key_for_issue() {
  local issue="$1"
  local repo="${2:-${MAKATO_LOOP_DISPATCH_REPO:-}}"

  # Declare the repo flag once — both the body fetch and the title fetch
  # (#232 third fallback below) reuse it.
  local -a repo_flag=()
  [[ -n "$repo" ]] && repo_flag=(--repo "$repo")

  # REST endpoint for the #447 fallback. `gh api` expands the {owner}/{repo}
  # placeholders from the current repo when no explicit repo is supplied.
  local rest_issue_path
  if [[ -n "$repo" ]]; then
    rest_issue_path="repos/${repo}/issues/${issue}"
  else
    rest_issue_path="repos/{owner}/{repo}/issues/${issue}"
  fi

  local body
  if [[ -n "${MAKATO_LOOP_ISSUE_BODY_OVERRIDE:-}" ]]; then
    body="$(cat "$MAKATO_LOOP_ISSUE_BODY_OVERRIDE" 2>/dev/null)" || return 1
  else
    # #447: wrap the body fetch with a REST fallback. The wrapper returns the
    # raw `{ "body": … }` JSON (primary) or the full issue object (REST); both
    # expose `.body`, so the extraction below is shape-agnostic. On wrapper
    # exhaustion the function returns 1 exactly as the previous `|| return 1`.
    local body_json
    if ! body_json="$(_gh_with_fallback "KEY-derivation body #${issue}" \
        issue view "$issue" "${repo_flag[@]}" --json body \
        -- api "$rest_issue_path")"; then
      return 1
    fi
    body="$(jq -r '.body // ""' <<<"$body_json" 2>/dev/null)" || return 1
  fi
  [[ -n "$body" ]] || return 1

  # Primary: footer line  *Feature slug: `<slug>` — produced by to-issues …*
  # BSD/macOS `sed` compatible (no -E, no PCRE lookarounds).
  local slug
  slug="$(printf '%s\n' "$body" \
    | sed -n "s/.*Feature slug: \`\([^\`]*\)\` — produced by to-issues.*/\1/p" \
    | head -1)"

  # Fallback: top-of-body provenance  specs/<slug>/stories.json
  # Matches a real slug (starts alnum, then alnum/hyphen only) so the literal
  # doc-example placeholder `specs/<slug>/stories.json` — angle brackets, which
  # a real slug never contains — no longer matches and can no longer produce a
  # bogus KEY=-slug- (#721, FM-FALSE-MATCH; incident #571). A genuine
  # provenance slug like `554-some-epic-story` still matches (with or without a
  # `> generated from` prefix, per the historic to-issues formats). sed -E
  # basic classes only (macOS + GNU safe).
  if [[ -z "$slug" ]]; then
    slug="$(printf '%s\n' "$body" \
      | sed -nE 's|.*specs/([a-z0-9][a-z0-9-]*)/stories\.json.*|\1|p' \
      | head -1)"
  fi

  # Third fallback (#232): the issue carries NO to-issues provenance at all —
  # a hand-filed or auto-filed (testbox/CI) issue. Derive
  # <issue-number>-<normalized-title>, matching seed-issue's SLUG convention
  # exactly (SKILL.md Step 4), so the loop no longer needs a manual seed-issue
  # run to produce a dispatchable KEY, and so a spec folder created by either
  # on-ramp resolves to the same slug. Reached ONLY when both provenance
  # patterns above missed, so provenance issues are unchanged.
  # Test hook: MAKATO_LOOP_ISSUE_TITLE_OVERRIDE mirrors the body override.
  if [[ -z "$slug" ]]; then
    local title
    if [[ -n "${MAKATO_LOOP_ISSUE_TITLE_OVERRIDE:-}" ]]; then
      title="$MAKATO_LOOP_ISSUE_TITLE_OVERRIDE"
    else
      # #447: REST fallback for the title fetch. Failure keeps the previous
      # fail-open behaviour (title stays empty, KEY derivation returns 1 below).
      local title_json
      if title_json="$(_gh_with_fallback "KEY-derivation title #${issue}" \
          issue view "$issue" "${repo_flag[@]}" --json title \
          -- api "$rest_issue_path")"; then
        title="$(jq -r '.title // ""' <<<"$title_json" 2>/dev/null || true)"
      fi
    fi
    if [[ -n "$title" ]]; then
      # seed-issue normalization: lowercase, non-alnum → '-', collapse runs,
      # strip leading/trailing '-', truncate to 40 chars, strip a trailing '-'
      # left by truncation. sed -E with basic classes only (macOS + GNU safe).
      local norm
      norm="$(printf '%s' "$title" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
      norm="$(_slug_truncate_wb "$norm")"
      [[ -n "$norm" ]] && slug="${issue}-${norm}"
    fi
  fi

  [[ -n "$slug" ]] || return 1

  # Disambiguation: when a slug matches multiple specs/ folders (epic
  # collision — e.g. two issues sharing a slug like "agent-skill-routing"),
  # pick the folder whose created-issues.json or plan.md references this
  # issue number. Without this, _derive_key_for_issue would return the same
  # slug for both issues; the po-agent prefix-match would then resolve to
  # whichever folder sorts first, dispatching the wrong plan.
  local spec_root="${REPO_ROOT:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)}/specs"
  if [[ -d "$spec_root" ]]; then
    local -a candidates=()
    while IFS= read -r -d '' dir; do
      candidates+=("$dir")
    done < <(find "$spec_root" -maxdepth 1 -type d -name "${slug}-*" -print0 2>/dev/null)
    if [[ "${#candidates[@]}" -gt 1 ]]; then
      local disambig=""
      for candidate in "${candidates[@]}"; do
        if grep -qsE '"issue_number"[[:space:]]*:[[:space:]]*'"$issue"'[^0-9]' \
              "$candidate/created-issues.json" "$candidate/plan.md" 2>/dev/null; then
          disambig="$(basename "$candidate")"
          break
        fi
      done
      [[ -n "$disambig" ]] && slug="$disambig"
    fi
  fi

  # Sanitise defensively: any character outside [A-Za-z0-9._-] becomes a
  # dash, so the derived BRANCH (feat/<issue>-<slug>) is always a valid ref.
  # to-issues slugs are already lowercase-hyphenated, so this is a no-op in
  # practice — but it guards against a hand-edited body.
  slug="${slug//[^a-zA-Z0-9._-]/-}"

  printf '%s\n' "$slug"
}

# ---------------------------------------------------------------------------
# _spec_folder_for_key <KEY>
#
# Binary existence check: does any specs/<KEY>*/ folder exist under SPECS_DIR?
# Returns 0 and prints the matching basename when a folder is found; returns 1
# and prints nothing when no folder matches.
#
# Reuses the SPECS_DIR env override (line 239) as its offline test seam —
# the same override used throughout loop.sh (e.g. in_flight_issues, _is_orphan_issue,
# _auto_seed_reconcile_thin_body). To exercise the miss path in tests, point
# SPECS_DIR at a temp directory that contains no folder starting with <KEY>.
# To exercise the hit path, create a ${KEY}-slug subfolder there.
#
# Distinct from the multi-candidate disambiguation block inside
# _derive_key_for_issue (lines 1536-1550): that block resolves among several
# matching folders to break an epic-slug collision; this function answers the
# binary question "does any folder for this KEY exist?" with a single find
# and is intentionally simpler.
# ---------------------------------------------------------------------------
_spec_folder_for_key() {
  local key="$1"
  local spec_root="${SPECS_DIR:-${REPO_ROOT}/specs}"
  local match
  match="$(find "$spec_root" -maxdepth 1 -type d -name "${key}*" -print0 2>/dev/null \
    | tr '\0' '\n' | head -1)"
  if [[ -n "$match" ]]; then
    printf '%s\n' "$(basename "$match")"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# _assign_issue <ISSUE_NUMBER> — assign the issue to the dispatch actor via
# `gh issue edit --add-assignee`, firing the `issues.assigned` webhook that
# `project-board-sync.yml` translates into a Ready → In progress board move
# (#33). Best-effort: a non-zero `gh` exit is logged and swallowed so a
# GitHub outage or a missing `issues:write` scope never blocks real work.
# Repo is taken from MAKATO_LOOP_DISPATCH_REPO (set by cmd_run from the poll
# result); when absent, `gh` falls back to the ambient repo context.
# ---------------------------------------------------------------------------
_assign_issue() {
  local issue="$1"
  [[ "$ASSIGN_ON_DISPATCH" == "1" ]] || return 0

  # Test hook: record the intended assign instead of hitting the network.
  # loop-smoke-tests.sh sets MAKATO_LOOP_ASSIGN_TEST_FILE to a path and
  # asserts on its contents.
  if [[ -n "${MAKATO_LOOP_ASSIGN_TEST_FILE:-}" ]]; then
    echo "assign #${issue} assignee=${ASSIGNEE} repo=${MAKATO_LOOP_DISPATCH_REPO:-<ambient>}" \
      >>"${MAKATO_LOOP_ASSIGN_TEST_FILE}"
    return 0
  fi

  local -a repo_flag=()
  [[ -n "${MAKATO_LOOP_DISPATCH_REPO:-}" ]] && repo_flag=(--repo "${MAKATO_LOOP_DISPATCH_REPO}")

  if gh issue edit "$issue" "${repo_flag[@]}" --add-assignee "$ASSIGNEE" >/dev/null 2>&1; then
    echo "loop: assigned #$issue to $ASSIGNEE (board → In progress via project-board-sync.yml)" >&2
  else
    echo "loop: WARN — failed to assign #$issue to $ASSIGNEE (dispatch continues; board Status unchanged)" >&2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _claim_board_card <ISSUE_NUMBER> — synchronous compare-and-set board claim
# (#259). Re-polls the issue's board Status and, only if it is still the
# dispatch Status ("Ready" by default), sets it to "In progress" via
# `gh project item-edit` — making the board the cross-session LOCK, not just
# the queue. See the CLAIM_ON_DISPATCH block at the top of this file for the
# race rationale (async assign→webhook gap between two worktree-local loops).
#
# Exit contract (consumed by cmd_dispatch):
#   0  — claimed (or claim disabled / best-effort fallback): PROCEED to spawn.
#   1  — the card is NOT at the dispatch Status any more (another session
#        already claimed it): SKIP this issue, do NOT spawn.
#
# Best-effort forward-only: any inability to READ the current Status (gh
# outage, missing config, empty board result) logs a WARN and returns 0 —
# degrading to the pre-#259 assign-only path is strictly safer than blocking
# dispatch, and the residual race is exactly today's. A failed WRITE (the
# item-edit itself) also returns 0: we have already observed Ready, so
# proceeding is correct; the async webhook remains the backstop.
#
# Args (via env, mirroring _assign_issue):
#   MAKATO_LOOP_DISPATCH_REPO — owning repo (for the issue URL match).
# Test hooks (offline):
#   MAKATO_LOOP_CLAIM_TEST_FILE       — append "claim #N status=<s> → <verb>"
#       instead of calling `gh`; <verb> ∈ {claimed, skip, warn-proceed}.
#   MAKATO_LOOP_CLAIM_STATUS_OVERRIDE — the fixture current Status the test
#       wants the re-poll to observe (e.g. "Ready", "In progress", "").
# ---------------------------------------------------------------------------
_claim_board_card() {
  local issue="$1"
  # Optional: per-item expected status (from the queue entry). When provided,
  # the CAS compares against this specific status instead of the global default,
  # which is critical for multi-status dispatch ("Ready,Todo") so a Todo item's
  # CAS is not incorrectly compared against "Ready". Falls back to
  # MAKATO_LOOP_ITEM_STATUS (set by cmd_run per queue item), then
  # MAKATO_LOOP_DISPATCH_STATUS / DEFAULT_STATUS for backward compatibility.
  local dispatch_status="${2:-${MAKATO_LOOP_ITEM_STATUS:-${MAKATO_LOOP_DISPATCH_STATUS:-$DEFAULT_STATUS}}}"

  # Disabled → fall straight through to the async assign→webhook path.
  [[ "$CLAIM_ON_DISPATCH" == "1" ]] || return 0

  # Test hook: decide from an injected fixture Status, never touch the network.
  if [[ -n "${MAKATO_LOOP_CLAIM_TEST_FILE:-}" ]]; then
    local cur="${MAKATO_LOOP_CLAIM_STATUS_OVERRIDE-__UNSET__}"
    if [[ "$cur" == "__UNSET__" || -z "$cur" ]]; then
      echo "claim #${issue} status=<unknown> → warn-proceed" >>"$MAKATO_LOOP_CLAIM_TEST_FILE"
      echo "loop: WARN — claim #$issue could not read board Status; proceeding (assign→webhook backstop)" >&2
      return 0
    fi
    if [[ "$cur" == "$dispatch_status" ]]; then
      echo "claim #${issue} status=${cur} → claimed" >>"$MAKATO_LOOP_CLAIM_TEST_FILE"
      echo "loop: claimed #$issue (board $dispatch_status → In progress)" >&2
      # Export the observed status for tier 3/4 label-board conflict gate (#356).
      LOOP_LAST_CLAIMED_STATUS="$cur"
      return 0
    fi
    echo "claim #${issue} status=${cur} → skip" >>"$MAKATO_LOOP_CLAIM_TEST_FILE"
    echo "loop: skip #$issue — board Status is '$cur', not '$dispatch_status' (claimed by another session)" >&2
    return 1
  fi

  # Resolve project coordinates + the In progress option id. Missing config →
  # cannot claim; WARN and proceed (best-effort read-fallback).
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "loop: WARN — claim #$issue skipped: .claude/config.json not found; proceeding (assign→webhook backstop)" >&2
    return 0
  fi
  local status_field_id in_progress_option_id project_node_id host owner number
  status_field_id="$(jq -r '.github_project.fields.status.id // empty' "$CONFIG_FILE")"
  in_progress_option_id="$(jq -r '.github_project.fields.status.options.in_progress // empty' "$CONFIG_FILE")"
  project_node_id="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE")"
  host="$(jq -r '.github_project.host // "github.com"' "$CONFIG_FILE")"
  owner="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE")"
  number="$(jq -r '.github_project.number // empty' "$CONFIG_FILE")"
  if [[ -z "$status_field_id" || -z "$in_progress_option_id" || -z "$project_node_id" || -z "$owner" || -z "$number" ]]; then
    echo "loop: WARN — claim #$issue skipped: status field / in_progress option / project missing in config; proceeding" >&2
    return 0
  fi

  # Re-poll: fetch the board item for this issue (current Status + item id).
  # A single item-list call gives us both, closing the TOCTOU window as far as
  # the API allows. `.content.number` matches the issue; `.status` is the live
  # Status name; `.id` is the project item id item-edit needs. When an offline
  # fixture is injected (MAKATO_LOOP_GH_OVERRIDE, same signal cmd_poll uses),
  # read it instead of calling `gh` — this keeps the DRY_DISPATCH smoke path
  # (T9) offline: it sees the fixture Status and proceeds without a network hit.
  local board item_line cur_status item_id
  if [[ -n "${MAKATO_LOOP_GH_OVERRIDE:-}" ]]; then
    board="$(cat "$MAKATO_LOOP_GH_OVERRIDE" 2>/dev/null || echo '{"items":[]}')"
  else
    # #289: the CAS re-poll goes through the retrying wrapper. If it fails after
    # all retries we must NOT warn-proceed — proceeding on an unreadable board
    # re-opens the pre-#259 double-dispatch race (two sessions each unable to
    # read the card, each falling through to spawn). A failed read is treated as
    # "cannot safely claim → SKIP this tick" (return 1); the issue stays on the
    # queue and a later tick re-attempts the claim once the API recovers.
    if ! board="$(_gh_project_item_list "$host" "$number" "$owner")"; then
      echo "loop: skip #$issue — board re-poll failed (rate-limit/transient); NOT claiming to avoid double-dispatch (#289)" >&2
      return 1
    fi
  fi
  item_line="$(jq -c --argjson i "$issue" \
    'first(.items[] | select(.content.type == "Issue" and .content.number == $i))' \
    <<<"$board" 2>/dev/null || echo "")"
  if [[ -z "$item_line" || "$item_line" == "null" ]]; then
    echo "loop: WARN — claim #$issue could not locate board item on re-poll; proceeding (assign→webhook backstop)" >&2
    return 0
  fi
  cur_status="$(jq -r '.status // empty' <<<"$item_line")"
  item_id="$(jq -r '.id // empty' <<<"$item_line")"

  # CAS: only claim when the card is still at the dispatch Status.
  if [[ "$cur_status" != "$dispatch_status" ]]; then
    echo "loop: skip #$issue — board Status is '${cur_status:-<none>}', not '$dispatch_status' (claimed by another session)" >&2
    return 1
  fi
  if [[ -z "$item_id" ]]; then
    echo "loop: WARN — claim #$issue: board item id unresolved; proceeding (assign→webhook backstop)" >&2
    return 0
  fi

  # Export the CAS-observed Status for the tier 3/4 label-board conflict gate (#356).
  LOOP_LAST_CLAIMED_STATUS="$cur_status"

  # Forward-only write: Ready → In progress. A failed write still proceeds —
  # we already observed Ready, and the async webhook is the backstop.
  if GH_HOST="$host" gh project item-edit --id "$item_id" \
      --project-id "$project_node_id" \
      --field-id "$status_field_id" \
      --single-select-option-id "$in_progress_option_id" >/dev/null 2>&1; then
    echo "loop: claimed #$issue (board $dispatch_status → In progress)" >&2
  else
    echo "loop: WARN — claim #$issue: item-edit failed after observing $dispatch_status; proceeding (assign→webhook backstop)" >&2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _reset_board_card_to_ready <ISSUE_NUMBER> — api_error board recovery (#687).
#
# Called by cmd_dispatch when the child exits rc!=0 and no workflow-state-<N>.json
# was written (session never started — e.g. Stream idle timeout). Moves the board
# card from "In progress" back to "Ready" so the loop retries on the next tick.
#
# Best-effort: any read/write failure logs a WARN and returns 0. Never blocks.
#
# Test hook: MAKATO_LOOP_RESET_BOARD_TEST_FILE — when set, write
#   "reset #N → Ready"  to the file instead of calling gh.
# ---------------------------------------------------------------------------
_reset_board_card_to_ready() {
  local issue="$1"

  # Test hook — offline smoke tests write to this file instead of calling gh.
  if [[ -n "${MAKATO_LOOP_RESET_BOARD_TEST_FILE:-}" ]]; then
    echo "reset #${issue} → Ready" >>"$MAKATO_LOOP_RESET_BOARD_TEST_FILE"
    echo "loop: api-error-reset — #$issue board reset → Ready (test hook)" >&2
    return 0
  fi

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "loop: WARN — api-error-reset #$issue: no config; board card stays In progress" >&2
    return 0
  fi

  local status_field_id ready_option_id project_node_id host owner number
  status_field_id="$(jq -r '.github_project.fields.status.id // empty' "$CONFIG_FILE")"
  ready_option_id="$(jq -r '.github_project.fields.status.options.ready // (.github_project.options.ready // empty)' "$CONFIG_FILE")"
  project_node_id="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE")"
  host="$(jq -r '.github_project.host // "github.com"' "$CONFIG_FILE")"
  owner="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE")"
  number="$(jq -r '.github_project.number // empty' "$CONFIG_FILE")"

  if [[ -z "$status_field_id" || -z "$ready_option_id" || -z "$project_node_id" || -z "$owner" || -z "$number" ]]; then
    echo "loop: WARN — api-error-reset #$issue: missing config fields; board card stays In progress" >&2
    return 0
  fi

  # Re-fetch item_id from board. Cannot reuse _claim_board_card's local item_id.
  # Use _board_via_graphql (cheap, ~1 point) with fallback to item-list.
  local board=""
  local _pid
  _pid="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE" 2>/dev/null)"
  if [[ -n "$_pid" ]]; then
    board="$(_board_via_graphql "$host" "$_pid" 2>/dev/null)" || board=""
  fi
  if [[ -z "$board" ]]; then
    board="$(GH_HOST="$host" gh project item-list "$number" \
      --owner "$owner" --format json --limit "$BOARD_LIMIT" 2>/dev/null)" || board=""
  fi
  if [[ -z "$board" ]]; then
    echo "loop: WARN — api-error-reset #$issue: board poll failed; card stays In progress" >&2
    return 0
  fi

  local item_line item_id cur_status
  item_line="$(jq -c --argjson i "$issue" \
    'first(.items[] | select(.content.type == "Issue" and .content.number == $i))' \
    <<<"$board" 2>/dev/null || echo "")"
  item_id="$(jq -r '.id // empty' <<<"$item_line" 2>/dev/null)"
  cur_status="$(jq -r '.status // empty' <<<"$item_line" 2>/dev/null)"

  if [[ -z "$item_id" ]]; then
    echo "loop: WARN — api-error-reset #$issue: item_id not found; card stays In progress" >&2
    return 0
  fi

  # Status guard: only reset when card is still "In progress".
  # Avoids forward-backward oscillation if reconciler raced ahead.
  if [[ "$cur_status" != "In progress" ]]; then
    echo "loop: api-error-reset #$issue: card is '${cur_status:-<unknown>}', not In progress — skip" >&2
    return 0
  fi

  if GH_HOST="$host" gh project item-edit --id "$item_id" \
      --project-id "$project_node_id" \
      --field-id "$status_field_id" \
      --single-select-option-id "$ready_option_id" >/dev/null 2>&1; then
    echo "loop: api-error-reset — #$issue board reset In progress → Ready (api_error, no workflow-state)" >&2
    # Best-effort JSONL audit to orchestrate.jsonl when found.
    local _spec_dir_reset
    _spec_dir_reset="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
      -name "orchestrate.jsonl" 2>/dev/null | head -1 | xargs -I{} dirname {} 2>/dev/null || true)"
    if [[ -n "$_spec_dir_reset" ]]; then
      local _now_ts
      _now_ts="$(_now)"
      echo "{\"ts\":\"$_now_ts\",\"skill\":\"loop\",\"issue\":$issue,\"step\":\"api-error-board-reset\",\"status\":\"reset\",\"data\":{\"from\":\"In progress\",\"to\":\"Ready\",\"reason\":\"api_error_no_workflow_state\"}}" \
        >>"$_spec_dir_reset/orchestrate.jsonl" 2>/dev/null || true
    fi
  else
    echo "loop: WARN — api-error-reset #$issue: item-edit failed; card stays In progress (reconciler will recover)" >&2
  fi
  return 0
}

# Labels that veto auto-seed promotion / dispatch even when the board Status
# matches. `needs-human-review` is applied on every HALT path; excluding it
# keeps a halted issue off-queue until a human clears the label (#286).
_PROMOTE_EXCLUSION_LABELS="triage experimental status:blocked autonomous:halt needs-human-review needs-reshape"

# ---------------------------------------------------------------------------
# auto-seed — standalone entry point for the pre-poll auto-seed pass.
# Runs _auto_seed_unprepared once and exits.
# (#373, epic #367 S5).
# ---------------------------------------------------------------------------
cmd_auto_seed() {
  _auto_seed_unprepared
}

# ---------------------------------------------------------------------------
# _auto_seed_demote_to_todo — move a board card Ready → Todo (#783).
#
# Called by the T3.5 guard in _auto_seed_candidates for a Ready-but-folderless
# issue (tracked by to-issues, so `_is_orphan_issue` returns 1, but no matching
# specs/<KEY>*/ folder exists). Demoting to Todo takes the card out of the
# dispatchable queue immediately, so the loop advances to the next Ready issue
# instead of re-selecting the folderless one forever (the starvation described
# in #783). On the next auto-seed pass the issue is a genuine unprepared Todo
# candidate that gets seeded and re-promoted.
#
# Mirrors the board-mutation pattern of _reset_board_card_to_ready /
# _auto_seed_block_full, but targets the `todo` Status option.
#
# Best-effort: any read/write failure logs a WARN and returns 0. Never blocks.
#
# Test hook: MAKATO_LOOP_DEMOTE_TEST_FILE — when set, append
#   "demote #N → Todo" to the file instead of calling gh.
# ---------------------------------------------------------------------------
_auto_seed_demote_to_todo() {
  local issue="${1:?issue number required}"

  # Test hook — offline smoke tests write to this file instead of calling gh.
  if [[ -n "${MAKATO_LOOP_DEMOTE_TEST_FILE:-}" ]]; then
    echo "demote #${issue} → Todo" >>"$MAKATO_LOOP_DEMOTE_TEST_FILE"
    echo "loop: auto-seed-demote — #$issue → Todo (test hook)" >&2
    return 0
  fi

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "loop: WARN — auto-seed-demote #$issue: no config; card stays Ready" >&2
    return 0
  fi

  local status_field_id todo_option_id project_node_id host owner number repo
  status_field_id="$(jq -r '.github_project.fields.status.id // empty' "$CONFIG_FILE")"
  todo_option_id="$(jq -r '.github_project.fields.status.options.todo // (.github_project.options.todo // empty)' "$CONFIG_FILE")"
  project_node_id="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE")"
  host="$(jq -r '.github_project.host // "github.com"' "$CONFIG_FILE")"
  owner="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE")"
  number="$(jq -r '.github_project.number // empty' "$CONFIG_FILE")"
  repo="${MAKATO_LOOP_DISPATCH_REPO:-}"

  if [[ -z "$status_field_id" || -z "$todo_option_id" || -z "$project_node_id" || -z "$owner" || -z "$number" ]]; then
    echo "loop: WARN — auto-seed-demote #$issue: missing config fields (need github_project.fields.status.options.todo); card stays Ready" >&2
    return 0
  fi

  # Resolve the board item id (3-step: idempotent item-add → cheap single-issue
  # GraphQL lookup → whole-board item-list fallback), matching _auto_seed_block_full.
  local item_id=""
  if [[ -n "$repo" ]]; then
    item_id="$(GH_HOST="$host" gh project item-add "$number" --owner "$owner" \
      --url "https://github.com/${repo}/issues/$issue" \
      --format json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)"
  fi
  if [[ -z "$item_id" ]]; then
    item_id="$(_project_item_id_for_issue "$host" "$owner" "$repo" "$issue" "$project_node_id" || true)"
  fi
  if [[ -z "$item_id" ]]; then
    item_id="$(GH_HOST="$host" gh project item-list "$number" --owner "$owner" \
      --format json --limit 9999 2>/dev/null \
      | jq -r --argjson i "$issue" '.items[] | select(.content.number == $i) | .id' 2>/dev/null \
      | head -1 || true)"
  fi

  if [[ -z "$item_id" ]]; then
    echo "loop: WARN — auto-seed-demote #$issue: could not resolve board item id; card stays Ready" >&2
    return 0
  fi

  if GH_HOST="$host" gh project item-edit --id "$item_id" \
      --project-id "$project_node_id" \
      --field-id "$status_field_id" \
      --single-select-option-id "$todo_option_id" >/dev/null 2>&1; then
    echo "loop: auto-seed-demote — #$issue board demoted Ready → Todo (folderless; will re-seed)" >&2
  else
    echo "loop: WARN — auto-seed-demote #$issue: board item-edit to Todo failed; card stays Ready" >&2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _auto_seed_candidates — discover open issues that need seeding (not yet on the
# board at the dispatch Status) and classify their plan-tier.
# Returns a JSON array of {number, plan_tier} objects.
# (#369, epic #367 S1).
#
# Test hook:
#   MAKATO_LOOP_AUTOSEED_OVERRIDE — path to a JSON file mimicking
#       `gh issue list --json number,labels,author` output.
# ---------------------------------------------------------------------------
_auto_seed_candidates() {
  local raw candidates
  if [[ -n "${MAKATO_LOOP_AUTOSEED_OVERRIDE:-}" ]]; then
    raw="$(cat "$MAKATO_LOOP_AUTOSEED_OVERRIDE" 2>/dev/null || echo '[]')"
  else
    local -a repo_flag=()
    [[ -n "${MAKATO_LOOP_DISPATCH_REPO:-}" ]] && repo_flag=(--repo "${MAKATO_LOOP_DISPATCH_REPO}")
    raw="$(gh issue list "${repo_flag[@]}" \
      --state open --json number,labels,author --limit 200 2>/dev/null || echo '[]')"
  fi
  [[ -n "$raw" ]] || raw='[]'

  # Start with all open issues; board-Ready exclusion is applied per-candidate
  # in T3.5 via _is_orphan_issue / board status checks below.
  local candidates="$raw"
  [[ -n "$candidates" ]] || candidates='[]'

  # Iterate per candidate, apply T2 exclusion labels, T3 bot veto, T4 plan-tier
  local result='[]'
  local n labels author_login excluded lbl plan_tier
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue

    labels="$(jq -r --argjson i "$n" \
      '.[] | select(.number == $i) | [.labels[].name] | join(" ")' \
      <<<"$candidates" 2>/dev/null || echo "")"
    author_login="$(jq -r --argjson i "$n" \
      '.[] | select(.number == $i) | .author.login // ""' \
      <<<"$candidates" 2>/dev/null || echo "")"

    # T2: Exclusion guard — reuse _PROMOTE_EXCLUSION_LABELS verbatim.
    excluded=""
    for lbl in $_PROMOTE_EXCLUSION_LABELS; do
      if [[ " $labels " == *" $lbl "* ]]; then excluded="$lbl"; break; fi
    done
    if [[ -n "$excluded" ]]; then
      echo "loop: auto-seed — skip #$n (exclusion label: $excluded)" >&2
      continue
    fi

    # T3: dependencies label veto.
    if [[ " $labels " == *" dependencies "* ]]; then
      echo "loop: auto-seed — skip #$n (dependencies label)" >&2
      continue
    fi

    # T3: bot-author veto — any GitHub App / bot account (login ends in
    # "[bot]": renovate[bot], dependabot[bot], and future bots). Bot-filed
    # issues (Renovate Dependency Dashboard #346, Dependabot alerts) are
    # never human-shaped work and must never enter the auto-seed queue.
    if [[ "$author_login" == *"[bot]" ]]; then
      echo "loop: auto-seed — skip #$n (bot author: $author_login)" >&2
      continue
    fi

    # T3.5: already-planned veto (#499/#510 shared-folder gap; incident #347).
    # An issue that came through `to-issues` is recorded in a specs/<slug>/
    # created-issues.json, and its buildable plan already lives at
    # specs/<slug>/plan-<n>.md. Re-seeding it would spawn a SECOND spec folder
    # (seed-issue's <n>-<title> convention) holding a hollow stub plan.md,
    # producing two competing "plans" for one issue — the exact class of
    # collision that makes the po-agent look in the wrong folder and report
    # "plan not found" (or HALT-006) even though a real plan exists. #571 fixed
    # the auto-seed-BLOCK arm for this; this closes the auto-seed candidate
    # arm. `_is_orphan_issue` returns 1 (not orphan) precisely when a valid
    # created-issues.json references this number, so a non-orphan is
    # already-planned and belongs to the board-Ready queue, not seeding.
    if ! _is_orphan_issue "$n"; then
      # #783: an already-planned (non-orphan) issue that is ALSO folderless
      # starves the dispatch queue — the cmd_dispatch spec-folder gate bounces
      # it to auto-seed every tick, but the old `continue` here silently skipped
      # it, so the folder never materialized and the same issue was re-selected
      # forever (blocking everything behind it). Detect the folderless case and
      # demote the card Ready → Todo so it exits the dispatchable queue; the next
      # auto-seed pass then treats it as a genuine unprepared candidate. When a
      # folder DOES exist (the normal already-planned path), behaviour is
      # unchanged. KEY-derivation failure → skip demotion, continue silently
      # (the gate WARN fires on the next dispatch attempt, no regression).
      local n_key=""
      n_key="$(_derive_key_for_issue "$n" "${MAKATO_LOOP_DISPATCH_REPO:-}" 2>/dev/null || true)"
      if [[ -n "$n_key" ]] && ! _spec_folder_for_key "$n_key" >/dev/null 2>&1; then
        echo "loop: auto-seed — #$n Ready-but-folderless (KEY='$n_key'); demoting to Todo for re-seed (#783)" >&2
        _auto_seed_demote_to_todo "$n" || true
      else
        echo "loop: auto-seed — skip #$n (already planned by to-issues — in created-issues.json)" >&2
      fi
      continue
    fi

    # T4: Classify plan-tier from labels.
    plan_tier="$(jq -r --argjson i "$n" \
      '.[] | select(.number == $i) | [.labels[].name] | .[] | select(startswith("plan-tier:"))' \
      <<<"$candidates" 2>/dev/null | head -1 | sed 's/plan-tier://' || echo "")"
    [[ -n "$plan_tier" ]] || plan_tier=""

    result="$(jq --argjson n "$n" --arg t "$plan_tier" \
      '. + [{"number": $n, "plan_tier": $t}]' \
      <<<"$result" 2>/dev/null || echo "$result")"
  done < <(jq -r '.[].number' <<<"$candidates" 2>/dev/null)

  printf '%s\n' "$result"
  return 0
}

# ---------------------------------------------------------------------------
# _auto_seed_dispatch_light — light-tier arm of the auto-seed routing.
# (#370, epic #367 S2).
#
# Accepts a single candidate's issue number and its classified plan_tier.
# When plan_tier == "light", dispatches seed-issue headlessly via the same
# `MAKATO_HEADLESS=1 claude -p` mechanism cmd_dispatch uses (loop.sh:1959).
# Non-light candidates are skipped with a deferral log and no dispatch.
#
# Exit codes:
#   0 — seed dispatched successfully (or candidate skipped as non-light)
#   1 — seed dispatch attempted but failed (non-fatal; caller continues)
#
# Test hook:
#   MAKATO_LOOP_SEED_TEST_CMD — when set, runs its value as the spawn command
#       instead of the real `claude -p`. Mirrors child_cmd in cmd_dispatch.
#       The stub receives the same env (MAKATO_HEADLESS=1,
#       CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0, ISSUE_NUMBER, REPO,
#       REPO_ROOT) and prompt as the real invocation.
# ---------------------------------------------------------------------------
_auto_seed_dispatch_light() {
  local issue="${1:?issue number required}"
  local plan_tier="${2:-}"

  # Non-light candidates: skip, defer to S4 (#372).
  if [[ "$plan_tier" != "light" ]]; then
    echo "loop: auto-seed — skip #$issue (plan-tier '$plan_tier' not light — deferred to S4)" >&2
    return 0
  fi

  echo "loop: auto-seed — dispatching seed-issue for #$issue (plan-tier:light)" >&2

  local repo="${MAKATO_LOOP_DISPATCH_REPO:-}"
  local dispatch_prompt
  dispatch_prompt="Use the Skill tool to invoke the makato-orchestrate:seed-issue skill with args '${issue} --type new-work'. Required env: ISSUE_NUMBER=${issue} REPO=${repo} REPO_ROOT=${REPO_ROOT}. MAKATO_HEADLESS=1 is already exported. Return R1 envelope verbatim."

  local rc=0
  if [[ -n "${MAKATO_LOOP_SEED_TEST_CMD:-}" ]]; then
    # Test-hook path: run the stub command instead of the real claude -p.
    # The stub receives the same env so the smoke suite can assert it.
    MAKATO_HEADLESS=1 \
    CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
    ISSUE_NUMBER="$issue" \
    REPO="$repo" \
    REPO_ROOT="$REPO_ROOT" \
      ${MAKATO_LOOP_SEED_TEST_CMD} -p "$dispatch_prompt" >/dev/null 2>&1 || rc=$?
  else
    # Production path: mirror the belt-and-braces invocation cmd_dispatch uses.
    CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
    MAKATO_HEADLESS=1 \
    ISSUE_NUMBER="$issue" \
    REPO="$repo" \
    REPO_ROOT="$REPO_ROOT" \
      "$CLAUDE_BIN" --dangerously-skip-permissions \
      -p "$dispatch_prompt" >/dev/null 2>&1 || rc=$?
  fi

  if [[ "$rc" -ne 0 ]]; then
    echo "loop: WARN — auto-seed seed dispatch for #$issue failed (rc=$rc); tick continues" >&2
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# _auto_seed_reconcile_thin_body — terminal-state reconciliation after a
# light-tier seed-issue dispatch (S3, epic #367, #371).
#
# Accepts a seeded issue number and an optional spec-key (slug) for the seeded
# issue. After _auto_seed_dispatch_light dispatches seed-issue for a
# plan-tier:light candidate, the light-planner agent may refuse a thin body:
# seed-issue Step 8.5c then writes NO plan, re-tiers the issue light → full,
# and strips status:ready-for-dev.  The loop must NOT treat the refused issue
# as dispatchable; this helper detects the thin-body outcome and reconciles
# the loop's view.
#
# Detection order:
#   1. (Primary signal) orchestrate.jsonl — reads
#      specs/<seed_key>/orchestrate.jsonl and greps the light-plan line for
#      data.thin_body == true or guard == "invalid".
#   2. (Backstop) label state — re-fetches the issue labels; treats as
#      thin-body when plan-tier:full is present AND status:ready-for-dev is
#      absent (exact post-state Step 8.5c leaves).
#
# On a thin-body verdict:
#   - Applies needs-human-review (idempotent — create if absent, skip if
#     already present).
#   - Does NOT touch the board (card stays at Todo).
#   - Emits a loop message naming the issue.
#   - Returns exit code 2 (thin-body — caller must not dispatch).
#
# On a non-thin (successful) seed:
#   - Returns 0 (no-op — dispatch proceeds normally).
#
# Exit codes:
#   0  — not thin-body; dispatch proceeds
#   2  — thin-body detected; caller must not dispatch this issue
#
# Args:
#   $1  issue number
#   $2  seed_key (optional) — the slug derived from seed-issue for locating
#       orchestrate.jsonl (e.g. "371-thin-body-terminal-reconciliation").
#       When empty, the jsonl signal is skipped and only the label backstop
#       applies.
#
# Test hooks (offline):
#   MAKATO_LOOP_RECONCILE_JSONL_DIR — override SPECS_DIR root for locating
#       orchestrate.jsonl files.  Tests redirect to a temp directory.
#   MAKATO_LOOP_RECONCILE_LABEL_FILE — path to a newline-separated list of
#       label names used as the issue's current labels instead of calling
#       `gh issue view --json labels`.
#   MAKATO_LOOP_LABEL_TEST_FILE — reused convention: append
#       "label #N needs-human-review" instead of calling `gh issue edit`.
# ---------------------------------------------------------------------------
_auto_seed_reconcile_thin_body() {
  local issue="${1:?issue number required}"
  local seed_key="${2:-}"

  local repo="${MAKATO_LOOP_DISPATCH_REPO:-}"
  local -a repo_flag=()
  [[ -n "$repo" ]] && repo_flag=(--repo "$repo")

  # --- Signal 1: orchestrate.jsonl (primary) ---
  local thin_body_detected=""
  if [[ -n "$seed_key" ]]; then
    local jsonl_root="${MAKATO_LOOP_RECONCILE_JSONL_DIR:-$SPECS_DIR}"
    local jsonl_path="${jsonl_root}/${seed_key}/orchestrate.jsonl"
    if [[ -f "$jsonl_path" && -s "$jsonl_path" ]]; then
      # Grep for the light-plan line: data.thin_body == true or guard == "invalid".
      # A line matches when jq can parse it AND either condition holds.
      while IFS= read -r line; do
        local _tb _guard
        _tb="$(printf '%s' "$line" | jq -r '.data.thin_body // empty' 2>/dev/null || true)"
        _guard="$(printf '%s' "$line" | jq -r '.data.guard // empty' 2>/dev/null || true)"
        if [[ "$_tb" == "true" || "$_guard" == "invalid" ]]; then
          thin_body_detected="jsonl"
          break
        fi
      done <"$jsonl_path"
    fi
    # Missing or empty jsonl: fall through — no error.
  fi

  # --- No thin-body verdict: return 0, dispatch proceeds ---
  if [[ -z "$thin_body_detected" ]]; then
    return 0
  fi

  # --- Thin-body verdict: apply needs-human-review, leave at Todo ---
  echo "loop: auto-seed — #${issue} thin-body, left at Todo + needs-human-review (not dispatched) [signal=${thin_body_detected}]" >&2

  if [[ -n "${MAKATO_LOOP_LABEL_TEST_FILE:-}" ]]; then
    # Test hook: record label action to file instead of calling gh.
    echo "label #${issue} needs-human-review" >>"$MAKATO_LOOP_LABEL_TEST_FILE"
    _post_halt_comment "HALT-006" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
  else
    # Production path: create label if absent, then add idempotently.
    if ! gh label list "${repo_flag[@]}" 2>/dev/null | grep -q "^needs-human-review"; then
      gh label create "needs-human-review" "${repo_flag[@]}" \
        --color "d93f0b" --description "Requires human review before autonomous dispatch" \
        >/dev/null 2>&1 || true
    fi
    if gh issue edit "$issue" "${repo_flag[@]}" \
        --add-label "needs-human-review" >/dev/null 2>&1; then
      echo "loop: auto-seed-reconcile — applied 'needs-human-review' label to #$issue" >&2
    else
      echo "loop: WARN — auto-seed-reconcile #$issue: could not apply needs-human-review label" >&2
    fi
    _post_halt_comment "HALT-006" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
  fi

  # Exit code 2 = thin-body; caller must not dispatch.
  return 2
}

# ---------------------------------------------------------------------------
# _auto_seed_block_full — full/untiered arm of the auto-seed routing.
# (#372, epic #367 S4).
#
# Accepts a single candidate's issue number and its classified plan_tier.
# When plan_tier is "full", "change", or empty (untiered), performs three
# best-effort actions:
#   1. Prepare a minimal specs/<slug>/ spec folder (plan.md stub +
#      seed-manifest.json, byte-for-byte matching seed-issue Step 8's format).
#      Idempotent: if the folder already exists, logs and skips folder creation.
#   2. Move the board card to Blocked. Resolves status_field_id and
#      options.blocked from .claude/config.json. Finds or adds the board item
#      (mirrors seed-issue's item-add / item-list fallback).
#      Also applies the `needs-human-review` label (creates if absent,
#      idempotent).
#   3. Post a sentinel-guarded launch-command comment. Before posting, checks
#      whether any existing issue comment already contains the sentinel
#      `<!-- makato:auto-seed-block:full -->`. If present, skips posting. If
#      absent, posts a comment with the sentinel and the exact full-planning
#      launch command for this issue.
#
# When plan_tier is "light", returns 0 immediately (no-op — S2 owns it).
#
# Exit codes:
#   0 — all applicable steps executed (or skipped as idempotent / no-op)
#   1 — one or more steps failed in a non-recoverable way
#
# All three steps are best-effort: a failure logs a WARN and continues to
# the next step; the function returns 1 only when ALL three steps fail.
#
# Test hooks (offline):
#   MAKATO_LOOP_BLOCK_TEST_FILE     — append "block #N" instead of calling
#       `gh project item-edit` to set Blocked. Offline substitute.
#   MAKATO_LOOP_LABEL_TEST_FILE     — append "label #N needs-human-review"
#       instead of calling `gh issue edit --add-label`.
#   MAKATO_LOOP_COMMENT_TEST_FILE   — append the full comment body instead of
#       calling `gh issue comment`.
#   MAKATO_LOOP_COMMENTS_OVERRIDE   — path to a JSON array of
#       `[{"body":"..."},...]` used as existing issue comments in place of
#       `gh issue view --json comments`. Keeps sentinel-detection offline.
#   MAKATO_LOOP_AUTOSEED_SPEC_ROOT  — override SPECS_DIR for the spec-stub
#       creation step (tests redirect to a temp directory).
#   MAKATO_LOOP_ISSUE_TITLE_OVERRIDE — reused from _derive_key_for_issue to
#       derive the slug without a `gh issue view` call.
#   MAKATO_LOOP_RECONCILE_LABEL_FILE — path to a newline-separated list of
#       label names used as the issue's current labels instead of calling
#       `gh issue view --json labels`. Offline substitute for label fetch.
#   MAKATO_LOOP_PROMOTE_TEST_FILE    — append "promote #N → Ready" instead of
#       calling `gh project item-edit` to set Ready. Offline substitute.
#   MAKATO_LOOP_PARK_LABELS          — comma-separated label names that mark an
#       operator-parked issue (default "priority:hold"). An issue with any of
#       these is skipped for Ready promotion (#721, FM-LABEL-PARK).
#   MAKATO_SPEC_STORIES_TRACKED      — forwarded to should-materialize-spec.sh:
#       1=force tracked, 0=force untracked (keeps tests offline, no git probe).
# ---------------------------------------------------------------------------
_auto_seed_promote_ready_from_gate() {
  local issue="${1:?issue number required}"

  local repo="${MAKATO_LOOP_DISPATCH_REPO:-}"
  local -a repo_flag=()
  [[ -n "$repo" ]] && repo_flag=(--repo "$repo")

  # --- Step A: park-label guard (#721, FM-LABEL-PARK) ---
  # MAKATO_LOOP_PARK_LABELS: comma-separated label names marking an
  # operator-parked issue (default "priority:hold"). An issue carrying any of
  # them is NOT promoted to Ready — the operator parked it deliberately, and a
  # silent auto-promote would override that. Checked BEFORE any board mutation
  # so the offline MAKATO_LOOP_PROMOTE_TEST_FILE path observes the skip too.
  # Offline label source: MAKATO_LOOP_RECONCILE_LABEL_FILE (newline-separated),
  # else `gh issue view --json labels`.
  local park_labels="${MAKATO_LOOP_PARK_LABELS:-priority:hold}"
  local issue_labels=""
  if [[ -n "${MAKATO_LOOP_RECONCILE_LABEL_FILE:-}" && -f "${MAKATO_LOOP_RECONCILE_LABEL_FILE}" ]]; then
    issue_labels="$(tr '\n' ',' <"$MAKATO_LOOP_RECONCILE_LABEL_FILE" 2>/dev/null || echo "")"
  else
    issue_labels="$(gh issue view "$issue" "${repo_flag[@]}" --json labels \
      --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")"
  fi
  local _pl_ifs_save="$IFS"; IFS=","
  local pl
  for pl in $park_labels; do
    IFS="$_pl_ifs_save"
    # trim surrounding whitespace
    pl="${pl#"${pl%%[![:space:]]*}"}"; pl="${pl%"${pl##*[![:space:]]}"}"
    [[ -n "$pl" ]] || { IFS=","; continue; }
    if printf '%s' "$issue_labels" | tr ',' '\n' | grep -qxF "$pl"; then
      echo "loop: auto-seed-block — skip promote #$issue (label '$pl' matches MAKATO_LOOP_PARK_LABELS; operator-parked)" >&2
      return 0
    fi
    IFS=","
  done
  IFS="$_pl_ifs_save"

  # --- Step B: Move board card to Ready ---
  if [[ -n "${MAKATO_LOOP_PROMOTE_TEST_FILE:-}" ]]; then
    echo "promote #${issue} → Ready" >>"$MAKATO_LOOP_PROMOTE_TEST_FILE"
  else
    if [[ -f "$CONFIG_FILE" ]]; then
      local status_field_id ready_option_id project_node_id host owner number
      status_field_id="$(jq -r '.github_project.fields.status.id // empty' "$CONFIG_FILE")"
      ready_option_id="$(jq -r '.github_project.fields.status.options.ready // (.github_project.options.ready // empty)' "$CONFIG_FILE")"
      project_node_id="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE")"
      host="$(jq -r '.github_project.host // "github.com"' "$CONFIG_FILE")"
      owner="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE")"
      number="$(jq -r '.github_project.number // empty' "$CONFIG_FILE")"

      if [[ -n "$status_field_id" && -n "$ready_option_id" && -n "$project_node_id" && -n "$owner" && -n "$number" ]]; then
        local item_id=""
        item_id="$(GH_HOST="$host" gh project item-add "$number" --owner "$owner" \
          --url "https://github.com/${repo}/issues/$issue" \
          --format json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)"
        if [[ -z "$item_id" ]]; then
          # Cheap single-issue lookup (~1 GraphQL point) before the expensive
          # whole-board item-list fallback.
          item_id="$(_project_item_id_for_issue "$host" "$owner" "$repo" "$issue" "$project_node_id" || true)"
        fi
        if [[ -z "$item_id" ]]; then
          item_id="$(GH_HOST="$host" gh project item-list "$number" --owner "$owner" \
            --format json --limit 9999 2>/dev/null \
            | jq -r --argjson i "$issue" '.items[] | select(.content.number == $i) | .id' 2>/dev/null \
            | head -1 || true)"
        fi
        if [[ -n "$item_id" ]]; then
          if GH_HOST="$host" gh project item-edit --id "$item_id" \
              --project-id "$project_node_id" \
              --field-id "$status_field_id" \
              --single-select-option-id "$ready_option_id" >/dev/null 2>&1; then
            echo "loop: auto-seed-block — set #$issue → Ready on board (materialize-refine)" >&2
          else
            echo "loop: WARN — auto-seed-block #$issue: board item-edit to Ready failed" >&2
          fi
        else
          echo "loop: WARN — auto-seed-block #$issue: could not resolve board item id for Ready move" >&2
        fi
      else
        echo "loop: WARN — auto-seed-block #$issue: missing config fields for board Ready move" >&2
      fi
    else
      echo "loop: WARN — auto-seed-block #$issue: .claude/config.json not found; skipping Ready move" >&2
    fi
  fi
}
_auto_seed_block_full() {
  local issue="${1:?issue number required}"
  local plan_tier="${2:-}"

  # Light-tier candidates: no-op (S2 owns them).
  if [[ "$plan_tier" == "light" ]]; then
    echo "loop: auto-seed-block — skip #$issue (plan-tier:light — S2 owns it)" >&2
    return 0
  fi

  # Change-tier candidates: no-op (makato-change:orchestrate owns them).
  if [[ "$plan_tier" == "change" ]]; then
    echo "loop: auto-seed-block — skip #$issue (plan-tier:change — change-orchestrate owns it)" >&2
    return 0
  fi

  echo "loop: auto-seed-block — processing #$issue (plan-tier '${plan_tier:-untiered}')" >&2

  local repo="${MAKATO_LOOP_DISPATCH_REPO:-}"
  local -a repo_flag=()
  [[ -n "$repo" ]] && repo_flag=(--repo "$repo")

  # --- Step 1: Derive slug and prepare spec-folder stub ---
  # Delegate to _derive_key_for_issue so to-issues footer KEY (primary) and
  # specs/<slug>/stories.json provenance (secondary) take precedence over the
  # title-slug fallback. This prevents false-positive Blocked on issues whose
  # plan lives in a shared feature folder (e.g. plan-342.md under
  # specs/platform-core-phase-2-admin-console/).
  local slug=""
  slug="$(_derive_key_for_issue "$issue" "${repo:-}" 2>/dev/null || true)"

  # Title-slug fallback (restores pre-#571 behaviour): _derive_key_for_issue
  # returns empty when the issue body is empty/unfetchable (its title fallback
  # is unreachable past the body-required guard). A hand-filed issue with no
  # to-issues provenance still needs a <issue>-<title-slug> spec stub, so
  # re-derive from the title here — matching seed-issue Step 4 normalization.
  if [[ -z "$slug" ]]; then
    local title=""
    if [[ -n "${MAKATO_LOOP_ISSUE_TITLE_OVERRIDE:-}" ]]; then
      title="$MAKATO_LOOP_ISSUE_TITLE_OVERRIDE"
    else
      title="$(gh issue view "$issue" "${repo_flag[@]}" --json title \
        --jq '.title' 2>/dev/null)" || true
    fi
    if [[ -n "$title" ]]; then
      local norm
      norm="$(printf '%s' "$title" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
      norm="$(_slug_truncate_wb "$norm")"
      [[ -n "$norm" ]] && slug="${issue}-${norm}"
    fi
  fi

  if [[ -z "$slug" ]]; then
    slug="${issue}"
    echo "loop: WARN — auto-seed-block #$issue could not derive slug; using bare issue number" >&2
  fi

  local spec_root="${MAKATO_LOOP_AUTOSEED_SPEC_ROOT:-$SPECS_DIR}"
  local spec_dir="$spec_root/$slug"

  # Stub creation is intentionally skipped when _derive_key_for_issue returned a
  # footer KEY that resolves to an existing shared spec folder (e.g. a to-issues
  # feature folder containing plan-<N>.md). The existing guard below handles this.
  if [[ -d "$spec_dir" ]]; then
    echo "loop: auto-seed-block — specs/$slug/ already exists — skipping folder creation" >&2
  else
    mkdir -p "$spec_dir" 2>/dev/null || {
      echo "loop: WARN — auto-seed-block #$issue: could not create spec dir $spec_dir" >&2
    }
    if [[ -d "$spec_dir" ]]; then
      local now_iso
      now_iso="$(_now)"

      # plan.md stub (mirrors seed-issue Step 8 format exactly).
      printf '# Plan: %s\n\n> Auto-seeded by seed-issue v1.2.0 on %s. Replace this stub with a\n> full plan before the PO-agent starts.\n\n## Issue\n\n[#%s](https://github.com/%s/issues/%s)\n\n## Acceptance criteria\n\n_To be filled in. The PO-agent will HALT with HALT-006 (MISSING_SPEC) if\nthis file contains only the stub text above._\n' \
        "#${issue}" "$now_iso" "$issue" "${repo:-unknown/repo}" "$issue" \
        >"$spec_dir/plan.md" 2>/dev/null || true

      # seed-manifest.json (schema_version 2, same as seed-issue).
      jq -n \
        --arg seeded_at "$now_iso" \
        --argjson issue_num "$issue" \
        --arg issue_title "" \
        --arg slug "$slug" \
        --arg repo "${repo:-}" \
        '{
          schema_version: "2",
          seeded_at: $seeded_at,
          seeded_by: "seed-issue",
          skill_version: "1.2.0",
          issue_number: $issue_num,
          issue_title: $issue_title,
          slug: $slug,
          repo: $repo,
          type: "new-work"
        }' >"$spec_dir/seed-manifest.json" 2>/dev/null || true

      echo "loop: auto-seed-block — created specs/$slug/ with plan.md stub and seed-manifest.json (schema_version 2)" >&2
    fi
  fi

  # --- Gate: consult should-materialize-spec.sh before blocking (#533) ---
  # When the issue has a committed stories.json the PO-agent's Step 1a gate
  # can materialize the plan autonomously via build-refine. Blocking in that
  # case contradicts the PO-agent — promote to Ready instead.
  local materialize_sh
  materialize_sh="$(dirname "$0")/should-materialize-spec.sh"

  local labels_raw=""
  if [[ -n "${MAKATO_LOOP_RECONCILE_LABEL_FILE:-}" ]]; then
    labels_raw="$(cat "${MAKATO_LOOP_RECONCILE_LABEL_FILE}" 2>/dev/null || true)"
  else
    labels_raw="$(gh issue view "$issue" "${repo_flag[@]}" \
      --json labels --jq '[.labels[].name] | .[]' 2>/dev/null || true)"
  fi
  local -a labels_arr=()
  while IFS= read -r lbl; do [[ -n "$lbl" ]] && labels_arr+=("$lbl"); done <<<"$labels_raw"

  local gate_out="" gate_verdict="halt"
  if [[ -f "$materialize_sh" ]]; then
    # For to-issues shared folders the real plan is plan-<N>.md, not plan.md.
    # Prefer the issue-specific plan file when it exists so the gate sees a
    # valid plan and emits 'proceed plan-valid' rather than 'halt'.
    local plan_file="$spec_dir/plan.md"
    if [[ ! -f "$plan_file" && -f "$spec_dir/plan-${issue}.md" ]]; then
      plan_file="$spec_dir/plan-${issue}.md"
    fi
    gate_out="$(bash "$materialize_sh" "$plan_file" "${labels_arr[@]}" 2>/dev/null || true)"
    gate_verdict="${gate_out%% *}"
  else
    echo "loop: WARN — auto-seed-block #$issue: should-materialize-spec.sh not found; defaulting to block" >&2
  fi

  if [[ "$gate_verdict" == "materialize-refine" ]]; then
    echo "loop: auto-seed-block — #$issue materialize-refine verdict; promoting to Ready (skipping block)" >&2
    _auto_seed_promote_ready_from_gate "$issue"
    return 0
  fi

  # A 'proceed' verdict means the gate saw a valid, committed plan (plan.md or
  # the issue-specific plan-<N>.md in a to-issues shared feature folder). This
  # is the #571 fix: a full-tier issue whose real plan lives at plan-<N>.md
  # under specs/<footer-KEY>/ must NOT be false-positive Blocked. Promote to
  # Ready instead of blocking.
  if [[ "$gate_verdict" == "proceed" ]]; then
    echo "loop: auto-seed-block — #$issue gate verdict 'proceed' (valid committed plan); promoting to Ready (skipping block)" >&2
    _auto_seed_promote_ready_from_gate "$issue"
    return 0
  fi

  # --- Step 2: Move board card to Blocked + apply needs-human-review label ---

  # Test hook for the block (item-edit) step.
  if [[ -n "${MAKATO_LOOP_BLOCK_TEST_FILE:-}" ]]; then
    echo "block #${issue} plan_tier=${plan_tier:-untiered} → Blocked" \
      >>"$MAKATO_LOOP_BLOCK_TEST_FILE"
  else
    # Production path: resolve project config + item id, set Blocked.
    if [[ -f "$CONFIG_FILE" ]]; then
      local status_field_id blocked_option_id project_node_id host owner number
      status_field_id="$(jq -r '.github_project.fields.status.id // empty' "$CONFIG_FILE")"
      blocked_option_id="$(jq -r '.github_project.fields.status.options.blocked // (.github_project.options.blocked // empty)' "$CONFIG_FILE")"
      project_node_id="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE")"
      host="$(jq -r '.github_project.host // "github.com"' "$CONFIG_FILE")"
      owner="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE")"
      number="$(jq -r '.github_project.number // empty' "$CONFIG_FILE")"

      if [[ -n "$status_field_id" && -n "$blocked_option_id" && -n "$project_node_id" && -n "$owner" && -n "$number" ]]; then
        # Find or add the board item (mirrors seed-issue's item-add path).
        local item_id=""
        item_id="$(GH_HOST="$host" gh project item-add "$number" --owner "$owner" \
          --url "https://github.com/${repo}/issues/$issue" \
          --format json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)"
        if [[ -z "$item_id" ]]; then
          # Cheap single-issue lookup (~1 GraphQL point) before the expensive
          # whole-board item-list fallback.
          item_id="$(_project_item_id_for_issue "$host" "$owner" "$repo" "$issue" "$project_node_id" || true)"
        fi
        if [[ -z "$item_id" ]]; then
          item_id="$(GH_HOST="$host" gh project item-list "$number" --owner "$owner" \
            --format json --limit 9999 2>/dev/null \
            | jq -r --argjson i "$issue" '.items[] | select(.content.number == $i) | .id' 2>/dev/null \
            | head -1 || true)"
        fi
        if [[ -n "$item_id" ]]; then
          if GH_HOST="$host" gh project item-edit --id "$item_id" \
              --project-id "$project_node_id" \
              --field-id "$status_field_id" \
              --single-select-option-id "$blocked_option_id" >/dev/null 2>&1; then
            echo "loop: auto-seed-block — set #$issue → Blocked on board" >&2
          else
            echo "loop: WARN — auto-seed-block #$issue: board item-edit to Blocked failed" >&2
          fi
        else
          echo "loop: WARN — auto-seed-block #$issue: could not resolve board item id" >&2
        fi
      else
        echo "loop: WARN — auto-seed-block #$issue: missing config fields for board Blocked move" >&2
      fi
    else
      echo "loop: WARN — auto-seed-block #$issue: .claude/config.json not found; skipping board move" >&2
    fi
  fi

  # Apply needs-human-review label (idempotent, create if absent).
  if [[ -n "${MAKATO_LOOP_LABEL_TEST_FILE:-}" ]]; then
    echo "label #${issue} needs-human-review" >>"$MAKATO_LOOP_LABEL_TEST_FILE"
    _post_halt_comment "HALT-006" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
  else
    if gh label list "${repo_flag[@]}" 2>/dev/null | grep -q "^needs-human-review"; then
      : # label exists
    else
      gh label create "needs-human-review" "${repo_flag[@]}" \
        --color "d93f0b" --description "Requires human review before autonomous dispatch" \
        >/dev/null 2>&1 || true
    fi
    if gh issue edit "$issue" "${repo_flag[@]}" \
        --add-label "needs-human-review" >/dev/null 2>&1; then
      echo "loop: auto-seed-block — applied 'needs-human-review' label to #$issue" >&2
    else
      echo "loop: WARN — auto-seed-block #$issue: could not apply needs-human-review label" >&2
    fi
    _post_halt_comment "HALT-006" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
  fi

  # --- Step 3: Post sentinel-guarded launch-command comment ---
  local SENTINEL="<!-- makato:auto-seed-block:full -->"

  # Check for existing sentinel in issue comments.
  local existing_comments=""
  if [[ -n "${MAKATO_LOOP_COMMENTS_OVERRIDE:-}" ]]; then
    existing_comments="$(cat "$MAKATO_LOOP_COMMENTS_OVERRIDE" 2>/dev/null || echo '[]')"
  else
    existing_comments="$(gh issue view "$issue" "${repo_flag[@]}" \
      --json comments --jq '.comments' 2>/dev/null || echo '[]')"
  fi

  local sentinel_found=""
  sentinel_found="$(printf '%s' "$existing_comments" \
    | jq -r '.[].body' 2>/dev/null \
    | grep -F "$SENTINEL" | head -1 || true)"

  if [[ -n "$sentinel_found" ]]; then
    echo "loop: auto-seed-block — sentinel already present on #$issue; skipping comment" >&2
  else
    # Build the launch command: seed-issue skill with new-work type.
    local launch_cmd
    if [[ -n "$repo" ]]; then
      launch_cmd="/seed-issue ${issue} --type new-work  (or: claude code and invoke makato-orchestrate:seed-issue skill with args '${issue} --type new-work', repo=${repo})"
    else
      launch_cmd="/seed-issue ${issue} --type new-work  (or: claude code and invoke makato-orchestrate:seed-issue skill with args '${issue} --type new-work')"
    fi

    local comment_body
    comment_body="${SENTINEL}
This issue carries \`plan-tier:full\` (or no plan-tier label) and does not have a committed \`stories.json\` — the full makato-plan pipeline is needed before autonomous dispatch.

**To make this issue dispatchable without manual board action**, relabel it \`plan-tier:light\`: the auto-seed pass then dispatches \`seed-issue\` headlessly, the light-planner generates \`plan-<N>.md\`, and \`seed-issue\` moves the board card to **Status=Ready** on its own. Otherwise, run \`seed-issue\` yourself to generate a full \`plan.md\`:

\`\`\`
${launch_cmd}
\`\`\`

Once a valid \`plan.md\` exists, \`seed-issue\` moves the board card to **Status=Ready** — the sole dispatch signal — and the loop picks it up automatically. (The former \`status:ready-for-dev\` label bridge was removed in #688.)

_This comment was posted automatically by the makato auto-seed pass (#372)._"

    if [[ -n "${MAKATO_LOOP_COMMENT_TEST_FILE:-}" ]]; then
      echo "comment #${issue} sentinel=${SENTINEL}" >>"$MAKATO_LOOP_COMMENT_TEST_FILE"
      printf '%s\n' "$comment_body" >>"$MAKATO_LOOP_COMMENT_TEST_FILE"
    else
      if gh issue comment "$issue" "${repo_flag[@]}" \
          --body "$comment_body" >/dev/null 2>&1; then
        echo "loop: auto-seed-block — posted launch-command comment on #$issue" >&2
      else
        echo "loop: WARN — auto-seed-block #$issue: could not post launch-command comment" >&2
      fi
    fi
  fi

  return 0
}

# ---------------------------------------------------------------------------
# _auto_seed_unprepared — composing pass that seeds or blocks every open issue
# that is not yet status:ready-for-dev. (#373, epic #367 S5).
#
# Calls _auto_seed_candidates() to obtain a JSON array of
# {number, plan_tier} objects, then routes each candidate:
#
#   plan_tier == "light"                → S2: _auto_seed_dispatch_light
#                                          If the dispatch succeeds (rc=0),
#                                          runs S3: _auto_seed_reconcile_thin_body
#                                          to detect and reconcile thin-body outcomes.
#   plan_tier == "full" | "change" | "" → S4: _auto_seed_block_full
#
# Each candidate's handling is wrapped in `|| true` (best-effort): a single
# failure logs a WARN and the pass continues. The function always returns 0.
#
# Test hook:
#   Reuses the per-step test hooks of S1–S4 (MAKATO_LOOP_AUTOSEED_OVERRIDE,
#   MAKATO_LOOP_SEED_TEST_CMD, MAKATO_LOOP_BLOCK_TEST_FILE, etc.). The
#   _test-auto-seed-unprepared hook in the MAKATO_LOOP_TEST_HOOK block
#   invokes this function directly.
# ---------------------------------------------------------------------------
_auto_seed_unprepared() {
  echo "loop: auto-seed — starting pre-poll unprepared pass (#373, epic #367 S5)" >&2

  local candidates
  # Candidates function writes JSON to stdout, messages to stderr.
  candidates="$(_auto_seed_candidates)" 2>/dev/null || candidates='[]'
  [[ -n "$candidates" ]] || candidates='[]'

  local count
  count="$(jq 'length' <<<"$candidates" 2>/dev/null || echo 0)"
  echo "loop: auto-seed — $count candidate(s) to process" >&2

  local n plan_tier
  while IFS=$'\t' read -r n plan_tier; do
    [[ -n "$n" ]] || continue

    if [[ "$plan_tier" == "light" ]]; then
      # S2: dispatch seed-issue headlessly.
      local dispatch_rc=0
      _auto_seed_dispatch_light "$n" "$plan_tier" || dispatch_rc=$?
      if [[ "$dispatch_rc" -eq 0 ]]; then
        # S3: reconcile thin-body outcome. Derive seed_key from issue number.
        # _auto_seed_reconcile_thin_body handles an absent jsonl gracefully.
        local seed_key=""
        seed_key="$(_derive_key_for_issue "$n" "${MAKATO_LOOP_DISPATCH_REPO:-}" 2>/dev/null || true)"
        _auto_seed_reconcile_thin_body "$n" "$seed_key" || true
      else
        echo "loop: WARN — auto-seed #$n light dispatch failed (rc=$dispatch_rc); tick continues" >&2
      fi
    else
      # S4: block full/untiered issues. (change-tier is a no-op in _auto_seed_block_full)
      _auto_seed_block_full "$n" "$plan_tier" || true
    fi
  done < <(jq -r '.[] | [.number, .plan_tier] | @tsv' <<<"$candidates" 2>/dev/null || true)

  echo "loop: auto-seed — pre-poll unprepared pass complete" >&2
  return 0
}

# ---------------------------------------------------------------------------
# _reap_epoch_of_iso <iso-8601-ms> — convert an ISO-8601 ms timestamp (the
# shape _now emits) to a Unix epoch integer, or empty on parse failure. Used
# by the reap throttle to compare last_reap against wall-clock now. python3
# for portability (macOS `date` lacks GNU -d; matches _now's convention).
# ---------------------------------------------------------------------------
_reap_epoch_of_iso() {
  local iso="$1"
  [[ -n "$iso" && "$iso" != "null" ]] || return 0
  python3 -c "import sys,datetime
try:
    s=sys.argv[1].replace('Z','+00:00')
    print(int(datetime.datetime.fromisoformat(s).timestamp()))
except Exception:
    pass" "$iso" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _derive_reap_repo — resolve owner/repo for `gh pr list`. Prefers the explicit
# MAKATO_LOOP_REAP_REPO override, then MAKATO_LOOP_DISPATCH_REPO (set by cmd_run
# from the poll result), then parses `git remote get-url origin`. Prints the
# owner/repo slug, or empty when none can be resolved.
# ---------------------------------------------------------------------------
_derive_reap_repo() {
  if [[ -n "${MAKATO_LOOP_REAP_REPO:-}" ]]; then
    printf '%s\n' "$MAKATO_LOOP_REAP_REPO"; return 0
  fi
  if [[ -n "${MAKATO_LOOP_DISPATCH_REPO:-}" ]]; then
    printf '%s\n' "$MAKATO_LOOP_DISPATCH_REPO"; return 0
  fi
  git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's|.*github\.com[:/]||; s|\.git$||' || true
}

# ---------------------------------------------------------------------------
# _reap_pr_merged <repo> <branch> — echo the merged PR number for a branch, or
# empty if none. Offline test hook: MAKATO_LOOP_REAP_GH_OVERRIDE points at a
# JSON map {"<branch>": "<pr#>"} read instead of calling `gh`.
# ---------------------------------------------------------------------------
_reap_pr_merged() {
  local repo="$1" branch="$2"
  if [[ -n "${MAKATO_LOOP_REAP_GH_OVERRIDE:-}" ]]; then
    jq -r --arg b "$branch" '.[$b] // empty' \
      "$MAKATO_LOOP_REAP_GH_OVERRIDE" 2>/dev/null || true
    return 0
  fi
  [[ -n "$repo" ]] || return 0
  gh pr list --repo "$repo" --head "$branch" --state merged \
    --json number --jq '.[0].number // empty' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _reap_base_ref — the ref a landed branch's work should already be contained
# in (the default branch). Resolves origin/HEAD (→ origin/main) with an
# origin/main fallback. Override with MAKATO_LOOP_REAP_BASE_REF (tests point it
# at a local `main` so ancestry works in a throwaway repo with no remote).
# ---------------------------------------------------------------------------
_reap_base_ref() {
  if [[ -n "${MAKATO_LOOP_REAP_BASE_REF:-}" ]]; then
    printf '%s\n' "$MAKATO_LOOP_REAP_BASE_REF"; return 0
  fi
  local ref
  ref="$(git -C "$REPO_ROOT" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's@^refs/remotes/@@')"
  [[ -n "$ref" ]] && { printf '%s\n' "$ref"; return 0; }
  printf 'origin/main\n'
}

# ---------------------------------------------------------------------------
# _reap_branch_landed <head-sha> <branch> <repo> <base-ref> — echo a short
# reason when the worktree's work has already LANDED on the base branch, empty
# otherwise. Two independent signals, unioned so both merge styles are covered:
#
#   (a) merged PR for the head branch — catches squash/rebase merges where the
#       commits are rewritten so the SHA is no longer an ancestor of base.
#   (b) HEAD is a strict ancestor of the base ref — catches branches whose PR
#       head was renamed (the `gh --head` lookup misses them) but whose commits
#       are demonstrably already in base.
#
# HEAD == base tip is deliberately NOT treated as landed: a freshly created
# worktree sits exactly on the base tip with no work of its own, so equality is
# ambiguous and only a merged PR (signal a) counts there. This is the guard
# that keeps a just-branched, not-yet-committed worktree alive.
# ---------------------------------------------------------------------------
_reap_branch_landed() {
  local head="$1" branch="$2" repo="$3" base_ref="$4"
  local pr
  pr="$(_reap_pr_merged "$repo" "$branch")"
  if [[ -n "$pr" ]]; then printf 'merged PR #%s\n' "$pr"; return 0; fi
  local base_tip
  base_tip="$(git -C "$REPO_ROOT" rev-parse -q --verify "$base_ref" 2>/dev/null || true)"
  if [[ -n "$base_tip" && -n "$head" && "$head" != "$base_tip" ]]; then
    if git -C "$REPO_ROOT" merge-base --is-ancestor "$head" "$base_ref" 2>/dev/null; then
      printf 'ancestor of %s\n' "$base_ref"; return 0
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _reap_is_retained <realpath-of-worktree> — return 0 (retained → skip) when
# ANY specs/*/workflow-state-*.json has .worktree_retained==true AND a
# .worktree_path that realpath-matches the candidate; else return 1. Mirrors
# in_flight_issues' scan. Most worktrees have no state file, in which case the
# flag simply cannot veto — the dirty/lock guards are the backstop for those.
# ---------------------------------------------------------------------------
_reap_is_retained() {
  local target="$1"
  [[ -d "$SPECS_DIR" ]] || return 1
  local match
  match="$(find "$SPECS_DIR" -maxdepth 2 \
      \( -name 'workflow-state-*.json' -o -name 'workflow-state.json' \) \
      -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
      local wp retained rp
      retained="$(jq -r '.worktree_retained // false' "$f" 2>/dev/null || echo false)"
      [[ "$retained" == "true" ]] || continue
      wp="$(jq -r '.worktree_path // empty' "$f" 2>/dev/null || true)"
      [[ -n "$wp" ]] || continue
      rp="$(_realpath "$wp")"
      if [[ "$rp" == "$target" ]]; then echo "match"; break; fi
    done)"
  [[ -n "$match" ]]
}

# ---------------------------------------------------------------------------
# _realpath <path> — canonicalise (resolves macOS /var → /private/var symlink
# aliasing so path comparisons are stable). Matches worktree.sh's helper.
# ---------------------------------------------------------------------------
_realpath() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || printf '%s\n' "$1"
}

# ---------------------------------------------------------------------------
# _reap_wt_age_secs <worktree-dir> — return the age of the worktree directory
# in whole seconds (now - directory mtime).  Used by the stale-reaper (#320).
# Falls back to 0 on stat failure so a broken directory is treated as young
# (safe default — no false positive reaping on stat error).
# ---------------------------------------------------------------------------
_reap_wt_age_secs() {
  local dir="$1"
  # Use python3 (already a project dependency) for portable mtime — avoids the
  # macOS BSD vs GNU `stat` flag incompatibility.  Falls back to 0 on error so
  # a broken directory is treated as young (safe default, no false-positive reap).
  python3 -c '
import os, sys, time
try:
    mtime = os.path.getmtime(sys.argv[1])
    print(int(time.time() - mtime))
except Exception:
    print(0)
' "$dir" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# _reap_owner_pid_alive <worktree-dir> — return 0 when the owning loop.sh
# process (recorded in <worktree-dir>/.loop-owner.pid) is still running.
# Return 1 when the pid file is absent, empty, or the pid is dead.
# ---------------------------------------------------------------------------
_reap_owner_pid_alive() {
  local dir="$1"
  local pid_file="$dir/.loop-owner.pid"
  [[ -f "$pid_file" ]] || return 1
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || echo "")"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

# ---------------------------------------------------------------------------
# _reap_has_unpushed <worktree-dir> <branch> — return 0 when the worktree has
# commits on <branch> that have not been pushed to the remote tracking branch.
# Return 1 (= no unpushed commits, safe to reap) on any error or when the
# branch has no upstream configured.
# ---------------------------------------------------------------------------
_reap_has_unpushed() {
  local dir="$1" branch="$2"
  # Verify the remote tracking ref exists; if not, treat as no unpushed.
  local upstream
  upstream="$(git -C "$dir" rev-parse --abbrev-ref "@{u}" 2>/dev/null || echo "")"
  [[ -n "$upstream" ]] || return 1
  # Any commit reachable from HEAD but not from the remote tracking ref.
  local count
  count="$(git -C "$dir" rev-list --count HEAD "^$upstream" 2>/dev/null || echo 0)"
  [[ "$count" -gt 0 ]]
}

# ---------------------------------------------------------------------------
# _reap_merged_worktrees — name-agnostic sweep that removes local worktrees
# whose work has already LANDED on the base branch (#265). See the config block
# near the top of this file for the rationale. Best-effort: never fails the tick.
#
# Guard stack — a worktree is removed ONLY when it passes ALL of:
#   1. not the main checkout (realpath != realpath(REPO_ROOT))
#   2. lives under .claude/worktrees/ (out-of-band worktrees are left alone)
#   3. no nested-worktree relationship — neither the parent of another
#      registered worktree nor a child living inside one
#   4. not locked (`git worktree lock` is the operator's always-honoured pin)
#   5. not detached HEAD (no branch → cannot correlate to landed work)
#   6. no TRACKED uncommitted changes (untracked `??` scratch does NOT pin)
#   7. not retained (workflow-state .worktree_retained==true, when a state maps)
#   8. branch has LANDED on the base branch — merged PR OR HEAD is an ancestor
#      of the base ref (renamed-head / squash-merge safe; see
#      _reap_branch_landed)
#      — OR, when guard 8 fails, Guard 9 (#320) applies:
#   9. stale-crash reap — branch NOT landed BUT: owning loop.sh pid is dead
#      AND worktree age >= REAP_STALE_AGE_SECS AND (no unpushed commits OR
#      REAP_STALE_FORCE=1).  Records a "stale-crashed worktree" landed reason.
#
# Throttle: no-ops when the last pass ran within REAP_INTERVAL_SECS. Offline
# test hooks: MAKATO_LOOP_REAP_WT_OVERRIDE (fake porcelain), _REAP_GH_OVERRIDE
# (merged-PR map), MAKATO_LOOP_REAP_BASE_REF (base ref for ancestry),
# MAKATO_LOOP_REAP_DRYRUN=1 (log intent, do not remove).
# ---------------------------------------------------------------------------
_reap_merged_worktrees() {
  [[ "$REAP_ON_POLL" == "1" ]] || return 0

  # Throttle — skip when a pass ran within the interval window.
  if [[ "${REAP_INTERVAL_SECS:-3600}" -gt 0 ]]; then
    local last_reap last_epoch now_epoch
    last_reap="$(_read_status | jq -r '.last_reap // empty' 2>/dev/null || true)"
    last_epoch="$(_reap_epoch_of_iso "$last_reap")"
    if [[ -n "$last_epoch" ]]; then
      now_epoch="$(date +%s)"
      if (( now_epoch - last_epoch < REAP_INTERVAL_SECS )); then
        return 0
      fi
    fi
  fi

  local dryrun="${MAKATO_LOOP_REAP_DRYRUN:-}"
  local repo self_path wt_base porcelain base_ref
  repo="$(_derive_reap_repo)"
  base_ref="$(_reap_base_ref)"
  self_path="$(_realpath "$REPO_ROOT")"
  wt_base="$(_realpath "$REPO_ROOT/.claude/worktrees")"

  if [[ -n "${MAKATO_LOOP_REAP_WT_OVERRIDE:-}" ]]; then
    porcelain="$(cat "$MAKATO_LOOP_REAP_WT_OVERRIDE" 2>/dev/null || true)"
  else
    porcelain="$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null || true)"
  fi
  [[ -n "$porcelain" ]] || { _reap_stamp 0 ""; return 0; }

  # First pass: collect all worktree paths (realpath) so guard 3 can detect a
  # candidate that is the parent of a nested worktree.
  local all_paths=()
  local line p
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) p="${line#worktree }"; all_paths+=("$(_realpath "$p")") ;;
    esac
  done <<<"$porcelain"

  # Second pass: parse stanzas and apply the guard stack.
  local reaped_json="[]"
  local reaped_count=0
  local cur_path="" cur_branch="" cur_locked="" cur_detached="" cur_head=""

  _reap_process_stanza() {
    [[ -n "$cur_path" ]] || return 0
    local rp="$cur_path" branch="$cur_branch"

    # Guard 1: main checkout.
    if [[ "$rp" == "$self_path" ]]; then
      echo "loop: reap skip $rp (main checkout)" >&2; return 0
    fi
    # Guard 2: under .claude/worktrees/.
    if [[ "$rp" != "$wt_base/"* ]]; then
      echo "loop: reap skip $rp (outside .claude/worktrees)" >&2; return 0
    fi
    # Guard 3: nested-worktree relationship. Two distinct hazards:
    #   (a) PARENT — the candidate contains another registered worktree in its
    #       subtree; removing it would blow away the nested one.
    #   (b) CHILD-OF-ANOTHER-WORKTREE — the candidate lives inside ANOTHER
    #       worktree's own .claude/worktrees/ dir (a worktree nested under a
    #       worktree). Removing it there corrupts the parent; the parent's own
    #       guards govern that subtree.
    # Note the main checkout is itself a registered worktree and every managed
    # worktree lives under its .claude/worktrees/ — that is the NORMAL layout,
    # not nesting. So (b) must key off `other != self_path`, and equivalently a
    # genuinely nested worktree is one whose path contains `.claude/worktrees/`
    # more than once. We check the registered-ancestor form directly.
    local other
    for other in "${all_paths[@]}"; do
      [[ "$other" == "$rp" ]] && continue
      if [[ "$other" == "$rp/"* ]]; then
        echo "loop: reap skip $rp (parent of nested worktree)" >&2; return 0
      fi
      if [[ "$other" != "$self_path" && "$rp" == "$other/"* ]]; then
        echo "loop: reap skip $rp (nested inside worktree $other)" >&2; return 0
      fi
    done
    # Guard 4: locked.
    if [[ -n "$cur_locked" ]]; then
      echo "loop: reap skip $rp (locked)" >&2; return 0
    fi
    # Guard 5: detached HEAD.
    if [[ -n "$cur_detached" || -z "$branch" ]]; then
      echo "loop: reap skip $rp (detached HEAD / no branch)" >&2; return 0
    fi
    # Guard 6: dirty working tree — TRACKED changes only. Untracked scratch
    # files (build artefacts, generated HTML, editor droppings) are not work
    # worth preserving and must not pin a worktree forever, so `--porcelain`
    # `??` lines are filtered out. Staged/modified/deleted TRACKED paths still
    # veto removal (that is real uncommitted work).
    if [[ -n "$(git -C "$rp" status --porcelain 2>/dev/null | grep -v '^??')" ]]; then
      echo "loop: reap skip $rp (dirty working tree — tracked changes)" >&2; return 0
    fi
    # Guard 7: retained via workflow-state.
    if _reap_is_retained "$rp"; then
      echo "loop: reap skip $rp (worktree_retained=true)" >&2; return 0
    fi
    # Guard 8: the branch’s work must have LANDED on the base branch — either a
    # merged PR (any merge style) OR the HEAD is already an ancestor of the
    # base ref (catches renamed-head branches the PR lookup misses). A worktree
    # whose work is not yet in base is live and must survive.
    # Exception: Guard 9 (stale-crash reap) can authorise removal without landing.
    local landed=""
    landed="$(_reap_branch_landed "$cur_head" "$branch" "$repo" "$base_ref")"
    if [[ -z "$landed" ]]; then
      # Guard 9 (#320): stale-crash reap — the branch has NOT landed but the
      # owning loop.sh process is dead AND the worktree is older than
      # REAP_STALE_AGE_SECS.  This catches hard-crashed runs that leave a
      # worktree behind indefinitely.
      #
      # Safety invariants:
      #   a) A live owning PID always skips — we never reap under a live loop.
      #   b) Unpushed commits block reaping unless REAP_STALE_FORCE=1 (explicit
      #      operator opt-in that un-landed work may be discarded).
      #   c) Age threshold prevents mis-reaping a freshly created worktree whose
      #      loop is still starting up (REAP_STALE_AGE_SECS default = 24h).
      #   d) All upstream guards (locked, dirty, retained) already fired above;
      #      a worktree reaching here is clean and un-retained.

      # (a) live owner — skip
      if _reap_owner_pid_alive "$rp"; then
        echo "loop: reap skip $rp (branch $branch not landed; owner pid alive)" >&2; return 0
      fi
      # (c) age gate
      local age
      age="$(_reap_wt_age_secs "$rp")"
      if [[ "${REAP_STALE_AGE_SECS:-86400}" -gt 0 ]] && \
         (( age < REAP_STALE_AGE_SECS )); then
        echo "loop: reap skip $rp (branch $branch not landed; worktree too young ${age}s < ${REAP_STALE_AGE_SECS}s)" >&2; return 0
      fi
      # (b) unpushed commits gate
      if _reap_has_unpushed "$rp" "$branch"; then
        if [[ "${REAP_STALE_FORCE:-0}" != "1" ]]; then
          echo "loop: reap skip $rp (branch $branch not landed; unpushed commits — set MAKATO_LOOP_REAP_STALE_FORCE=1 to override)" >&2; return 0
        fi
        echo "loop: reap WARN $rp (branch $branch not landed; unpushed commits present; REAP_STALE_FORCE=1)" >&2
      fi

      # Passed all stale-crash guards — authorise reap.
      landed="stale-crashed worktree (owner pid dead, age ${age}s)"
    fi

    if [[ -n "$dryrun" ]]; then
      echo "loop: reap would remove $rp ($landed, branch $branch)" >&2
      return 0
    fi
    echo "loop: reap removing $rp ($landed, branch $branch)" >&2
    if git -C "$REPO_ROOT" worktree remove --force "$rp" >/dev/null 2>&1; then
      reaped_json="$(jq -c --arg p "$rp" --arg b "$branch" --arg r "$landed" \
        '. + [{path:$p, branch:$b, landed:$r}]' <<<"$reaped_json")"
      reaped_count=$((reaped_count + 1))
    else
      echo "loop: WARN — reap remove failed for $rp (tick continues)" >&2
    fi
  }

  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        _reap_process_stanza
        cur_path="$(_realpath "${line#worktree }")"
        cur_branch=""; cur_locked=""; cur_detached=""; cur_head=""
        ;;
      "HEAD "*)              cur_head="${line#HEAD }" ;;
      "branch refs/heads/"*) cur_branch="${line#branch refs/heads/}" ;;
      "detached")            cur_detached=1 ;;
      "locked"*)             cur_locked=1 ;;
    esac
  done <<<"$porcelain"
  _reap_process_stanza   # flush the final stanza (no trailing blank guaranteed)

  # Prune stale registrations left by removals (best-effort).
  if [[ -z "$dryrun" && "$reaped_count" -gt 0 ]]; then
    git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
  fi

  # Orphaned specs/ folder pruning — runs in the same pass window so it
  # inherits the REAP_ON_POLL guard and the shared throttle. Best-effort:
  # a failure here never aborts the worktree-reap audit.
  _reap_orphan_specs || true

  _reap_stamp "$reaped_count" "$reaped_json"
  return 0
}

# ---------------------------------------------------------------------------
# _reap_stamp <count> <reaped-json> — record the reap-pass audit into
# loop-status.json. `reaped` is written only when the pass removed something
# (keeps the status file from growing an empty array every hour).
# ---------------------------------------------------------------------------
_reap_stamp() {
  local count="$1" reaped_json="${2:-}"
  _patch_status '.last_reap' "\"$(_now)\""
  _patch_status '.last_reap_count' "${count:-0}"
  if [[ "${count:-0}" -gt 0 && -n "$reaped_json" ]]; then
    _patch_status '.reaped' "$reaped_json"
  fi
}

# ---------------------------------------------------------------------------
# _reap_orphan_specs — prune local specs/<slug>/ folders for completed or
# closed issues. Called from _reap_merged_worktrees after the worktree pass,
# so it shares the REAP_ON_POLL guard and the throttle window. Audit counts
# land in separate loop-status.json fields (.last_reap_specs_count /
# .reap_specs_pruned) so they never mingle with the worktree .reaped schema.
#
# Why this lives here and not in archive-spec.sh: in the makato repo `specs/**`
# is gitignored (only build.jsonl / spec.md are whitelisted), so the po-agent's
# per-run artefacts (plan.md, workflow-state-<N>.json, orchestrate.jsonl,
# seed-manifest.json, lessons-*.md) are untracked local scratch. archive-spec.sh
# runs on a GHA runner with a fresh checkout — it cannot see, let alone remove,
# these local files. The reaper runs on the operator's machine where they live.
#
# Decision tree per folder:
#   1. SAFETY: `git ls-files <dir>` non-empty → skip. A folder with ANY tracked
#      file belongs to a consumer repo where specs are committed and managed by
#      archive-spec.sh via `git mv`; the reaper must NEVER delete it.
#   2. Issue number: seed-manifest.json .issue_number (primary), else N parsed
#      from a workflow-state-<N>.json filename. Not derivable → skip with WARN.
#   3. Done signal (fast local path first): workflow-state-<N>.json has
#      .current_phase == "done" → prune. Otherwise fall back to `gh issue view
#      <N> --json state` (or MAKATO_LOOP_REAP_SPECS_GH_OVERRIDE): CLOSED → prune,
#      OPEN → skip, unknown/error → skip with WARN.
#   3b. SHARED-EPIC guard: if the folder holds a created-issues.json / stories.json
#      that enumerates sibling issues, KEEP the folder while ANY sibling is still
#      open — one stories.json is the shared AC/plan store for the whole batch
#      (e.g. openspec-transfer-features hosts #562–#568). Unreadable sibling
#      state is treated as open (KEEP). Prevents destroying sibling plans when
#      only one story of an epic has merged.
#   4. Promote lessons THEN prune: before deleting, run promote-lessons.sh so
#      any scope=generalizable lesson in workflow-state-<N>.json /
#      change-lessons.jsonl is lifted into the committed .makato/memory/ store.
#      Those source files are gitignored, so documentation-agent (fresh GHA
#      checkout) never sees them — the reaper is the only place promotion can
#      read them. A non-zero promote exit KEEPS the folder (never lose lessons).
#   5. Dryrun (MAKATO_LOOP_REAP_DRYRUN): log intent, promote nothing, remove nothing.
#
# Always returns 0 (best-effort — a per-folder failure never aborts the tick).
# ---------------------------------------------------------------------------
_reap_orphan_specs() {
  [[ "$REAP_SPECS" == "1" ]] || return 0

  local spec_root="${SPECS_DIR:-${REPO_ROOT}/specs}"
  [[ -d "$spec_root" ]] || return 0

  local dryrun="${MAKATO_LOOP_REAP_DRYRUN:-}"
  local pruned_count=0
  local pruned_json="[]"

  local slug_dir
  while IFS= read -r -d '' slug_dir; do
    [[ -d "$slug_dir" ]] || continue

    # Guard 1: must be fully untracked (see NEVER note above).
    if [[ -n "$(git -C "$REPO_ROOT" ls-files "$slug_dir" 2>/dev/null)" ]]; then
      echo "loop: reap-specs skip $slug_dir (has tracked files — managed by archive-spec.sh)" >&2
      continue
    fi

    # Derive the issue number: seed-manifest first, workflow-state filename fallback.
    local issue_num=""
    if [[ -f "$slug_dir/seed-manifest.json" ]]; then
      issue_num="$(jq -r '.issue_number // empty' "$slug_dir/seed-manifest.json" 2>/dev/null || true)"
    fi
    if [[ -z "$issue_num" ]]; then
      local wf_file
      wf_file="$(find "$slug_dir" -maxdepth 1 -name 'workflow-state-*.json' 2>/dev/null | head -1)"
      if [[ -n "$wf_file" ]]; then
        issue_num="$(basename "$wf_file" | sed -E 's/^workflow-state-([0-9]+)\.json$/\1/')"
      fi
    fi
    if [[ -z "$issue_num" || ! "$issue_num" =~ ^[0-9]+$ ]]; then
      # Distinguish: a folder with no <N>- prefix AND no manifest/workflow-state
      # is a human-authored design-doc or scratch folder — demote to info/debug.
      # A folder that looks issue-derived (has a seed-manifest or workflow-state
      # file) but still failed number derivation is a genuine anomaly — keep WARN.
      local slug_basename
      slug_basename="$(basename "$slug_dir")"
      if [[ ! "$slug_basename" =~ ^[0-9] ]] \
          && [[ ! -f "$slug_dir/seed-manifest.json" ]] \
          && [[ -z "$(find "$slug_dir" -maxdepth 1 -name 'workflow-state-*.json' 2>/dev/null | head -1)" ]]; then
        echo "loop: reap-specs skip $slug_dir (no issue prefix, treating as design-doc folder)" >&2
      else
        echo "loop: reap-specs WARN $slug_dir — cannot derive issue number, skipping" >&2
      fi
      continue
    fi

    # Done signal — fast local path: workflow-state phase=done.
    local reason=""
    local wf_phase_file="$slug_dir/workflow-state-${issue_num}.json"
    if [[ -f "$wf_phase_file" ]]; then
      local phase
      phase="$(jq -r '.current_phase // empty' "$wf_phase_file" 2>/dev/null || true)"
      [[ "$phase" == "done" ]] && reason="workflow-state phase=done"
    fi

    # Fallback: gh issue state (offline override in tests).
    if [[ -z "$reason" ]]; then
      local gh_state=""
      if [[ -n "${MAKATO_LOOP_REAP_SPECS_GH_OVERRIDE:-}" ]]; then
        gh_state="$(jq -r --arg n "$issue_num" '.[$n] // empty' \
          "$MAKATO_LOOP_REAP_SPECS_GH_OVERRIDE" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
      else
        local repo; repo="$(_derive_reap_repo)"
        local -a repo_flag=()
        [[ -n "$repo" ]] && repo_flag=(--repo "$repo")
        gh_state="$(gh issue view "$issue_num" "${repo_flag[@]}" --json state --jq '.state' 2>/dev/null \
          | tr '[:upper:]' '[:lower:]' || true)"
      fi
      if [[ "$gh_state" == "closed" ]]; then
        reason="issue #${issue_num} CLOSED"
      elif [[ "$gh_state" == "open" ]]; then
        echo "loop: reap-specs skip $slug_dir (issue #${issue_num} is OPEN)" >&2
        continue
      else
        echo "loop: reap-specs WARN $slug_dir (issue #${issue_num} gh state unknown: '${gh_state}') — skipping" >&2
        continue
      fi
    fi

    # Guard 6: shared-epic folder. A folder whose created-issues.json (or
    # stories.json) enumerates MORE than one issue is an epic store shared by
    # the whole batch (e.g. openspec-transfer-features hosts #562–#568 with one
    # stories.json). The done signal above only clears the single issue whose
    # workflow-state we derived; deleting the folder would destroy the AC/plan
    # data the sibling stories still need. Skip while ANY referenced sibling is
    # still open. Offline via MAKATO_LOOP_REAP_SPECS_GH_OVERRIDE (same fixture
    # map used by the done-signal fallback). Best-effort: an unreadable sibling
    # state is treated as "still open" (KEEP) — never lose shared plans.
    local epic_manifest=""
    for cand in "$slug_dir/created-issues.json" "$slug_dir/stories.json"; do
      [[ -f "$cand" ]] && { epic_manifest="$cand"; break; }
    done
    if [[ -n "$epic_manifest" ]]; then
      # Collect every issue number referenced in the manifest (both shapes:
      # created-issues.json .issues[].issue_number and stories.json
      # .stories[].issue_number / githubIssue), excluding the current one.
      local -a siblings=()
      while IFS= read -r sib; do
        [[ -n "$sib" && "$sib" != "$issue_num" ]] && siblings+=("$sib")
      done < <(jq -r '
        [ (.issues[]?.issue_number // empty),
          (.stories[]?.issue_number // empty),
          (.stories[]?.githubIssue // empty) ]
        | .[] | numbers' "$epic_manifest" 2>/dev/null | sort -u)

      if [[ "${#siblings[@]}" -gt 0 ]]; then
        local open_sibling=""
        for sib in "${siblings[@]}"; do
          local sib_state=""
          if [[ -n "${MAKATO_LOOP_REAP_SPECS_GH_OVERRIDE:-}" ]]; then
            sib_state="$(jq -r --arg n "$sib" '.[$n] // empty' \
              "$MAKATO_LOOP_REAP_SPECS_GH_OVERRIDE" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
          else
            local sib_repo; sib_repo="$(_derive_reap_repo)"
            local -a sib_repo_flag=()
            [[ -n "$sib_repo" ]] && sib_repo_flag=(--repo "$sib_repo")
            sib_state="$(gh issue view "$sib" "${sib_repo_flag[@]}" --json state --jq '.state' 2>/dev/null \
              | tr '[:upper:]' '[:lower:]' || true)"
          fi
          # Anything not definitively "closed" (open, or unreadable) pins the folder.
          if [[ "$sib_state" != "closed" ]]; then
            open_sibling="$sib"
            break
          fi
        done
        if [[ -n "$open_sibling" ]]; then
          echo "loop: reap-specs skip $slug_dir (shared-epic folder — sibling issue #${open_sibling} still open; keeping shared plans)" >&2
          continue
        fi
      fi
    fi

    # Prune (or log intent under dryrun).
    if [[ -n "$dryrun" ]]; then
      echo "loop: reap-specs would remove $slug_dir (issue #${issue_num}, ${reason})" >&2
    else
      # Promote generalizable lessons into the committed store BEFORE deleting.
      # This is the only place promotion can read the po-agent's per-issue
      # lessons: workflow-state-<N>.json / change-lessons.jsonl are gitignored,
      # so documentation-agent on a fresh GHA checkout never sees them. If the
      # promote step fails (non-zero — a genuine I/O error), we KEEP the folder
      # so the lessons are never lost; a clean exit (promoted or nothing to
      # promote) authorises removal.
      local promote_sh="$(dirname "$0")/promote-lessons.sh"
      if [[ -f "$promote_sh" ]]; then
        if ! bash "$promote_sh" "$issue_num" "$spec_root" \
               "${REPO_ROOT}/.makato/memory/procedural.jsonl" >/dev/null 2>&1; then
          echo "loop: reap-specs SKIP $slug_dir (issue #${issue_num}) — promote-lessons failed, keeping folder to avoid lesson loss" >&2
          continue
        fi
      fi
      echo "loop: reap-specs removing $slug_dir (issue #${issue_num}, ${reason})" >&2
      if rm -rf "$slug_dir" 2>/dev/null; then
        pruned_json="$(jq -c --arg d "$slug_dir" --arg n "$issue_num" --arg r "$reason" \
          '. + [{dir:$d, issue:$n, reason:$r}]' <<<"$pruned_json")"
        pruned_count=$((pruned_count + 1))
      else
        echo "loop: WARN — reap-specs remove failed for $slug_dir (tick continues)" >&2
      fi
    fi
  done < <(find "$spec_root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

  # Audit — write count every live pass; the array only when something moved.
  if [[ -z "$dryrun" ]]; then
    _patch_status '.last_reap_specs_count' "${pruned_count}"
    if [[ "$pruned_count" -gt 0 ]]; then
      _patch_status '.reap_specs_pruned' "$pruned_json"
    fi
  fi

  return 0
}

# ---------------------------------------------------------------------------
# remove-worktrees — standalone entry point for the merged-worktree reaper
# (#265). Also called by cmd_run before each poll. Bypass the throttle with
# MAKATO_LOOP_REAP_INTERVAL=0; inspect safely with MAKATO_LOOP_REAP_DRYRUN=1.
# ---------------------------------------------------------------------------
cmd_remove_worktrees() {
  _reap_merged_worktrees
}

# ---------------------------------------------------------------------------
# _pre_dispatch_plan_guard <KEY> — validate plan.md before PO-agent dispatch.
# Runs validate-plan-body.sh; if invalid, attempts build-refine --autonomous
# as a recovery step, then re-validates. Emits a colon-delimited tuple on
# stdout: "<verdict>:<refine_attempted>:<refine_outcome>" where:
#   verdict         ∈ {valid, invalid, skipped, error}
#   refine_attempted ∈ {true, false}
#   refine_outcome  ∈ {valid, invalid, error, n/a}
# Never blocks dispatch on its own — callers decide whether to proceed.
# ---------------------------------------------------------------------------
_pre_dispatch_plan_guard() {
  local key="$1"
  local validate_sh
  validate_sh="$(dirname "$0")/validate-plan-body.sh"

  # Locate plan.md via the same glob _spec_folder_for_key uses.
  local spec_root="${SPECS_DIR:-${REPO_ROOT}/specs}"
  local plan_path
  plan_path="$(find "$spec_root" -maxdepth 2 -name "plan.md" \
    -path "*/${key}*" 2>/dev/null | head -1)"

  if [[ -z "$plan_path" ]]; then
    echo "skipped:false:n/a"
    return 0
  fi

  if [[ ! -x "$validate_sh" && ! -f "$validate_sh" ]]; then
    echo "error:false:n/a"
    return 0
  fi

  local guard_out guard_verdict
  guard_out="$(bash "$validate_sh" "$plan_path" 2>/dev/null || true)"
  guard_verdict="${guard_out%% *}"

  if [[ "$guard_verdict" == "valid" ]]; then
    echo "valid:false:n/a"
    return 0
  fi

  # Plan is invalid — attempt build-refine --autonomous as recovery.
  # Note: exit 127 from the claude subprocess means the skill binary is not
  # launchable (PATH / installation issue), NOT a build-refine logic failure.
  # That case is branched below before the generic non-zero error path.
  echo "loop: pre-dispatch plan guard: plan.md invalid for KEY=${key} — running build-refine --autonomous" >&2

  local refine_prompt="Use the Skill tool to invoke the makato-build:build-refine skill with args '${key} --autonomous'. REPO_ROOT=${REPO_ROOT}. MAKATO_HEADLESS=1 is already exported. Return R1 envelope verbatim."
  local refine_exit=0
  MAKATO_HEADLESS=1 REPO_ROOT="$REPO_ROOT" \
    "$CLAUDE_BIN" --dangerously-skip-permissions -p "$refine_prompt" \
    >/dev/null 2>&1 || refine_exit=$?

  if [[ $refine_exit -eq 127 ]]; then
    # exit 127 = skill not launchable (claude binary missing / PATH issue) —
    # this is an expected infrastructure skip, not a refine logic failure.
    echo "loop: pre-dispatch plan guard: build-refine skill not launchable (exit 127) for KEY=${key} — skipping refine, dispatching anyway" >&2
    echo "invalid:true:error"
    return 0
  fi
  if [[ $refine_exit -ne 0 ]]; then
    echo "loop: pre-dispatch plan guard: build-refine exited ${refine_exit} for KEY=${key} — dispatching anyway" >&2
    echo "invalid:true:error"
    return 0
  fi

  # Re-validate after refine — this is the single authoritative post-refine check.
  local guard_out2 guard_verdict2
  guard_out2="$(bash "$validate_sh" "$plan_path" 2>/dev/null || true)"
  guard_verdict2="${guard_out2%% *}"

  if [[ "$guard_verdict2" == "valid" ]]; then
    echo "loop: pre-dispatch plan guard: build-refine produced a valid plan for KEY=${key}" >&2
    echo "valid:true:valid"
  else
    echo "loop: pre-dispatch plan guard: build-refine did not produce a valid plan for KEY=${key} — dispatching anyway" >&2
    echo "invalid:true:invalid"
  fi
}

# ---------------------------------------------------------------------------
# _emit_langfuse_trace <log_file> <issue>
#
# Called after every headless `claude -p` dispatch completes. Extracts the
# session_id from the stream-json result line in <log_file>, derives the
# transcript path (~/.claude/projects/<project-hash>/<session_id>.jsonl),
# and pipes a minimal Stop-hook payload to langfuse_hook.py.
#
# Skipped silently when:
#   - TRACE_TO_LANGFUSE != true
#   - langfuse_hook.py not found on the plugin search path
#   - session_id absent from log (test stub / dry-run paths)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# _extract_session_id <log_file>
#
# Extract the Claude session UUID from a dispatch log's terminal
# {"type":"result",...} stream-json line. This UUID is the value
# `claude --resume` requires — NOT the spec KEY or issue number (#616). Emits
# the UUID on stdout, or nothing when the log is absent/has no result line.
#
# Sole source of truth for session-id extraction: both _emit_langfuse_trace
# (telemetry) and the dispatch capture that persists last_session_id
# (recovery, #616) call this so the extraction logic exists in exactly one
# place.
# ---------------------------------------------------------------------------
_extract_session_id() {
  local log_file="${1:-}"
  [[ -f "$log_file" ]] || return 0
  grep '"type":"result"' "$log_file" 2>/dev/null \
    | tail -1 \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("session_id",""))' 2>/dev/null || true
}

_emit_langfuse_trace() {
  local log_file="${1:-}" issue="${2:-}"
  [[ "${TRACE_TO_LANGFUSE:-false}" == "true" ]] || return 0
  [[ -f "$log_file" ]] || return 0

  # Resolve hook — prefer working-tree copy, fall back to marketplace cache.
  local hook_py=""
  local _candidates=(
    "$REPO_ROOT/plugins/makato-observability/hooks/langfuse_hook.py"
    "$HOME/.claude/plugins/marketplaces/makato-suite/plugins/makato-observability/hooks/langfuse_hook.py"
  )
  local _c
  for _c in "${_candidates[@]}"; do
    if [[ -f "$_c" ]]; then hook_py="$_c"; break; fi
  done
  [[ -n "$hook_py" ]] || return 0

  # Extract session_id from the terminal {"type":"result",...} line.
  local session_id
  session_id="$(_extract_session_id "$log_file")"
  [[ -n "$session_id" ]] || return 0

  # Derive transcript path: ~/.claude/projects/<hash>/<session_id>.jsonl
  local project_hash
  project_hash="$(echo -n "$REPO_ROOT" | sed 's|/|-|g' | sed 's|^-||')"
  local transcript="$HOME/.claude/projects/${project_hash}/${session_id}.jsonl"
  [[ -f "$transcript" ]] || return 0

  # Read issue_trace_id from workflow-state (when available — absent on first
  # emit before init runs, or in repos without makato-orchestrate workflow-state).
  local issue_trace_id=""
  if [[ -n "${issue:-}" ]]; then
    local wf_file
    wf_file="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
      -name "workflow-state-${issue}.json" 2>/dev/null | head -1)"
    if [[ -n "$wf_file" ]]; then
      issue_trace_id="$(jq -r '.issue_trace_id // empty' "$wf_file" 2>/dev/null || true)"
    fi
  fi

  # Build payload via jq to avoid inline string interpolation with untrusted values.
  local payload_json
  payload_json="$(jq -n \
    --arg sid "$session_id" \
    --arg tp "$transcript" \
    --arg tid "${issue_trace_id:-}" \
    'if $tid != "" then {sessionId:$sid,transcriptPath:$tp,issue_trace_id:$tid}
     else {sessionId:$sid,transcriptPath:$tp} end')"
  python3 "$hook_py" <<< "$payload_json" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# dispatch <ISSUE_NUMBER> [--repo owner/repo] [--dry-run]
#
# --repo sets MAKATO_LOOP_DISPATCH_REPO for this call, overriding any
# ambient env value. Required when invoking dispatch directly (outside
# cmd_run's board poll, which sets the env var itself).
# ---------------------------------------------------------------------------
cmd_dispatch() {
  local issue="${1:?issue number required}"
  shift
  local dry_run=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)    MAKATO_LOOP_DISPATCH_REPO="${2:?--repo requires owner/repo}"; shift 2 ;;
      --dry-run) dry_run="--dry-run"; shift ;;
      *) echo "loop: dispatch: unknown flag: $1" >&2; return 64 ;;
    esac
  done

  # Require an explicit repo when dispatching directly — ambient git remote
  # is the makato repo, not the target, and a silent wrong-repo gh call is
  # harder to debug than an early failure here.
  if [[ -z "${MAKATO_LOOP_DISPATCH_REPO:-}" ]]; then
    echo "loop: dispatch: REPO is required — set MAKATO_LOOP_DISPATCH_REPO or pass --repo owner/repo" >&2
    return 1
  fi

  # #171 idempotent-dispatch guard — silent no-op (exit 0) when the same
  # issue is already in flight or was just dispatched within the guard
  # window. Distinct from the "different issue in flight" exit-2 branch
  # below: same-issue is a bug on the caller's side (a sleep-wake burst
  # or a race with the PO-agent's state write), not an operator error,
  # so the outer cmd_run should NOT log-and-retry noisily.
  if _within_dispatch_guard "$issue"; then
    echo "loop: dispatch #$issue skipped by guard (recent same-issue dispatch within window)" >&2
    return 0
  fi

  # Refuse to dispatch when a workflow is already active in this loop session.
  local active
  active="$(_read_status | jq -r '.active_workflow.issue // empty')"
  if [[ -n "$active" && "$active" != "$issue" ]]; then
    echo "loop: refuse to dispatch #$issue — active_workflow=#$active (single-threaded)" >&2
    return 2
  fi

  local now
  now="$(_now)"
  local active_obj
  active_obj="$(jq -n --argjson issue "$issue" --arg ts "$now" \
    '{issue: $issue, started_at: $ts, stalled: false, stalled_since: null, killed_by_watchdog: false}')"
  _patch_status '.active_workflow' "$active_obj"
  # Stamp .last_dispatch_at / .last_dispatch_issue on EVERY real dispatch
  # attempt (not just DRY_DISPATCH — that legacy stamp is preserved
  # below but no longer the only path that writes these fields). Guard
  # predicate B needs this to detect same-issue re-dispatch during the
  # sleep-wake burst after active_workflow has been cleared.
  _patch_status '.last_dispatch_at' "\"$now\""
  _patch_status '.last_dispatch_issue' "$issue"

  # Derive the po-agent dispatch bundle's KEY and BRANCH from the issue.
  # KEY is the feature slug from the issue body's to-issues provenance;
  # BRANCH is derived deterministically as feat/<issue>-<key> (the po-agent
  # creates the branch via worktree.sh --new-branch when it is absent on
  # the remote, so a deterministic name with no pre-existing ref is the
  # autonomous happy-path). On derivation failure, log a WARN and continue
  # with empty KEY/BRANCH — the po-agent then returns R1 failure with a
  # clear `missing input: KEY`, which is strictly better than the prior
  # state where ALL four required inputs were silently absent.
  local key="" branch=""
  if key="$(_derive_key_for_issue "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}")"; then
    # Avoid a doubled issue-number prefix: both the to-issues footer slug
    # (e.g. a dedicated collision-avoidance slug "470-persistent-…") and the
    # seed-issue title fallback slug ("<issue>-<normalized-title>") already
    # embed the issue number. Only prepend "<issue>-" when KEY does not
    # already start with it — key=470-foo → feat/470-foo (not feat/470-470-foo),
    # while key=test-feature → feat/<issue>-test-feature as before.
    if [[ "$key" == "${issue}-"* ]]; then
      branch="feat/${key}"
    else
      branch="feat/${issue}-${key}"
    fi
  else
    key=""
    echo "loop: WARN — could not derive KEY for issue #${issue} (no to-issues provenance in body); po-agent will fail input validation" >&2
  fi

  # Routing: issues labelled type:change are dispatched through the
  # makato-change:orchestrate --autonomous path; everything else goes to
  # the po-agent (makato-build pipeline).
  # Test hook: MAKATO_LOOP_ISSUE_TYPE_OVERRIDE — when set, its value is used
  # as issue_type directly (keeps routing smoke tests offline).
  # Resolved here (before the spec-folder gate) so the gate can bypass
  # type:change issues — change-orchestrate creates its own spec folder in
  # Step 0.5 and must never be blocked by a missing pre-existing folder.
  local issue_type=""
  if [[ -n "${MAKATO_LOOP_ISSUE_TYPE_OVERRIDE:-}" ]]; then
    issue_type="$MAKATO_LOOP_ISSUE_TYPE_OVERRIDE"
  else
    # #447: REST fallback for the routing label fetch. `gh api …/issues/N` and
    # `gh issue view --json labels` both expose `.labels[].name`, so the
    # `type:`-prefix extraction below is shape-agnostic. On wrapper failure
    # issue_type stays empty and dispatch continues to the default po-agent
    # path (unchanged fail-open routing).
    # Test seam: MAKATO_LOOP_ROUTING_LABELS_OVERRIDE — when set to a file path,
    # the labels JSON is read from that file instead of calling _gh_with_fallback
    # (mirrors MAKATO_LOOP_GATE_LABELS_OVERRIDE for offline smoke tests).
    local _rt_repo="${MAKATO_LOOP_DISPATCH_REPO:-}"
    local -a _rt_repo_flag=()
    [[ -n "$_rt_repo" ]] && _rt_repo_flag=(--repo "$_rt_repo")
    local _rt_rest_path
    if [[ -n "$_rt_repo" ]]; then
      _rt_rest_path="repos/${_rt_repo}/issues/${issue}"
    else
      _rt_rest_path="repos/{owner}/{repo}/issues/${issue}"
    fi
    local labels_json=""
    if [[ -n "${MAKATO_LOOP_ROUTING_LABELS_OVERRIDE:-}" ]]; then
      labels_json="$(cat "${MAKATO_LOOP_ROUTING_LABELS_OVERRIDE}" 2>/dev/null || true)"
    elif labels_json="$(_gh_with_fallback "issue-type routing #${issue}" \
        issue view "$issue" "${_rt_repo_flag[@]}" --json labels \
        -- api "$_rt_rest_path")"; then
      : # labels_json set by _gh_with_fallback
    fi
    if [[ -n "$labels_json" ]]; then
      # #760: plan-tier:change is the authoritative routing signal and takes
      # priority over any type:* label. The project-board classifier (#211)
      # stamps plan-tier:change on change issues, but those same issues also
      # carry a work-kind type:* label (e.g. type:fix, type:feat). The
      # earlier #539 logic only consulted plan-tier:change when *no* type:*
      # label was present, so an issue labelled BOTH type:fix AND
      # plan-tier:change resolved to type:fix, routed to the po-agent, failed
      # the spec-folder gate (change-orchestrate owns its own folder), fell
      # into the auto-seed change no-op, and — as first-in-queue — stalled the
      # whole FIFO queue forever. Checking plan-tier:change FIRST closes that
      # gap: the tier label decides the pipeline; type:* only decides routing
      # when no tier override is present.
      if jq -e '[.labels[].name] | contains(["plan-tier:change"])' \
          <<<"$labels_json" >/dev/null 2>&1; then
        issue_type="type:change"
      else
        issue_type="$(jq -r \
          '[.labels[].name | select(startswith("type:"))] | first // ""' \
          <<<"$labels_json" 2>/dev/null || true)"
      fi
    fi
  fi

  # ---------------------------------------------------------------------------
  # Pre-dispatch spec-folder gate (#445) — verify the derived KEY resolves to
  # an actual specs/ folder BEFORE forking the po-agent subprocess. A
  # truncated or mismatched KEY (e.g. a 40-char title-derived slug that cuts
  # mid-word) produces a KEY that has no matching specs/<KEY>*/ folder; the
  # po-agent would start, fail Step 1, and HALT-006 — wasting the dispatch
  # slot. This gate catches the mismatch here and routes to auto-seed
  # instead, consuming no dispatch slot.
  #
  # The gate fires only when key is non-empty (a failed derivation already
  # logged the "could not derive KEY" WARN above and leaves key=""; the
  # existing path for that case is unchanged) AND the issue is not type:change
  # (change-orchestrate creates its own spec folder in Step 0.5 — the gate
  # does not apply to that path).
  #
  # SPECS_DIR (line 239) is the offline test seam: point it at a temp dir to
  # exercise the miss or hit path in smoke tests — the same override used by
  # _spec_folder_for_key, in_flight_issues, _is_orphan_issue, and the
  # auto-seed helpers throughout this file (see MAKATO_LOOP_GATE_LABELS_OVERRIDE
  # for the analogous pattern in the dispatch gate block below).
  # ---------------------------------------------------------------------------
  if [[ -n "$key" && "$issue_type" != "type:change" \
        && "$dry_run" != "--dry-run" \
        && "${MAKATO_LOOP_DRY_DISPATCH:-0}" != "1" ]] \
      && ! _spec_folder_for_key "$key" >/dev/null 2>&1; then
    echo "loop: WARN — pre-dispatch: KEY '${key}' matches no specs/ folder for #${issue}; routing to auto-seed, slot not consumed" >&2
    _auto_seed_unprepared "$issue" 2>/dev/null || true
    _patch_status '.active_workflow' 'null'
    return 0
  fi

  # ---------------------------------------------------------------------------
  # Pre-dispatch plan guard — validate plan.md and attempt build-refine
  # recovery before launching the PO-agent. Safety net: never blocks dispatch.
  # Skipped for type:change (no spec folder) and dry-run.
  # ---------------------------------------------------------------------------
  local _pdpg_tuple="skipped:false:n/a"
  if [[ "$issue_type" != "type:change" \
        && "$dry_run" != "--dry-run" \
        && "${MAKATO_LOOP_DRY_DISPATCH:-0}" != "1" \
        && -n "$key" ]]; then
    # Guard returns "<verdict>:<refine_attempted>:<refine_outcome>" — parse in
    # one shot to avoid a redundant validate-plan-body.sh invocation.
    _pdpg_tuple="$(_pre_dispatch_plan_guard "$key")"
  fi
  local _pdpg_verdict="${_pdpg_tuple%%:*}"
  local _pdpg_rest="${_pdpg_tuple#*:}"
  local _pdpg_refine_attempted="${_pdpg_rest%%:*}"
  local _pdpg_refine_outcome="${_pdpg_rest#*:}"
  _patch_status '.pre_dispatch_plan_guard' \
    "$(jq -n \
      --arg verdict "$_pdpg_verdict" \
      --argjson refine_attempted "$([[ "$_pdpg_refine_attempted" == "true" ]] && echo true || echo false)" \
      --arg refine_outcome "$_pdpg_refine_outcome" \
      '{verdict: $verdict, refine_attempted: $refine_attempted, refine_outcome: $refine_outcome}')"

  if [[ "$dry_run" == "--dry-run" ]]; then
    if [[ "$issue_type" == "type:change" ]]; then
      echo "loop: --dry-run — would exec: $CLAUDE_BIN --dangerously-skip-permissions -p \"<dispatch makato-change:orchestrate --autonomous for issue #${issue} KEY=${key} REPO=${MAKATO_LOOP_DISPATCH_REPO:-} REPO_ROOT=${REPO_ROOT}>\"" >&2
    else
      echo "loop: --dry-run — would exec: $CLAUDE_BIN --dangerously-skip-permissions -p \"<dispatch makato-orchestrate:po-agent for issue #${issue} KEY=${key} REPO=${MAKATO_LOOP_DISPATCH_REPO:-} BRANCH=${branch} REPO_ROOT=${REPO_ROOT}>\"" >&2
    fi
    echo "loop: --dry-run — would claim #${issue} (board Ready → In progress, CAS)" >&2
    echo "loop: --dry-run — would assign #${issue} to ${ASSIGNEE} (board → In progress)" >&2
    _patch_status '.active_workflow' 'null'
    return 0
  fi

  # ---------------------------------------------------------------------------
  # Dispatch gate (#318/#355) — read-only checks that refuse to dispatch a
  # Ready issue that is already merged or in-flight. Skipped entirely when
  # GATE_DISABLE=1. Every skip path: logs attribution, increments
  # gate_skips_total, clears active_workflow, returns 0 (clean skip).
  # Best-effort: any read failure logs WARN and proceeds (does not increment
  # gate_skips_total). Gate never writes board Status — D5 no-op invariant.
  # ---------------------------------------------------------------------------
  # gate_is_orphan is declared outside the GATE_DISABLE block so the tier 3/4
  # label-board conflict check (which runs after _claim_board_card) can also
  # skip when the issue is an orphan (#357 D6).
  local gate_is_orphan=0
  if [[ "$GATE_DISABLE" != "1" ]]; then
    # Task 1 — Consolidated label+title fetch (D10 enabler).
    # One gh call for exclusion-label veto; result also available for S2/tier-4.
    # Offline override: MAKATO_LOOP_GATE_LABELS_OVERRIDE points to a canned file.
    # Task 6 — Best-effort: a read failure sets gate_labels_json="" and logs WARN;
    # the gate skips the veto check and proceeds (no gate_skips_total increment).
    local repo="${MAKATO_LOOP_DISPATCH_REPO:-}"
    local gate_labels_json=""
    if [[ -n "${MAKATO_LOOP_GATE_LABELS_OVERRIDE:-}" ]]; then
      if ! gate_labels_json="$(cat "${MAKATO_LOOP_GATE_LABELS_OVERRIDE}" 2>/dev/null)"; then
        echo "loop: WARN — gate: could not read MAKATO_LOOP_GATE_LABELS_OVERRIDE ('${MAKATO_LOOP_GATE_LABELS_OVERRIDE}'); proceeding" >&2
        gate_labels_json=""
      fi
    else
      # #447: REST fallback for the gate label+title fetch. `gh api …/issues/N`
      # exposes `.labels[].name` and `.title` just like `gh issue view
      # --json labels,title`, so the downstream veto/tier-4 consumers are
      # shape-agnostic. On wrapper failure gate_labels_json stays empty and the
      # gate proceeds (unchanged best-effort WARN+proceed behaviour).
      local gate_rest_path
      if [[ -n "$repo" ]]; then
        gate_rest_path="repos/${repo}/issues/${issue}"
      else
        gate_rest_path="repos/{owner}/{repo}/issues/${issue}"
      fi
      local -a gate_repo_flag=()
      [[ -n "$repo" ]] && gate_repo_flag=(--repo "$repo")
      if ! gate_labels_json="$(_gh_with_fallback "gate labels #${issue}" \
          issue view "$issue" "${gate_repo_flag[@]}" --json labels,title \
          -- api "$gate_rest_path")"; then
        echo "loop: WARN — gate: could not fetch labels for #${issue}; proceeding" >&2
        gate_labels_json=""
      fi
    fi

    # Orphan detection (D6, #357): classify before tiers 1-4 so the degraded
    # path can skip tiers 3/4. An orphan has no created-issues.json in any
    # specs/ folder referencing this issue (missing / zero-byte / malformed
    # counted as orphan per D11). _is_orphan_issue uses SPECS_DIR override for
    # offline testing.
    if _is_orphan_issue "$issue"; then
      gate_is_orphan=1
    fi

    # Task 3 — Exclusion-label veto (D4).
    # Applies to both orphan and non-orphan paths: an issue carrying a hard-stop
    # exclusion label (needs-human-review, status:blocked, etc.) must never
    # dispatch regardless of orphan status.
    local gate_veto_label=""
    if [[ -n "$gate_labels_json" ]]; then
      gate_veto_label="$(jq -r \
        --argjson excl "$(printf '%s\n' $_PROMOTE_EXCLUSION_LABELS | jq -R . | jq -s .)" \
        '[.labels[].name] as $lbls | $excl[] | select(. as $e | $lbls | any(. == $e)) | .' \
        <<<"$gate_labels_json" 2>/dev/null | head -1 || true)"
    fi
    if [[ -n "$gate_veto_label" ]]; then
      echo "loop: gate — #${issue} carries exclusion label '${gate_veto_label}'; skip dispatch" >&2
      _increment_gate_skips
      _patch_status '.active_workflow' 'null'
      return 0
    fi

    # Task 4 — Tier 1: merged-PR check.
    # Runs for BOTH orphan and non-orphan paths (tier 1 MUST still win — D6).
    # Call _reap_pr_merged (honours MAKATO_LOOP_REAP_GH_OVERRIDE offline override).
    # Guard: skip when branch is empty (key derivation failed) — an empty --head
    # flag on `gh pr list` would return all recently-merged PRs, producing a false
    # positive. Best-effort (Task 6): _reap_pr_merged returns empty on any read
    # failure (the function uses 2>/dev/null || true internally); gate proceeds.
    local gate_merged_pr=""
    if [[ -n "$branch" ]]; then
      gate_merged_pr="$(_reap_pr_merged "$repo" "$branch" 2>/dev/null || true)"
    fi
    if [[ -n "$gate_merged_pr" ]]; then
      echo "loop: gate — #${issue} branch '${branch}' already merged (PR #${gate_merged_pr}); skip dispatch + stamp needs-human-review" >&2
      gh issue edit "$issue" --repo "$repo" --add-label needs-human-review 2>/dev/null || true
      _post_halt_comment "HALT-014" "$issue" "$repo" \
        --reason "Branch '${branch}' was already merged (PR #${gate_merged_pr}) but the issue is still open — dispatch was skipped to avoid duplicate work." \
        --what-to-fix "Verify PR #${gate_merged_pr} delivered this issue; if so close the issue and move the board card to Done. Otherwise open a fresh branch. Then remove needs-human-review." || true
      _increment_gate_skips
      _patch_status '.active_workflow' 'null'
      return 0
    fi

    # Task 4 — Tier 2: in-flight workflow-state check.
    # Runs for BOTH orphan and non-orphan paths (D6).
    # Re-assert in_flight_issues for the direct `dispatch <n>` entry point.
    # Task 6 — Best-effort: in_flight_issues uses 2>/dev/null per-file; any
    # scan failure returns empty so the gate proceeds.
    local gate_inflight=""
    gate_inflight="$(in_flight_issues 2>/dev/null | grep -x "$issue" || true)"
    if [[ -n "$gate_inflight" ]]; then
      echo "loop: gate — #${issue} has a non-done workflow-state (in-flight); skip dispatch" >&2
      _increment_gate_skips
      _patch_status '.active_workflow' 'null'
      return 0
    fi

    # Degraded gate path (D6, #357): orphan proceeds after tiers 1+2.
    # Emit audit log and increment counter; skip tiers 3/4 (label-board
    # conflict check requires created-issues.json context that orphans lack).
    if [[ "$gate_is_orphan" -eq 1 ]]; then
      local gate_issue_url="https://github.com/${repo}/issues/${issue}"
      echo "loop: gate — orphan: ${gate_issue_url} — D6 tiers 1-2 enforced, board/label drift not checked" >&2
      _increment_orphan_dispatches
    fi
  fi
  # End dispatch gate.

  # Synchronous board claim (#259) — the compare-and-set that makes the board
  # the cross-worktree LOCK. Runs BEFORE the async assign so a lost CAS costs
  # nothing: if _claim_board_card returns 1 the card is no longer at the
  # dispatch Status (a second loop session already claimed it), so we clear
  # active_workflow and return 0 (a clean skip, NOT an error — the outer
  # cmd_run treats it like an empty pick and moves on next tick). Skipped
  # under --dry-run above (inspection mode never mutates the board).
  if ! _claim_board_card "$issue"; then
    _patch_status '.active_workflow' 'null'
    return 0
  fi

  # Tier 3/4 — label-vs-board conflict gate (#356). Runs immediately after the
  # CAS succeeds (we have the board-observed Status and gate_labels_json already
  # in scope from the dispatch gate block above). On conflict: skip dispatch,
  # stamp needs-human-review (best-effort), increment gate_skips_total, and
  # return 0 (clean skip — same contract as tiers 1/2). The board Status is NOT
  # written (D5 no-op invariant). Skipped when gate_labels_json is empty (read
  # failure already logged a WARN in the dispatch gate block — best-effort).
  # Also skipped for orphan issues (#357 D6): tiers 3/4 require created-issues.json
  # context that orphans lack; the degraded gate already ran tiers 1+2 above.
  if [[ "$GATE_DISABLE" != "1" && -n "$gate_labels_json" && "$gate_is_orphan" -eq 0 ]]; then
    local claimed_status="${MAKATO_LOOP_ITEM_STATUS:-${MAKATO_LOOP_DISPATCH_STATUS:-Ready}}"
    # Use the CAS-observed status exported by _claim_board_card when available.
    [[ -n "${LOOP_LAST_CLAIMED_STATUS:-}" ]] && claimed_status="$LOOP_LAST_CLAIMED_STATUS"
    if _label_board_conflict "$gate_labels_json" "$claimed_status"; then
      echo "loop: gate — #${issue} label-board conflict (labels vs board '${claimed_status}'); skip dispatch + stamp needs-human-review" >&2
      _label_conflict_stamp "$issue"
      _increment_gate_skips
      echo "loop: gate-skip #${issue} reason=label-board-conflict gate_skips_total=$(_read_status | jq -r '.gate_skips_total // 0')" >&2
      _patch_status '.active_workflow' 'null'
      return 0
    fi
  fi

  # Assign the issue to the dispatch actor → fires issues.assigned →
  # project-board-sync.yml moves the board Ready → In progress (#33). Done
  # for BOTH the DRY_DISPATCH test path and the real fork so the smoke
  # suite can assert on it; skipped only under --dry-run above (inspection
  # mode never mutates GitHub). Best-effort — never blocks dispatch.
  # With the #259 claim above already writing In progress, the assign is now
  # a belt-and-braces trigger (idempotent add-assignee; board sync is
  # forward-only, so a late webhook never rolls the claimed card back).
  _assign_issue "$issue"

  # Test hook — exercise the full state-machine without forking a subprocess.
  # .last_dispatch_issue is already stamped by the unconditional block
  # above (#171); this branch only needs to clear active_workflow.
  if [[ "${MAKATO_LOOP_DRY_DISPATCH:-0}" == "1" ]]; then
    _patch_status '.active_workflow' 'null'
    return 0
  fi

  # Test hook — spawn a genuinely-hung subprocess so the watchdog has
  # something to reap. Value is the command to exec (usually a `sleep`).
  # Used exclusively by loop-smoke-tests.sh scenarios T12–T14.
  local child_cmd=""
  if [[ -n "${MAKATO_LOOP_STALL_TEST_CMD:-}" ]]; then
    child_cmd="${MAKATO_LOOP_STALL_TEST_CMD}"
  fi

  local rc=0
  # Prepare log capture + watchdog UNLESS the operator opted out
  # (MAKATO_LOOP_STALL_DISABLE=1). See #164 for the design.
  local log_file="" watchdog_pid=""
  if [[ "${MAKATO_LOOP_STALL_DISABLE:-0}" != "1" ]]; then
    log_file="$STATE_DIR/dispatch-${issue}.log"
    : >"$log_file"
  fi
  # Single-threaded by construction: this call blocks until the PO-agent
  # subprocess exits. The next outer iteration polls fresh.
  #
  # The prompt explicitly delegates to the `makato-orchestrate:po-agent`
  # subagent via the Task tool. The po-agent owns the outer-loop contract
  # and threads `--autonomous` into every downstream `makato-build` skill
  # dispatch (see po-agent.md § "Autonomous Execution" and
  # plugins/makato-build/AUTONOMOUS-MODE.md). Without this delegation, the
  # top-level Claude session picks whichever skill it thinks matches
  # "drive the issue" and invokes it in default interactive mode — which
  # in a headless `claude -p` subprocess deadlocks on the first
  # AskUserQuestion prompt (see #160).
  #
  # `MAKATO_HEADLESS=1` is exported as a defensive belt: if the top-level
  # session or any downstream skill ignores the delegation prompt above
  # and falls back to interactive mode, the makato-build Step 1b guard
  # (see plugins/makato-build/AUTONOMOUS-MODE.md § "Defensive-headless
  # guard") HALTs with MISSING_INPUT instead of hanging on
  # AskUserQuestion. This is the #163 fix; the #160 fix (delegation
  # prompt) remains the primary defence.

  # Export MAKATO_ORCHESTRATE_SHARED so child sessions (po-agent,
  # change-orchestrate) can locate shared scripts (worktree.sh, etc.)
  # without relying on CWD. The child's CWD is the makato repo root, which
  # is the same as the loop's CWD — but making it explicit avoids breakage
  # if the child ever cd's into a worktree or target repo.
  MAKATO_ORCHESTRATE_SHARED="$(git rev-parse --show-toplevel)/plugins/makato-orchestrate/shared"
  if [[ -d "$MAKATO_ORCHESTRATE_SHARED" ]]; then
    export MAKATO_ORCHESTRATE_SHARED
  else
    echo "[loop WARN] MAKATO_ORCHESTRATE_SHARED path not found: $MAKATO_ORCHESTRATE_SHARED" >&2
  fi

  local dispatch_prompt
  if [[ "$issue_type" == "type:change" ]]; then
    # Route to makato-change:orchestrate --autonomous. No plan.md required —
    # the change pipeline owns its own spec-folder lifecycle.
    dispatch_prompt="Use the Skill tool to invoke the makato-change:orchestrate skill with args '${key} --autonomous'. Required env: ISSUE_NUMBER=${issue} ISSUE_KEY=${key} REPO=${MAKATO_LOOP_DISPATCH_REPO:-} REPO_ROOT=${REPO_ROOT}. MAKATO_HEADLESS=1 is already exported. The skill owns the analyze→design→execute→resolve-review loop and writes change-state-${issue}.json + a workflow-state-${issue}.json loop-compat stub. Return R1 envelope verbatim."
  else
    dispatch_prompt="Use the Task tool to dispatch the makato-orchestrate:po-agent subagent to drive GitHub issue #${issue} to a merged PR. Pass the po-agent's required inputs verbatim: ISSUE_NUMBER=${issue} KEY=${key} REPO=${MAKATO_LOOP_DISPATCH_REPO:-} BRANCH=${branch} REPO_ROOT=${REPO_ROOT}. The po-agent owns the outer loop, workflow-state, and all makato-build --autonomous dispatch; do not invoke makato-build or makato-plan skills directly from this session. Return the po-agent's final R1 envelope verbatim."
  fi

  if [[ -n "$log_file" ]]; then
    # Redirect both stdout+stderr to the log file so the watchdog gets
    # mtime updates on any child output. Operators can `tail -f` the log
    # (or the loop-status.json watchdog fields) — mixing `tee` in-band
    # would require capturing the source PID out of a pipeline, which
    # bash makes awkward and non-portable.
    if [[ -n "$child_cmd" ]]; then
      # Test path: spawn the stall stand-in directly.
      # shellcheck disable=SC2086
      $child_cmd >"$log_file" 2>&1 &
      local child_pid=$!
    else
      # Production path: real claude invocation.
      #
      # Two flags work together to keep a long unattended build alive:
      #
      #   --output-format stream-json --verbose
      #     The dispatch prompt delegates to the po-agent via the Task
      #     tool, which in claude >= 2.1.x runs the subagent as a
      #     BACKGROUND task. The plain `text` format flushes nothing until
      #     the whole session ends, so the log mtime stays frozen for the
      #     entire run and the liveness watchdog stall-kills the po-agent
      #     mid-build (the #146 regression). `stream-json --verbose` emits
      #     a JSON event line per tool call / thinking step, giving the
      #     watchdog a live mtime signal. (`stream-json` requires
      #     `--verbose` under `--print`.) The trade-off: the log holds
      #     structured JSON, not prose — the final R1 envelope is the
      #     `result` field of the terminal `{"type":"result",...}` line.
      #
      #   CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0
      #     Without this, the top-level `-p` session (which only dispatches,
      #     then waits on the background po-agent) terminates the po-agent
      #     after the default 600 s background-wait ceiling — killing a
      #     full build cycle (5 tasks, TDD, PR) 10 min in. `0` = wait
      #     indefinitely; the loop's own watchdog + HALT poll remain the
      #     bounding mechanisms.
      CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
        MAKATO_HEADLESS=1 "$CLAUDE_BIN" --dangerously-skip-permissions \
        --output-format stream-json --verbose \
        -p "$dispatch_prompt" >"$log_file" 2>&1 &
      local child_pid=$!
    fi
    # Spawn watchdog against the child's PID.
    _watchdog_poll "$log_file" "$child_pid" "$issue" &
    watchdog_pid=$!
    # Signal-safe reap: if this dispatch shell is TERM'd/INT'd while blocked
    # on `wait "$child_pid"` below, bash runs the default signal action and
    # exits BEFORE the reap block — orphaning the watchdog grandchild, which
    # is reparented to init and keeps calling _patch_status against the shared
    # loop-status.json (resurrecting a just-cleared active_workflow via jq's
    # null-path autovivification). That leaked writer corrupts a later
    # dispatch's state — the source of the T30 loop-smoke-test flake (#312).
    # Trapping TERM/INT reaps both children in-scope (dynamic scoping makes
    # the locals visible here) before exiting, so a kill of the dispatch PID
    # cascades to the watchdog instead of orphaning it.
    trap 'kill -TERM "$watchdog_pid" "$child_pid" 2>/dev/null || true; wait "$watchdog_pid" "$child_pid" 2>/dev/null || true; exit 143' TERM INT
    # Block on child. `wait` returns the child's exit status if we name it.
    wait "$child_pid" || rc=$?
    # #616: capture the Claude session UUID from the dispatch log and persist
    # it to workflow-state as last_session_id, so a later recovery (either the
    # loop's _stall_resume or context-handoff.sh's HALT-007B resume) can pass a
    # VALID `claude --resume <uuid>` argument instead of the spec KEY (which
    # --resume rejects — it requires a session UUID). Captured for every
    # dispatch, not just failing ones, because the UUID must already be on disk
    # by the time any recovery path runs. Best-effort — a missing UUID or a
    # patch failure never aborts the dispatch; the recovery paths degrade
    # gracefully (skip resume / HALT-007 fallback) when last_session_id is null.
    if [[ -n "$log_file" && -n "${key:-}" ]]; then
      local _sid
      _sid="$(_extract_session_id "$log_file")"
      if [[ -n "$_sid" ]]; then
        local _ws_capture
        _ws_capture="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/shared/workflow-state.sh"
        if [[ -x "$_ws_capture" ]]; then
          "$_ws_capture" patch "$key" "$issue" '.last_session_id' "\"$_sid\"" >/dev/null 2>&1 || true
        fi
      fi
    fi
    # Reap watchdog — it either exited already (kill path or child-exit)
    # or is between polls; killing is a no-op in the former case.
    if [[ -n "$watchdog_pid" ]] && kill -0 "$watchdog_pid" 2>/dev/null; then
      kill -TERM "$watchdog_pid" 2>/dev/null || true
      wait "$watchdog_pid" 2>/dev/null || true
    fi
    # Normal completion — drop the signal trap so it cannot fire against
    # stale PIDs during the rest of the function.
    trap - TERM INT
    # Stall-restart wiring (#444): if the watchdog killed the child, call
    # _stall_restart to classify and route. On transient (returns 0), the
    # outer cmd_run loop continues normally. On no_progress (returns 1),
    # propagate the failure rc so the loop does not re-queue the issue.
    if [[ "${MAKATO_LOOP_STALL_DISABLE:-0}" != "1" ]]; then
      local _killed_issue
      _killed_issue="$(_read_status | jq -r '.last_watchdog_kill.issue // empty' 2>/dev/null || true)"
      local _killed_flag
      _killed_flag="$(_read_status | jq -r '.active_workflow.killed_by_watchdog // false' 2>/dev/null || echo false)"
      # active_workflow.killed_by_watchdog was true before the watchdog cleared
      # it; we read the preserved snapshot from last_watchdog_kill.
      local _wkill_flag
      _wkill_flag="$(_read_status | jq -r '
        if .last_watchdog_kill.issue == '"$issue"' then
          "true"
        else
          "false"
        end' 2>/dev/null || echo false)"
      if [[ "$_wkill_flag" == "true" ]]; then
        # Derive spec folder from SPECS_DIR + issue's workflow-state file.
        local _spec_dir=""
        local _wf
        _wf="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
          -name "workflow-state-${issue}.json" 2>/dev/null | head -1)"
        if [[ -n "$_wf" ]]; then
          _spec_dir="$(dirname "$_wf")"
        fi
        _stall_restart "$issue" "$_spec_dir" "$log_file" || rc=$?
      else
        # Stall-resume wiring (#531): child exited without a watchdog kill.
        # Classify the dispatch log; if the run was incomplete or errored
        # and did NOT emit a HALT code, attempt a --resume re-entry.
        local _dispatch_verdict
        _dispatch_verdict="$(_parse_dispatch_result "$log_file")"
        if [[ "$_dispatch_verdict" == "incomplete" || "$_dispatch_verdict" == "errored" ]]; then
          # Check whether the run ended on a HALT code (grep orchestrate.jsonl
          # for the most recent step:halt entry). If present, skip resume —
          # the HALT classification path owns the issue.
          local _spec_dir_r=""
          local _wf_r
          _wf_r="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
            -name "workflow-state-${issue}.json" 2>/dev/null | head -1)"
          if [[ -n "$_wf_r" ]]; then
            _spec_dir_r="$(dirname "$_wf_r")"
          fi
          local _halt_emitted="false"
          if [[ -f "${_spec_dir_r}/orchestrate.jsonl" ]]; then
            if grep -q '"step":"halt"' "${_spec_dir_r}/orchestrate.jsonl" 2>/dev/null; then
              _halt_emitted="true"
            fi
          fi
          if [[ "$_halt_emitted" != "true" ]]; then
            _stall_resume "$issue" "$key" "$_spec_dir_r" "$log_file" || rc=$?
            # #687: api_error recovery — reset board card to Ready when dispatch
            # failed before writing workflow-state (session never started).
            if [[ "$rc" -ne 0 ]]; then
              local _wf_absent="true"
              local _wf_check
              _wf_check="$(find "${SPECS_DIR:-$REPO_ROOT/specs}" -maxdepth 2 \
                -name "workflow-state-${issue}.json" 2>/dev/null | head -1)"
              [[ -n "$_wf_check" ]] && _wf_absent="false"
              if [[ "$_wf_absent" == "true" ]]; then
                echo "loop: api-error: #$issue exited rc=$rc with no workflow-state — resetting board to Ready" >&2
                _reset_board_card_to_ready "$issue" || true
              fi
            fi
          fi
        fi
      fi
    fi
  else
    # Opt-out path (MAKATO_LOOP_STALL_DISABLE=1) — legacy behaviour, no
    # log capture, no watchdog. No streaming needed (nothing reads the
    # log), but the background-wait ceiling still applies: without
    # CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 the top-level session kills
    # the background po-agent after 600 s. `text` format is fine here
    # since the operator watches the terminal directly.
    if [[ -n "$child_cmd" ]]; then
      # shellcheck disable=SC2086
      $child_cmd || rc=$?
    else
      CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
        MAKATO_HEADLESS=1 "$CLAUDE_BIN" --dangerously-skip-permissions \
        --output-format text \
        -p "$dispatch_prompt" || rc=$?
    fi
  fi
  _emit_langfuse_trace "$log_file" "$issue"
  _patch_status '.active_workflow' 'null'
  return $rc
}

# ---------------------------------------------------------------------------
# _acquire_run_mutex — layer-1 defence against concurrent loop.sh
# instances (#172). Writes $$ to $PIDFILE and installs an EXIT trap to
# remove it. Refuses to start when the pidfile names a live PID unless
# `--force` is passed; a stale pidfile (PID gone) is reclaimed silently.
#
# The check-and-write is not atomic across processes — two operators
# starting a run in the same millisecond can both pass the kill -0
# probe. This is acceptable: the actual damage from #172 came from
# accidentally-parallel installs (plugin-cache vs. working-tree), not
# from a simultaneous double-invoke race. `flock` is not available on
# stock macOS and shims add a dependency for a vanishingly rare case;
# operators who want stricter guarantees run one instance under
# `tmux` / `nohup` and rely on that shell's job control.
#
# Args: <force-flag>  (non-empty = --force was passed)
# Exit codes:
#   0  — pidfile acquired, EXIT trap installed
#   3  — refused, another live instance already owns the pidfile
# ---------------------------------------------------------------------------
_acquire_run_mutex() {
  local force="$1"
  if [[ -f "$PIDFILE" ]]; then
    local existing_pid
    existing_pid="$(cat "$PIDFILE" 2>/dev/null || echo "")"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      if [[ -z "$force" ]]; then
        echo "loop: another instance is running (PID $existing_pid, pidfile $PIDFILE)" >&2
        echo "loop: pass --force to reclaim, or stop the incumbent (kill -TERM $existing_pid)" >&2
        return 3
      fi
      echo "loop: --force reclaiming PID $existing_pid (SIGTERM, ${FORCE_GRACE_SECS}s grace, then SIGKILL)" >&2
      kill -TERM "$existing_pid" 2>/dev/null || true
      local waited=0
      while [[ $waited -lt $FORCE_GRACE_SECS ]] && kill -0 "$existing_pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
      done
      if kill -0 "$existing_pid" 2>/dev/null; then
        echo "loop: --force SIGKILL'ing PID $existing_pid (still alive after ${FORCE_GRACE_SECS}s)" >&2
        kill -KILL "$existing_pid" 2>/dev/null || true
      fi
    else
      # Stale pidfile — reclaim silently. Common after crash or kill -9.
      if [[ -n "$existing_pid" ]]; then
        echo "loop: stale pidfile (PID $existing_pid gone); reclaiming $PIDFILE" >&2
      fi
    fi
  fi
  echo "$$" >"$PIDFILE"
  # Preserve any existing EXIT trap (tests may compose) by chaining.
  trap 'rm -f "$PIDFILE"' EXIT
  return 0
}

# ---------------------------------------------------------------------------
# _stamp_startup_audit — layer-2 defence (#172). Records this
# instance's identity into loop-status.json so an operator seeing
# multiple loop processes in `ps` can tell which one owns the state
# dir. Distinct from the run-metadata fields (status_name, interval)
# which describe the poll cadence; startup_audit describes the
# process.
#
# Args: <status-name> <interval> <dry-run-flag>
# ---------------------------------------------------------------------------
_stamp_startup_audit() {
  local status_name="$1"
  local interval="$2"
  local dry_run="$3"
  local now script_path ppid
  now="$(_now)"
  # $0 is the script as invoked; canonicalise so a symlinked plugin-
  # cache path resolves to its real disk location. macOS `readlink`
  # lacks `-f`; the python fallback matches worktree.sh's convention.
  script_path="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$0" 2>/dev/null || echo "$0")"
  ppid="$(ps -o ppid= -p "$$" 2>/dev/null | tr -d ' ' || echo "")"
  local audit
  audit="$(jq -n \
    --arg started_at "$now" \
    --arg script_path "$script_path" \
    --argjson pid "$$" \
    --arg ppid "$ppid" \
    --arg pidfile "$PIDFILE" \
    --arg status_name "$status_name" \
    --argjson interval "$interval" \
    --arg dry_run "$dry_run" \
    '{
       started_at: $started_at,
       script_path: $script_path,
       pid: $pid,
       ppid: (if $ppid == "" then null else ($ppid|tonumber) end),
       pidfile: $pidfile,
       status_name: $status_name,
       interval_seconds: $interval,
       dry_run: ($dry_run != "")
     }')"
  _patch_status '.startup_audit' "$audit"
}

# ---------------------------------------------------------------------------
# _reshape_pass — pre-poll reshape pass (#350, epic #319).
#
# Detects issues at board Status = Needs Planning (or `needs-reshape` label as
# a degraded fallback when the board option is absent), honours the kill-switch,
# and for each candidate:
#   - Reads `reshape_cycles` from workflow-state-<issue>.json via workflow-state.sh
#   - If at ceiling (>= MAKATO_MAX_RESHAPE_CYCLES, default 2): fires HALT-013,
#     applies needs-human-review, appends halt_audit, writes orchestrate.jsonl — no dispatch.
#   - Below ceiling: dispatches `makato-plan:decompose <slug> --autonomous` with
#     RESHAPE_REQUEST pointing at reshape-request.json, then `to-issues
#     --autonomous`.  On full success: increments reshape_cycles, removes
#     needs-reshape, sets board Status=Ready, and logs step:"reshape" status:"ok"
#     to orchestrate.jsonl.  On failure: leaves Needs Planning, applies
#     needs-human-review, logs status:"error".
#
# Feature-flagged: MAKATO_LOOP_RESHAPE_ENABLED (default "0"). When disabled
# the function returns 0 immediately as a no-op.
#
# Test hooks (offline):
#   MAKATO_LOOP_RESHAPE_OVERRIDE     path to a JSON file of the form
#       [{"number":<N>,"key":"<KEY>"}] used instead of the real board poll.
#       When set, no `gh project item-list` call is made.
#   MAKATO_LOOP_RESHAPE_TEST_CMD     command string eval'd in place of the
#       real Claude dispatch. Must exit 0 for the success path and non-zero
#       for the failure path. Overrides BOTH the decompose and to-issues
#       dispatches (loop tests cannot invoke Claude headlessly). When absent
#       the real dispatch path executes.
#   MAKATO_LOOP_LABEL_TEST_FILE      reused from other passes: append
#       "label #N needs-human-review" or "remove-label #N needs-reshape" etc.
#       instead of calling `gh issue edit`.
#
# All gh / dispatch failures are best-effort per-candidate: a failure logs a
# WARN and the pass continues to the next candidate. The function always
# returns 0 (never blocks the tick).
# ---------------------------------------------------------------------------
_reshape_pass() {
  # Guard 1: feature flag.
  if [[ "${MAKATO_LOOP_RESHAPE_ENABLED:-0}" != "1" ]]; then
    return 0
  fi

  echo "loop: reshape-pass — starting (#350)" >&2

  # Guard 2: kill-switch.
  if ! cmd_check_halt; then
    echo "loop: reshape-pass — HALT file present, skipping pass" >&2
    return 0
  fi

  local repo="${MAKATO_LOOP_DISPATCH_REPO:-}"
  local -a repo_flag=()
  [[ -n "$repo" ]] && repo_flag=(--repo "$repo")

  local max_cycles="${MAKATO_MAX_RESHAPE_CYCLES:-2}"

  # Guard 3: discover Needs Planning candidates.
  # Primary: board Status = Needs Planning via MAKATO_LOOP_RESHAPE_OVERRIDE test
  # hook or real gh project item-list.
  # Fallback: gh issue list --label needs-reshape when board poll yields nothing.
  local candidates='[]'

  if [[ -n "${MAKATO_LOOP_RESHAPE_OVERRIDE:-}" ]]; then
    candidates="$(cat "${MAKATO_LOOP_RESHAPE_OVERRIDE}" 2>/dev/null || echo '[]')"
  else
    # Primary: board Status = Needs Planning using config-resolved option id.
    local needs_planning_option_id=""
    if [[ -f "$CONFIG_FILE" ]]; then
      needs_planning_option_id="$(jq -r '
        (.github_project.fields.status.options.needs_planning // empty),
        (.github_project.options.needs_planning // empty)
        | select(. != null and . != "null" and . != "")
        | .' "$CONFIG_FILE" 2>/dev/null | head -1 || true)"
    fi

    if [[ -n "$needs_planning_option_id" ]]; then
      local board_items
      board_items="$(_gh_project_item_list 2>/dev/null || echo '{"items":[]}')"
      candidates="$(jq -r --arg opt_id "$needs_planning_option_id" \
        '[.items[] | select(.content.type == "Issue") |
          select(.status_option_id == $opt_id or .status == "Needs Planning") |
          {number: .content.number, key: ""}]' \
        <<<"$board_items" 2>/dev/null || echo '[]')"
    fi

    # Fallback: label-based discovery when board yields nothing.
    if [[ "$(jq 'length' <<<"$candidates" 2>/dev/null || echo 0)" -eq 0 ]]; then
      local label_issues
      label_issues="$(gh issue list "${repo_flag[@]}" \
        --label "needs-reshape" --state open \
        --json number --limit 200 2>/dev/null || echo '[]')"
      candidates="$(jq '[.[] | {number: .number, key: ""}]' <<<"$label_issues" 2>/dev/null || echo '[]')"
    fi
  fi

  local count
  count="$(jq 'length' <<<"$candidates" 2>/dev/null || echo 0)"
  echo "loop: reshape-pass — $count candidate(s) to process" >&2

  local n key
  while IFS=$'\t' read -r n key; do
    [[ -n "$n" ]] || continue
    echo "loop: reshape-pass — processing issue #$n" >&2

    # Derive spec KEY if not provided by the fixture.
    if [[ -z "$key" || "$key" == "null" ]]; then
      key="$(_derive_key_for_issue "$n" "$repo" 2>/dev/null || true)"
    fi
    if [[ -z "$key" ]]; then
      echo "loop: WARN — reshape-pass #$n: cannot derive KEY; skipping" >&2
      continue
    fi

    # Read reshape_cycles from workflow-state.
    # Read the state file directly via SPECS_DIR (the loop-global variable),
    # which tests can override via SPECS_DIR env. workflow-state.sh uses its own
    # REPO_ROOT/specs so we resolve the path ourselves here.
    local state_file=""
    local spec_folder
    spec_folder="$(find "$SPECS_DIR" -maxdepth 1 -type d -name "${key}-*" 2>/dev/null | head -1)"
    [[ -z "$spec_folder" ]] && [[ -d "$SPECS_DIR/$key" ]] && spec_folder="$SPECS_DIR/$key"
    [[ -z "$spec_folder" ]] && spec_folder="$SPECS_DIR/$key"
    state_file="$spec_folder/workflow-state-${n}.json"
    local wf_json reshape_cycles
    wf_json="$([[ -f "$state_file" ]] && cat "$state_file" 2>/dev/null || echo '{}')"
    reshape_cycles="$(jq -r '.reshape_cycles // 0' <<<"$wf_json" 2>/dev/null || echo 0)"

    # Ceiling check — HALT-013: reshape oscillation guard (#351, epic #319).
    # When reshape_cycles >= max_cycles, the issue has already been reshaped as
    # many times as the operator allows. Dispatching again would risk an
    # unbounded plan→build→plan oscillation, so we stop and page the operator.
    #
    # Contract per halt-conditions.md HALT-013:
    #   1. Apply needs-human-review label.
    #   2. Append halt_audit entry with code "HALT-013" to workflow-state.
    #   3. Write orchestrate.jsonl step:"halt" line.
    if [[ "$reshape_cycles" -ge "$max_cycles" ]]; then
      echo "loop: reshape-pass — #$n HALT-013: reshape ceiling reached (reshape_cycles=${reshape_cycles} >= max=${max_cycles}); applying needs-human-review" >&2

      # Step 1: apply needs-human-review label.
      _apply_needs_human_review_reshape "$n" "${repo_flag[@]}"

      # Step 2: append halt_audit entry directly to the state file using the same
      # direct-write pattern as reshape_cycles increment (so SPECS_DIR overrides
      # in tests are honoured — workflow-state.sh resolves from REPO_ROOT/specs/
      # and would not find the test fixture file).
      local halt_data halt_ts
      halt_ts="$(_now)"
      halt_data="$(jq -cn \
        --argjson cycles "$reshape_cycles" \
        --argjson max "$max_cycles" \
        '{reshape_cycles: $cycles, max_reshape_cycles: $max, retryable: false, origin: "human"}')"
      if [[ -f "$state_file" ]]; then
        local patched_halt
        patched_halt="$(jq \
          --arg code "HALT-013" \
          --arg ts "$halt_ts" \
          --argjson data "$halt_data" \
          '.halt_audit += [{"code": $code, "ts": $ts, "data": $data}] | .updated_at = $ts' \
          "$state_file" 2>/dev/null || true)"
        [[ -n "$patched_halt" ]] && printf '%s\n' "$patched_halt" >"$state_file" 2>/dev/null || true
      fi

      # Step 3: write step:"halt" orchestrate.jsonl line.
      local spec_folder_halt=""
      spec_folder_halt="$(find "$SPECS_DIR" -maxdepth 1 -type d -name "${key}-*" 2>/dev/null | head -1 || true)"
      [[ -z "$spec_folder_halt" && -d "$SPECS_DIR/$key" ]] && spec_folder_halt="$SPECS_DIR/$key"
      [[ -z "$spec_folder_halt" ]] && spec_folder_halt="$SPECS_DIR/$key"
      mkdir -p "$spec_folder_halt" 2>/dev/null || true
      printf '%s\n' "$(jq -cn \
        --arg ts "$halt_ts" \
        --argjson issue "$n" \
        --argjson data "$halt_data" \
        '{"ts": $ts, "skill": "loop", "issue": $issue, "step": "halt", "status": "error", "data": ($data + {"halt_code": "HALT-013"})}')" \
        >> "$spec_folder_halt/orchestrate.jsonl" 2>/dev/null || true


      _log_reshape_result "$key" "$n" "error" "$reshape_cycles" "cycle-ceiling"
      continue
    fi

    # Dispatch: decompose Refine + to-issues.
    local dispatch_rc=0
    local reshape_request_path="$SPECS_DIR/$key/reshape-request.json"

    if [[ -n "${MAKATO_LOOP_RESHAPE_TEST_CMD:-}" ]]; then
      # Test hook: eval the override command inside a subshell so that an
      # `exit N` in the test command does not escape to the calling function.
      ( eval "${MAKATO_LOOP_RESHAPE_TEST_CMD}" ) >/dev/null 2>&1 || dispatch_rc=$?
    else
      # Production path: dispatch Claude headlessly.
      # Step 1: decompose in Refine mode.
      local decompose_prompt
      decompose_prompt="Use the Skill tool to invoke makato-plan:decompose for issue #${n} in Refine mode. ISSUE_NUMBER=${n} KEY=${key} REPO=${repo} REPO_ROOT=${REPO_ROOT} RESHAPE_REQUEST=${reshape_request_path}. --autonomous. Return R1 envelope verbatim."
      REPO_ROOT="$REPO_ROOT" \
      MAKATO_HEADLESS=1 \
        "$CLAUDE_BIN" --dangerously-skip-permissions -p "$decompose_prompt" \
        >/dev/null 2>&1 || dispatch_rc=$?

      # Step 2: to-issues (only when decompose succeeded).
      if [[ "$dispatch_rc" -eq 0 ]]; then
        local to_issues_prompt
        to_issues_prompt="Use the Skill tool to invoke makato-plan:to-issues for issue #${n}. ISSUE_NUMBER=${n} KEY=${key} REPO=${repo} REPO_ROOT=${REPO_ROOT}. --autonomous. Return R1 envelope verbatim."
        REPO_ROOT="$REPO_ROOT" \
        MAKATO_HEADLESS=1 \
          "$CLAUDE_BIN" --dangerously-skip-permissions -p "$to_issues_prompt" \
          >/dev/null 2>&1 || dispatch_rc=$?
      fi
    fi

    if [[ "$dispatch_rc" -ne 0 ]]; then
      echo "loop: reshape-pass — #$n dispatch failed (rc=${dispatch_rc}); applying needs-human-review" >&2
      _apply_needs_human_review_reshape "$n" "${repo_flag[@]}"
      _log_reshape_result "$key" "$n" "error" "$reshape_cycles" "dispatch-failed"
      continue
    fi

    # Success: increment reshape_cycles, remove needs-reshape label, set Status=Ready.
    local new_cycles=$(( reshape_cycles + 1 ))
    # Patch reshape_cycles directly in the state file (uses SPECS_DIR path so
    # SPECS_DIR overrides in tests are respected, same as the read above).
    if [[ -f "$state_file" ]]; then
      local patched_json
      patched_json="$(jq --argjson c "$new_cycles" '.reshape_cycles = $c' "$state_file" 2>/dev/null || true)"
      if [[ -n "$patched_json" ]]; then
        printf '%s\n' "$patched_json" >"$state_file" 2>/dev/null || true
      fi
    fi

    # Remove needs-reshape label.
    if [[ -n "${MAKATO_LOOP_LABEL_TEST_FILE:-}" ]]; then
      echo "remove-label #${n} needs-reshape" >>"$MAKATO_LOOP_LABEL_TEST_FILE"
    else
      gh issue edit "$n" "${repo_flag[@]}" --remove-label "needs-reshape" >/dev/null 2>&1 || true
    fi

    # Set board Status=Ready.
    local ready_option_id=""
    if [[ -f "$CONFIG_FILE" ]]; then
      ready_option_id="$(jq -r '.github_project.fields.status.options.ready // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    fi
    if [[ -n "$ready_option_id" ]]; then
      local status_field_id project_node_id host owner number
      status_field_id="$(jq -r '.github_project.fields.status.id // empty' "$CONFIG_FILE" 2>/dev/null || true)"
      project_node_id="$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE" 2>/dev/null || true)"
      host="$(jq -r '.github_project.host // "github.com"' "$CONFIG_FILE" 2>/dev/null || true)"
      owner="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE" 2>/dev/null || true)"
      number="$(jq -r '.github_project.number // empty' "$CONFIG_FILE" 2>/dev/null || true)"
      if [[ -n "$status_field_id" && -n "$project_node_id" && -n "$owner" && -n "$number" ]]; then
        # Find the board item id.
        local item_id=""
        # Cheap single-issue lookup (~1 GraphQL point) when we know the repo;
        # falls through to the expensive whole-board item-list otherwise.
        if [[ -n "$repo" ]]; then
          item_id="$(_project_item_id_for_issue "$host" "$owner" "$repo" "$n" "$project_node_id" || true)"
        fi
        if [[ -z "$item_id" ]]; then
          item_id="$(GH_HOST="$host" gh project item-list "$number" --owner "$owner" \
            --format json --limit 9999 2>/dev/null \
            | jq -r --argjson i "$n" '.items[] | select(.content.number == $i) | .id' 2>/dev/null \
            | head -1 || true)"
        fi
        if [[ -n "$item_id" ]]; then
          GH_HOST="$host" gh project item-edit \
            --id "$item_id" \
            --project-id "$project_node_id" \
            --field-id "$status_field_id" \
            --single-select-option-id "$ready_option_id" >/dev/null 2>&1 || true
        fi
      fi
    fi

    _log_reshape_result "$key" "$n" "ok" "$new_cycles" ""
    echo "loop: reshape-pass — #$n reshaped successfully (reshape_cycles=$new_cycles), Status=Ready" >&2

  done < <(jq -r '.[] | [.number, (.key // "")] | @tsv' <<<"$candidates" 2>/dev/null || true)

  echo "loop: reshape-pass — complete" >&2
  return 0
}

# ---------------------------------------------------------------------------
# _apply_needs_human_review_reshape <ISSUE_NUMBER> [REPO_FLAGS...] — helper
# that applies needs-human-review on a reshape-pass failure. Reuses the
# MAKATO_LOOP_LABEL_TEST_FILE hook so tests stay offline.
#
# Gates the label on `origin` from the latest halt_audit[] entry (#446).
# Classification rules (from halt-conditions.md § HALT classification table):
#   origin absent (legacy) → apply label (backward-compat)
#   origin == "human"      → apply label
#   origin == "auto"       → skip label (self-handling; no operator needed)
#   origin == "transient"  → skip label (may resolve without operator action)
#
# State file resolution uses SPECS_DIR (the loop-global variable, same pattern
# as _reshape_pass) so SPECS_DIR overrides in tests are honoured.
#
# Test hook: MAKATO_LOOP_NHR_ORIGIN_OVERRIDE — when set, bypass state-file
# lookup and use this value directly as the gate origin. Allows
# _test-apply-nhr-gate to exercise all four classification branches offline
# without a real workflow-state file or gh calls.
# ---------------------------------------------------------------------------
_apply_needs_human_review_reshape() {
  local issue="$1"
  shift
  local -a repo_flag=("$@")

  # Gate: determine the effective origin for this HALT.
  # Priority: MAKATO_LOOP_NHR_ORIGIN_OVERRIDE (test hook) > state-file lookup > safe default.
  local gate_origin="human"  # safe default: apply label when origin unknown

  if [[ -n "${MAKATO_LOOP_NHR_ORIGIN_OVERRIDE+x}" ]]; then
    # Test hook: use the explicitly provided origin (empty string is valid = legacy/absent).
    gate_origin="${MAKATO_LOOP_NHR_ORIGIN_OVERRIDE}"
  else
    # Production path: read origin from the latest halt_audit[] entry in workflow-state.
    local gate_key=""
    gate_key="$(_derive_key_for_issue "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" 2>/dev/null || true)"
    if [[ -n "$gate_key" ]]; then
      local gate_spec_folder=""
      gate_spec_folder="$(find "${SPECS_DIR:-specs}" -maxdepth 1 -type d -name "${gate_key}-*" 2>/dev/null | head -1 || true)"
      [[ -z "$gate_spec_folder" && -d "${SPECS_DIR:-specs}/$gate_key" ]] && gate_spec_folder="${SPECS_DIR:-specs}/$gate_key"
      if [[ -n "$gate_spec_folder" ]]; then
        local gate_state_file="$gate_spec_folder/workflow-state-${issue}.json"
        if [[ -f "$gate_state_file" ]]; then
          local latest_origin
          latest_origin="$(jq -r '.halt_audit[-1].data.origin // ""' "$gate_state_file" 2>/dev/null || echo "")"
          # Treat null/empty as "human" (backward compat for legacy entries without the field).
          [[ -z "$latest_origin" || "$latest_origin" == "null" ]] && latest_origin="human"
          gate_origin="$latest_origin"
        fi
      fi
    fi
  fi

  # Treat empty origin (no field in legacy entry) as "human" for backward compat.
  [[ -z "$gate_origin" ]] && gate_origin="human"

  # Only apply needs-human-review for human-origin HALTs.
  if [[ "$gate_origin" != "human" ]]; then
    echo "loop: reshape-pass — #${issue} skipping needs-human-review (origin=${gate_origin}; non-human HALTs do not require operator action)" >&2
    return 0
  fi

  if [[ -n "${MAKATO_LOOP_LABEL_TEST_FILE:-}" ]]; then
    echo "label #${issue} needs-human-review" >>"$MAKATO_LOOP_LABEL_TEST_FILE"
    _post_halt_comment "HALT-013" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
    return 0
  fi

  if ! gh label list "${repo_flag[@]}" 2>/dev/null | grep -q "^needs-human-review"; then
    gh label create "needs-human-review" "${repo_flag[@]}" \
      --color "E4E669" --description "Requires human review" >/dev/null 2>&1 || true
  fi
  gh issue edit "$issue" "${repo_flag[@]}" --add-label "needs-human-review" >/dev/null 2>&1 || true
  _post_halt_comment "HALT-013" "$issue" "${MAKATO_LOOP_DISPATCH_REPO:-}" || true
}

# ---------------------------------------------------------------------------
# _log_reshape_result <KEY> <ISSUE_NUMBER> <status:ok|error> <reshape_cycles>
#   <error_reason> — emit one JSONL entry to specs/<key>/orchestrate.jsonl.
# Uses build-log.sh when present; falls through silently when absent.
# ---------------------------------------------------------------------------
_log_reshape_result() {
  local key="$1"
  local issue="$2"
  local status="$3"
  local cycles="$4"
  local reason="${5:-}"

  local ts
  ts="$(_now)"
  local data
  data="$(jq -cn \
    --arg key "$key" \
    --argjson issue "$issue" \
    --argjson cycles "$cycles" \
    --arg reason "$reason" \
    '{key: $key, issue: $issue, reshape_cycles_after: $cycles, error_reason: (if $reason == "" then null else $reason end)}')"

  local entry
  entry="$(jq -cn \
    --arg ts "$ts" \
    --argjson issue "$issue" \
    --arg status "$status" \
    --argjson data "$data" \
    '{"ts": $ts, "skill": "loop", "issue": $issue, "step": "reshape", "status": $status, "data": $data}')"

  # Write to orchestrate.jsonl (loop's own audit trail), using SPECS_DIR
  # (loop's own REPO_ROOT-relative path) rather than delegating to build-log.sh,
  # which resolves via git --git-common-dir (main checkout). In a worktree,
  # build-log.sh would write to the main checkout's specs/ while loop.sh and
  # the tests use the worktree's specs/ — causing a mismatch. Writing here
  # keeps the path consistent with how SPECS_DIR is resolved throughout this
  # script.
  local spec_folder=""
  spec_folder="$(find "$SPECS_DIR" -maxdepth 1 -type d -name "${key}-*" 2>/dev/null | head -1 || true)"
  [[ -z "$spec_folder" && -d "$SPECS_DIR/$key" ]] && spec_folder="$SPECS_DIR/$key"
  [[ -z "$spec_folder" ]] && spec_folder="$SPECS_DIR/$key"
  mkdir -p "$spec_folder" 2>/dev/null || true
  printf '%s\n' "$entry" >> "$spec_folder/orchestrate.jsonl" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _emit_run_report <issue…> (#448) — at end-of-run, aggregate the terminal
# state of each dispatched issue into a single durable run report by delegating
# to scripts/generate-run-report.sh (read-only over the per-issue
# workflow-state-<issue>.json files). Prints the report path to stderr and
# records it in loop-status.json under `.last_run_report`. Skips silently when
# no issues were dispatched (an idle run has nothing to report). Best-effort:
# a report-generation failure logs a WARN and never changes cmd_run's exit
# status — reporting is additive and must not break the loop.
# ---------------------------------------------------------------------------
_emit_run_report() {
  local -a issues=("$@")
  [[ "${#issues[@]}" -gt 0 ]] || return 0
  local report_script="$REPO_ROOT/plugins/makato-orchestrate/scripts/generate-run-report.sh"
  if [[ ! -x "$report_script" ]]; then
    echo "loop: WARN — run-report script not found/executable at $report_script; skipping report (#448)" >&2
    return 0
  fi
  local report_path
  # Forward SPECS_DIR / STATE_DIR via the report script's own env hooks so a
  # test-overridden loop and its report share one specs/ + state/ location.
  if report_path="$(MAKATO_REPORT_SPECS_DIR="$SPECS_DIR" MAKATO_LOOP_STATE_DIR="$STATE_DIR" \
      "$report_script" --issues "${issues[*]}" 2>/dev/null)"; then
    echo "loop: run report written → $report_path (#448)" >&2
    _patch_status '.last_run_report' "\"$report_path\""
  else
    echo "loop: WARN — run-report generation failed for issues '${issues[*]}'; continuing (#448)" >&2
  fi
}

# ---------------------------------------------------------------------------
# _check_tool_deps — pre-flight dependency check (#587).
#
# Verifies that jq, gh, git, and python3 are available on PATH and that
# `gh auth status` passes. Runs once per cmd_run invocation (not per tick).
#
# Returns 0 when all checks pass.
# Returns non-zero and prints an actionable error to stderr when any check
# fails — naming the missing tool or identifying the authentication failure.
#
# The `gh auth status` check is skipped when the smoke-test harness is active:
# MAKATO_LOOP_GH_OVERRIDE (non-empty), MAKATO_LOOP_POLL_TEST_CMD, or
# MAKATO_LOOP_GRAPHQL_TEST_CMD indicate offline/test mode where board calls
# are served locally and a live gh auth round-trip is neither meaningful nor
# available. In production none of these vars are set, so the auth check fires
# normally.
# ---------------------------------------------------------------------------
_check_tool_deps() {
  local tool
  for tool in jq gh git python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "loop: pre-flight error — required tool '$tool' not found on PATH; install it and retry" >&2
      return 1
    fi
  done
  # Skip live auth check when any test-mode env var is active (offline/CI harness).
  if [[ -z "${MAKATO_LOOP_GH_OVERRIDE:-}" \
     && -z "${MAKATO_LOOP_POLL_TEST_CMD:-}" \
     && -z "${MAKATO_LOOP_GRAPHQL_TEST_CMD:-}" ]]; then
    local _host
    _host="$(jq -r '.github_project.host // "github.com"' "${CONFIG_FILE}" 2>/dev/null || echo "github.com")"
    if ! GH_HOST="$_host" gh auth status --hostname "$_host" >/dev/null 2>&1; then
      echo "loop: pre-flight error — gh auth status failed for $_host; run 'gh auth login --hostname $_host' and retry" >&2
      return 1
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _check_session_safety — pre-flight session-ancestry guard (#743).
#
# Detects when `loop.sh run` is a descendant of a background/headless Claude
# session (`bg-spare`, `bg-pty-host`, `claude daemon run --origin transient`).
# Such a session is reaped after a few minutes and its SIGTERM propagates down
# the process tree — killing the loop and any in-flight PO-agent dispatch
# (incident: dispatch #453, seed-issue #742). The loop MUST NOT inherit that
# lifecycle, so this guard aborts BEFORE the run-mutex/pidfile is taken.
#
# Walks up to 4 levels of ppid ancestry using `ps -o args=` (the full command
# string — `comm` is truncated at 15 chars on macOS, hiding `bg-pty-host` and
# `claude daemon run --origin transient`).
#
# Returns 0 (guard passes / bypassed / degraded) or 1 (bg-session detected).
#
# Bypass / test seams:
#   MAKATO_LOOP_ALLOW_BG_SESSION=1  — opt-out for headless CI where external
#       SIGTERM protection is provided by the caller. No-op, returns 0.
#   MAKATO_LOOP_GH_OVERRIDE (or POLL/GRAPHQL test cmds) — offline smoke-test
#       mode; guard is skipped (mirrors _check_tool_deps' auth-check skip).
#   MAKATO_LOOP_SESSION_SAFETY_TEST_PPID — inject the starting ppid for the
#       ancestry walk instead of using $PPID (offline tests, no real bg-spare).
#   MAKATO_LOOP_SESSION_SAFETY_PS_OVERRIDE — path to a file whose contents are
#       returned in place of `ps -o args= -p <pid>` for the injected ppid, so
#       tests can supply fake ancestry output without a live process.
# ---------------------------------------------------------------------------
_check_session_safety() {
  # Opt-out: headless CI with external SIGTERM protection.
  [[ "${MAKATO_LOOP_ALLOW_BG_SESSION:-0}" == "1" ]] && return 0

  # Offline smoke-test mode — never fire in the test harness (consistent with
  # _check_tool_deps skipping the live gh-auth check under these vars).
  if [[ -n "${MAKATO_LOOP_GH_OVERRIDE:-}" \
     || -n "${MAKATO_LOOP_POLL_TEST_CMD:-}" \
     || -n "${MAKATO_LOOP_GRAPHQL_TEST_CMD:-}" ]] \
     && [[ -z "${MAKATO_LOOP_SESSION_SAFETY_TEST_PPID:-}" ]]; then
    return 0
  fi

  local pid
  pid="${MAKATO_LOOP_SESSION_SAFETY_TEST_PPID:-$PPID}"

  local level args
  for level in 1 2 3 4; do
    [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" ]] || break

    # Resolve this ancestor's full command string. Test seam short-circuits the
    # real ps call for the injected ppid on the FIRST level only; subsequent
    # levels walk real ppids (empty → break via graceful-degrade below).
    if [[ -n "${MAKATO_LOOP_SESSION_SAFETY_PS_OVERRIDE:-}" && "$level" == "1" ]]; then
      args="$(cat "${MAKATO_LOOP_SESSION_SAFETY_PS_OVERRIDE}" 2>/dev/null || echo "")"
    else
      args="$(ps -o args= -p "$pid" 2>/dev/null || echo "")"
    fi

    # Graceful degrade: `ps` unavailable / empty output → skip the check.
    if [[ -z "$args" ]]; then
      [[ "$level" == "1" ]] && echo "loop: WARN — session-safety: could not read process ancestry (ps unavailable); skipping guard" >&2
      break
    fi

    if [[ "$args" == *"bg-spare"* \
       || "$args" == *"bg-pty-host"* \
       || "$args" == *"claude daemon run --origin transient"* ]]; then
      cat >&2 <<EOF
loop: error — launched under a background/headless Claude session (process: '${args}').
The loop will be SIGTERM'd when this session is reaped.
Fix: run from an interactive terminal or use nohup+disown:
  nohup plugins/makato-orchestrate/scripts/loop.sh run > ~/.claude/state/loop.log 2>&1 &
  disown
To suppress this guard: export MAKATO_LOOP_ALLOW_BG_SESSION=1
EOF
      return 1
    fi

    # Walk one level up. Test seam only mocks level 1; from level 2 we probe
    # the real ppid of the injected pid, which typically fails and breaks.
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || echo "")"
  done

  return 0
}

# ---------------------------------------------------------------------------
# run — long-running poll loop. CLI flags override env defaults.
# ---------------------------------------------------------------------------
cmd_run() {
  local status_name="$DEFAULT_STATUS"
  local interval="$DEFAULT_INTERVAL"
  local dry_run=""
  local once=""
  local force=""
  local promote_unblocked=""
  # #448 — accumulate the issue numbers dispatched in this run so the
  # end-of-run report can aggregate each one's terminal state. Populated only
  # on a real (non-dry-run) dispatch below.
  local -a dispatched_issues=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status)             status_name="${2:?--status requires a value}"; shift 2 ;;
      --interval)           interval="${2:?--interval requires a value}"; shift 2 ;;
      --dry-run)            dry_run="--dry-run"; shift ;;
      --once)               once="1"; shift ;;
      --force)              force="1"; shift ;;
      --promote-unblocked)  promote_unblocked="1"; shift ;;
      *) echo "loop: unknown flag: $1" >&2; return 64 ;;
    esac
  done

  # Pre-flight tool-dependency check (#587). Runs once per cmd_run invocation,
  # before the mutex, startup audit, or any board interaction. Aborts with a
  # non-zero exit and an actionable stderr message when any required tool is
  # absent or gh is not authenticated.
  _check_tool_deps || return 1

  # Pre-flight session-safety guard (#743). Aborts BEFORE the run-mutex/pidfile
  # is acquired when the loop is a descendant of a bg-spare / bg-pty-host /
  # headless Claude session that would SIGTERM the loop (and any in-flight
  # dispatch) when reaped. Bypass with MAKATO_LOOP_ALLOW_BG_SESSION=1.
  _check_session_safety || return 1

  # Layer 1 — run-mutex pidfile (see #172). Refuses to start a second
  # instance sharing this state dir. Two loops writing to the same
  # loop-status.json race on active_workflow / queue / last_poll and
  # can dispatch two PO-agents against the same repo working tree,
  # which is what the #172 incident report describes.
  #
  # `--force` reclaims a live pidfile by SIGTERM'ing the incumbent
  # (SIGKILL after $FORCE_GRACE_SECS) and taking over. Stale pidfiles
  # (PID dead) are reclaimed silently — this is the normal case after
  # `kill -9` or a crash left the file behind.
  _acquire_run_mutex "$force" || return $?

  # Startup audit — layer 2 defence. Stamps this instance's script
  # path, PID, PPID, and CLI args into loop-status.json so an operator
  # seeing two live loops in `ps` can tell which one owns the state
  # dir (the #172 incident had a plugin-cache instance and a
  # working-tree instance running side-by-side against the same repo).
  _stamp_startup_audit "$status_name" "$interval" "$dry_run"

  # Seed/refresh status with the run-level metadata before any poll. This
  # makes `loop status` informative even if the first poll is mid-flight.
  _patch_status '.status_name' "\"$status_name\""
  _patch_status '.interval_seconds' "$interval"
  _patch_status '.dry_run' "$( [[ -n "$dry_run" ]] && echo true || echo false )"

  # Session-scoped counters: reset orphan_dispatches to 0 at each cmd_run
  # start so a prior run's count is not carried over (#357 D7).
  _patch_status '.orphan_dispatches' '0'

  # #516 — adaptive idle backoff. When a tick finds the queue empty AND
  # dispatches nothing, the next sleep grows by IDLE_BACKOFF_FACTOR up to
  # IDLE_BACKOFF_MAX; any tick with work resets it back to the base interval.
  # An idle loop polling every 300s burns the board-poll budget for nothing;
  # backing off to 30m during quiet periods cuts idle polls ~6x. Defaults keep
  # the active-work cadence identical to today (effective == base when busy).
  local effective_interval="$interval"

  while true; do
    if ! cmd_check_halt; then
      _patch_status '.last_halt_at' "\"$(_now)\""
      # #448 — bash-3.2-safe empty-array expansion (set -u would abort on a
      # bare "${arr[@]}" when empty). _emit_run_report no-ops on empty input.
      _emit_run_report "${dispatched_issues[@]+"${dispatched_issues[@]}"}"
      return 0
    fi

    # Pre-poll external hook (#pending): a consumer-supplied script run before
    # any board interaction, right after the HALT check. Lets a consumer (e.g.
    # sagibeast's testbox-recovery.sh) keep its self-hosted runners alive before
    # the loop tries to dispatch. Exit contract:
    #   0 → healthy/handled, continue tick
    #   2 → transient problem, skip dispatch this tick (retry next tick)
    #   3 → give up: HALT the loop (the hook has already notified)
    # Any other non-zero is treated as 0 (best-effort — never block on a buggy
    # hook). Unset/non-executable → no-op. Skipped under --dry-run.
    if [[ -z "$dry_run" && -n "${MAKATO_LOOP_PREPOLL_HOOK:-}" \
          && -x "${MAKATO_LOOP_PREPOLL_HOOK}" ]]; then
      # `set -e` is active: a bare `hook; rc=$?` would abort cmd_run the moment
      # the hook exits non-zero (2/3 are expected). Capture rc with a `|| rc=$?`
      # guard — `$?` inside an `if !` body is already reset to 0, so that idiom
      # cannot recover the real code; `|| ` runs only on failure and preserves it.
      local prepoll_rc=0
      "${MAKATO_LOOP_PREPOLL_HOOK}" || prepoll_rc=$?
      case "$prepoll_rc" in
        2) echo "loop: pre-poll hook returned 2 — skipping dispatch this tick" >&2
           if [[ -n "$once" ]]; then
             _emit_run_report "${dispatched_issues[@]+"${dispatched_issues[@]}"}"
             return 0
           fi
           _guarded_sleep "$interval"; continue ;;
        3) echo "loop: pre-poll hook returned 3 — HALT (hook gave up)" >&2
           _patch_status '.last_halt_at' "\"$(_now)\""
           _emit_run_report "${dispatched_issues[@]+"${dispatched_issues[@]}"}"
           return 0 ;;
        0) : ;;
        *) echo "loop: pre-poll hook rc=${prepoll_rc} (ignored, best-effort)" >&2 ;;
      esac
    fi

    # Pre-poll auto-promotion of Todo/Blocked issues (#548): when
    # MAKATO_LOOP_ALLOW_TODO=1 or --promote-unblocked is given, invoke
    # promote-ready.sh run --yes non-interactively so newly-unblocked issues
    # are promoted to Ready before the board poll selects the next candidate.
    # A non-zero exit is logged but never aborts the tick. Default OFF —
    # a loop run without either signal does not invoke promote-ready.sh.
    if [[ -n "${MAKATO_LOOP_ALLOW_TODO:-}${promote_unblocked:-}" && -z "$dry_run" ]]; then
      local _pr_bin="${MAKATO_PROMOTE_PATH:-}"
      if [[ -z "$_pr_bin" ]]; then
        _pr_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/promote-ready.sh"
      fi
      if [[ -x "$_pr_bin" ]]; then
        local _promote_rc=0
        "$_pr_bin" run --yes 2>&1 | while IFS= read -r _line; do
          echo "loop: promote-unblocked: $_line" >&2
        done || _promote_rc=$?
        if [[ "$_promote_rc" -ne 0 ]]; then
          echo "loop: promote-unblocked: promote-ready.sh exited $_promote_rc (logged, tick continues)" >&2
        fi
      fi
    fi

    # Pre-poll orphaned-In-progress reconciliation (#368): move board cards
    # that are "In progress" but have no live local workflow-state to Blocked
    # + needs-human-review. Runs for all --status values. Skipped under
    # --dry-run. Best-effort — never blocks the tick.
    if [[ "${RECONCILE_ON_POLL}" != "0" && -z "$dry_run" ]]; then
      _reconcile_orphaned_in_progress || true
    fi

    # Pre-poll orphaned-stale detection (#616): recover an in-flight run whose
    # workflow-state file is PRESENT (current_phase != done) but whose owning
    # process is dead and whose updated_at is stale — the file-present gap the
    # #368 reconciler above explicitly skips. Runs right after it so both the
    # no-file and stale-file orphan classes are handled each tick. Best-effort.
    if [[ "${ORPHAN_DETECT_DISABLE}" != "1" && -z "$dry_run" ]]; then
      _reconcile_orphaned_stale || true
    fi

    # Pre-poll reshape pass (#350, epic #319): detect issues at board Status=Needs
    # Planning and drive a bounded makato-plan re-shape. Runs before auto-seed so
    # a reshaped issue can be seeded in the same tick. Feature-flagged off by
    # default; serial invariant preserved. Skipped under --dry-run.
    if [[ "${MAKATO_LOOP_RESHAPE_ENABLED:-0}" == "1" && -z "$dry_run" ]]; then
      _reshape_pass || true
    fi

    # Pre-poll auto-seed pass (#373, epic #367 S5): seed/block unprepared
    # issues before polling, so a freshly-seeded light issue can be eligible
    # for dispatch in the same tick. Only meaningful when "Ready" is among the
    # polled statuses (comma-list membership check).
    if [[ "${MAKATO_LOOP_AUTOSEED_ON_POLL:-1}" != "0" && ",${status_name}," == *",Ready,"* && -z "$dry_run" ]]; then
      _auto_seed_unprepared || true
    fi

    # Pre-poll merged-worktree reap (#265): remove local worktrees whose PR is
    # merged so the operator's .claude/worktrees/ does not pile up. Runs for
    # all --status values (it operates on local disk, not the board) but is
    # self-throttled to at most once per REAP_INTERVAL_SECS. Skipped under
    # --dry-run (inspection mode never mutates disk). Best-effort — never
    # blocks the tick.
    if [[ "$REAP_ON_POLL" == "1" && -z "$dry_run" ]]; then
      _reap_merged_worktrees || true
    fi

    # Optional prune pass (#597): remove done+stale workflow-state-*.json files.
    # Opt-in via MAKATO_LOOP_PRUNE_ON_RUN=1. Skipped under --dry-run.
    if [[ "${MAKATO_LOOP_PRUNE_ON_RUN}" == "1" && -z "$dry_run" ]]; then
      local _ws_sh
      _ws_sh="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/shared/workflow-state.sh"
      if [[ -x "$_ws_sh" ]]; then
        "$_ws_sh" prune "*" "$MAKATO_LOOP_PRUNE_AGE_DAYS" || true
      fi
    fi

    local queue queue_depth poll_rc
    # #289: capture cmd_poll's exit code. A non-zero rc means the board poll
    # FAILED (rate-limit / transient API error after all retries) — this is
    # categorically different from a successful poll that returned an empty
    # item set. We must not let a failed read masquerade as an empty queue and
    # trigger an "idle" tick, hiding an ongoing API outage behind a healthy-
    # looking loop.
    poll_rc=0
    queue="$(cmd_poll "$status_name")" || poll_rc=$?
    if [[ $poll_rc -eq 76 ]]; then
      # Rate-budget skip (#556): the proactive guard detected that
      # resources.graphql.remaining < GRAPHQL_MIN_REMAINING and already slept
      # until the reset epoch. Stamp poll_skipped_rate_budget:true (leave
      # poll_healthy unchanged — this is not an error, just a pre-emptive
      # sleep), then continue to the next tick.
      local now
      now="$(_now)"
      _write_status "$(jq \
        --arg ts "$now" \
        '. + {poll_skipped_rate_budget: true, last_poll_skip_reason: "rate_budget", last_poll_skip: $ts}' \
        <<<"$(_read_status)")"
      _increment_poll_skip_count
      local _psc
      _psc="$(_read_status | jq -r '.poll_skip_count // 0')"
      if (( _psc >= RATE_SKIP_THRESHOLD )); then
        echo "loop: INFO — poll_skip_count=$_psc >= threshold=$RATE_SKIP_THRESHOLD; circuit-breaker sleep ${RATE_SKIP_BACKOFF}s (#683)" >&2
        _patch_status '.poll_skip_count' '0'
        _guarded_sleep "$RATE_SKIP_BACKOFF"
      fi
      if [[ -n "$once" ]]; then
        _emit_run_report "${dispatched_issues[@]+"${dispatched_issues[@]}"}"
        return 0
      fi
      continue
    fi
    if [[ $poll_rc -ne 0 ]]; then
      # Distinct transient-error state: stamp the failure into loop-status.json
      # (so the audit shows an outage, not an idle loop), skip dispatch this
      # tick, and re-poll after a short backoff rather than the full interval —
      # Ready work must resume promptly once the API recovers.
      local now err_backoff
      now="$(_now)"
      err_backoff="${MAKATO_LOOP_POLL_ERROR_BACKOFF:-$interval}"
      echo "loop: board poll FAILED (transient/rate-limit) — skipping dispatch this tick, re-polling in ${err_backoff}s (#289)" >&2
      _write_status "$(jq \
        --arg ts "$now" \
        '. + {last_poll_error: $ts, poll_healthy: false}' \
        <<<"$(_read_status)")"
      if [[ -n "$once" ]]; then
        _emit_run_report "${dispatched_issues[@]+"${dispatched_issues[@]}"}"
        return 0
      fi
      _guarded_sleep "$err_backoff"
      continue
    fi
    queue_depth="$(jq 'length' <<<"$queue")"
    # Batch the poll-result fields into a single status write — saves
    # three `_patch_status` invocations (each reads + jq-merges + mktemp + mv).
    # `poll_healthy:true` clears any prior transient-error flag (#289).
    local now
    now="$(_now)"
    _write_status "$(jq \
      --arg ts "$now" \
      --argjson depth "$queue_depth" \
      --argjson q "$(jq '[.[].issue]' <<<"$queue")" \
      '. + {last_poll: $ts, queue_depth: $depth, queue: $q, poll_healthy: true, poll_skipped_rate_budget: false}' \
      <<<"$(_read_status)")"
    _reset_poll_skip_count
    vcr_obj="$(_compute_vcr)"
    _patch_status '.vcr' "$vcr_obj"

    local in_flight
    in_flight="$(in_flight_issues)"
    local next_issue
    # Wave-ordered selection (#548): call _dependency_order to get an ordered
    # candidate list (wave 0 before wave 1, FIFO within each wave). Pick the
    # first candidate that is not already in-flight. Fall back byte-for-byte
    # to the original jq | head -1 expression when no graph files are present
    # or _dependency_order returns an empty list.
    local _dep_order_list
    _dep_order_list="$(_dependency_order)"
    if [[ -n "$_dep_order_list" ]]; then
      # Walk the wave-ordered list and pick the first not in-flight.
      local _in_flight_arr=()
      while IFS= read -r _fl_issue; do
        [[ -n "$_fl_issue" ]] && _in_flight_arr+=("$_fl_issue")
      done <<<"$in_flight"
      next_issue=""
      while IFS= read -r _candidate; do
        [[ -z "$_candidate" ]] && continue
        local _is_in_flight=0
        for _fl in "${_in_flight_arr[@]+"${_in_flight_arr[@]}"}"; do
          if [[ "$_fl" == "$_candidate" ]]; then _is_in_flight=1; break; fi
        done
        if [[ "$_is_in_flight" -eq 0 ]]; then
          # Verify candidate is actually in the current queue (board may have
          # changed since promote-ready.sh ran — intersection is mandatory).
          if jq -e --argjson n "$_candidate" '.[] | select(.issue == $n)' \
              <<<"$queue" >/dev/null 2>&1; then
            next_issue="$_candidate"
            break
          fi
        fi
      done <<<"$_dep_order_list"
      # If no wave-ordered candidate was found (e.g. all graph issues already
      # in-flight but FIFO queue has non-graph items), fall back to legacy.
      if [[ -z "$next_issue" ]]; then
        next_issue="$(jq -r --argjson in_flight \
          "$(jq -R . <<<"$in_flight" | jq -sc 'map(select(length>0))')" \
          '.[] | .issue as $n
            | select(($in_flight | index($n|tostring) | not)) | $n' \
          <<<"$queue" | head -1)"
      fi
    else
      # No graph / empty list: original FIFO selection (byte-for-byte fallback).
      next_issue="$(jq -r --argjson in_flight \
        "$(jq -R . <<<"$in_flight" | jq -sc 'map(select(length>0))')" \
        '.[] | .issue as $n
          | select(($in_flight | index($n|tostring) | not)) | $n' \
        <<<"$queue" | head -1)"
    fi

    if [[ -n "$next_issue" ]]; then
      echo "loop: dispatching issue #$next_issue (status=$status_name, queue_depth=$queue_depth)" >&2
      # Resolve the owning repository for this issue from the poll result
      # (the board is cross-repo — every item carries its own repository).
      # Passed to cmd_dispatch via env so the public `dispatch <ISSUE>`
      # signature is unchanged; the assign-on-dispatch step needs it for
      # `gh issue edit --repo`.
      local next_repo next_item_status
      next_repo="$(jq -r --argjson n "$next_issue" \
        'map(select(.issue == $n)) | .[0].repository // empty' <<<"$queue")"
      next_item_status="$(jq -r --argjson n "$next_issue" \
        'map(select(.issue == $n)) | .[0].status // empty' <<<"$queue")"
      # `cmd_dispatch` already clears active_workflow on return; we ignore
      # the PO-agent's exit code — it writes its own HALT audit to
      # workflow-state.json; the loop's job is to surface the next issue,
      # not to second-guess the orchestrator's terminal state.
      MAKATO_LOOP_DISPATCH_REPO="$next_repo" \
      MAKATO_LOOP_ITEM_STATUS="$next_item_status" \
        cmd_dispatch "$next_issue" ${dry_run:+"$dry_run"} || true
      # #448 — record this issue for the end-of-run report. Dry-run dispatches
      # never touch workflow-state, so they are excluded (nothing to aggregate).
      if [[ -z "$dry_run" ]]; then
        dispatched_issues+=("$next_issue")
      fi
    else
      echo "loop: queue empty or fully in-flight (depth=$queue_depth) — idle" >&2
    fi

    if [[ -n "$once" ]]; then
      _emit_run_report "${dispatched_issues[@]+"${dispatched_issues[@]}"}"
      return 0
    fi

    # #516 — adaptive idle backoff. A tick "did work" if it dispatched an
    # issue OR the board still holds queued items (depth>0 but all in-flight
    # means work is active — stay responsive). Only a genuinely empty queue
    # with no dispatch grows the interval. Any work resets to base.
    if [[ -n "$next_issue" || "${queue_depth:-0}" -gt 0 ]]; then
      effective_interval="$interval"
    else
      effective_interval=$(( effective_interval * IDLE_BACKOFF_FACTOR ))
      (( effective_interval > IDLE_BACKOFF_MAX )) && effective_interval="$IDLE_BACKOFF_MAX"
    fi
    _patch_status '.effective_interval_seconds' "$effective_interval"

    # #171 — wall-clock-guaranteed sleep. Naive `sleep "$interval"` can
    # return early after a macOS host suspend/resume; _guarded_sleep
    # re-enters raw sleep until the requested wall-clock has elapsed.
    _guarded_sleep "$effective_interval"
  done
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
SUBCMD="${1:?subcommand required: run|poll|next|status|dispatch|check-halt}"
shift || true

# ---------------------------------------------------------------------------
# Test-hook dispatch — subcommands prefixed with `_test-` are exposed
# EXCLUSIVELY for the smoke-test suite (`loop-smoke-tests.sh`) and are
# NOT part of the public subcommand contract. They are segregated from
# the main dispatcher below so `--help`-style tab completion or an
# operator scanning the case block does not treat them as usable.
# Anyone invoking one gets an explicit error explaining the intent.
# ---------------------------------------------------------------------------
if [[ "$SUBCMD" == _test-* ]]; then
  # In-band signal: allow the smoke tests through, refuse everyone else.
  # `MAKATO_LOOP_TEST_HOOK=1` is the caller-side opt-in; loop-smoke-tests.sh
  # sets it before invoking, an operator running `loop.sh _test-…` at the
  # prompt gets the refusal message.
  if [[ "${MAKATO_LOOP_TEST_HOOK:-0}" != "1" ]]; then
    echo "loop: '$SUBCMD' is an internal test hook (smoke-tests only)." >&2
    echo "loop: run via loop-smoke-tests.sh; do not invoke directly." >&2
    exit 64
  fi
  case "$SUBCMD" in
    _test-guarded-sleep) _guarded_sleep "$@" ;;
    _test-gh-item-list) _gh_project_item_list "$@" ;;
    # _test-board-graphql <host> <pid> — exercise _board_via_graphql
    # deterministically via MAKATO_LOOP_GRAPHQL_TEST_CMD (per-page fixture,
    # receives MAKATO_LOOP_GRAPHQL_CURSOR). Prints the remapped {"items":[...]}
    # payload to stdout / returns the function's exit code so the smoke suite
    # can assert the item-list-shape contract and multi-page assembly (#516).
    _test-board-graphql) _board_via_graphql "$@" ;;
    # _test-item-id-for-issue <host> <owner> <repo> <issue> <pid> — exercise
    # _project_item_id_for_issue deterministically via MAKATO_LOOP_ITEM_ID_TEST_CMD
    # (canned repository.issue.projectItems JSON). Prints the resolved item id /
    # returns the function's exit code so the smoke suite can assert the
    # project-id filter and not-on-board miss paths.
    _test-item-id-for-issue) _project_item_id_for_issue "$@" ;;
    # _test-check-graphql-rate-budget <host> — exercise _check_graphql_rate_budget
    # deterministically via MAKATO_LOOP_GRAPHQL_TEST_CMD (canned rate_limit JSON)
    # and MAKATO_LOOP_RATE_GUARD / MAKATO_LOOP_GRAPHQL_MIN_REMAINING overrides.
    # Returns the function's exit code (0=proceed, 2=skip) so smoke tests can
    # assert the guard, bypass, and degrade paths (#556).
    _test-check-graphql-rate-budget) _check_graphql_rate_budget "$@" ;;
    # _test-gh-with-fallback <context> <args...> — exercise _gh_with_fallback
    # deterministically via MAKATO_LOOP_FALLBACK_TEST_CMD (+ MAKATO_LOOP_SLEEP_CMD
    # to skip backoff waits). Prints the payload to stdout / returns the wrapper's
    # exit code so the smoke suite can assert success, exhaustion, and backoff.
    # (#447).
    _test-gh-with-fallback) _gh_with_fallback "$@" ;;
    # _test-gh-json-valid <json> — exercise _gh_json_valid directly; exits 0 on
    # parseable JSON, 1 otherwise. (#447).
    _test-gh-json-valid) _gh_json_valid "$@" ;;
    # _test-auto-seed-candidates — exercise _auto_seed_candidates deterministically
    # using MAKATO_LOOP_AUTOSEED_OVERRIDE fixture. Returns JSON array to stdout.
    # (#369, epic #367 S1).
    _test-auto-seed-candidates) _auto_seed_candidates ;;
    # _test-auto-seed-dispatch-light <issue> <plan_tier> — exercise
    # _auto_seed_dispatch_light deterministically using MAKATO_LOOP_SEED_TEST_CMD.
    # (#370, epic #367 S2).
    _test-auto-seed-dispatch-light) _auto_seed_dispatch_light "$@" ;;
    # _test-auto-seed-block-full <issue> <plan_tier> — exercise
    # _auto_seed_block_full deterministically using test-hook env vars:
    #   MAKATO_LOOP_BLOCK_TEST_FILE, MAKATO_LOOP_LABEL_TEST_FILE,
    #   MAKATO_LOOP_COMMENT_TEST_FILE, MAKATO_LOOP_COMMENTS_OVERRIDE,
    #   MAKATO_LOOP_AUTOSEED_SPEC_ROOT, MAKATO_LOOP_ISSUE_TITLE_OVERRIDE.
    # (#372, epic #367 S4).
    _test-auto-seed-block-full) _auto_seed_block_full "$@" ;;
    # _test-auto-seed-promote <issue> — exercise _auto_seed_promote_ready_from_gate
    # deterministically using test-hook env vars:
    #   MAKATO_LOOP_PROMOTE_TEST_FILE (append "promote #N → Ready" on promote),
    #   MAKATO_LOOP_RECONCILE_LABEL_FILE (offline issue-label source),
    #   MAKATO_LOOP_PARK_LABELS (park-label list). (#721, FM-LABEL-PARK).
    _test-auto-seed-promote) _auto_seed_promote_ready_from_gate "$@" ;;
    # _test-auto-seed-reconcile-thin-body <issue> [seed_key] — exercise
    # _auto_seed_reconcile_thin_body deterministically using test-hook env vars:
    #   MAKATO_LOOP_RECONCILE_JSONL_DIR, MAKATO_LOOP_RECONCILE_LABEL_FILE,
    #   MAKATO_LOOP_LABEL_TEST_FILE.
    # (#371, epic #367 S3).
    _test-auto-seed-reconcile-thin-body) _auto_seed_reconcile_thin_body "$@" ;;
    # _test-auto-seed-unprepared — exercise _auto_seed_unprepared
    # deterministically. Reads from MAKATO_LOOP_AUTOSEED_OVERRIDE and
    # routes through the four arms via test hooks.
    # (#373, epic #367 S5).
    _test-auto-seed-unprepared) _auto_seed_unprepared "$@" ;;
    # _test-claim-board-card — exercise _claim_board_card deterministically.
    # Uses MAKATO_LOOP_CLAIM_ON_DISPATCH=1 + MAKATO_LOOP_CLAIM_TEST_FILE +
    # MAKATO_LOOP_CLAIM_STATUS_OVERRIDE + MAKATO_LOOP_ITEM_STATUS.
    # Arg: <ISSUE_NUMBER>
    _test-claim-board-card) _claim_board_card "$1" ;;
    # _test-reconcile-orphaned — exercise _reconcile_orphaned_in_progress
    # deterministically via test-hook env vars:
    #   MAKATO_LOOP_RECONCILE_GH_OVERRIDE, MAKATO_LOOP_RECONCILE_TEST_FILE,
    #   MAKATO_LOOP_RECONCILE_LABEL_TEST_FILE.
    # (#368).
    _test-reconcile-orphaned) _reconcile_orphaned_in_progress "$@" ;;
    # _test-reconcile-stale — exercise _reconcile_orphaned_stale
    # deterministically via test-hook env vars:
    #   MAKATO_LOOP_RECONCILE_SPECS_DIR, MAKATO_LOOP_RECONCILE_TEST_FILE,
    #   MAKATO_LOOP_RECONCILE_LABEL_TEST_FILE, MAKATO_ORPHAN_STALE_SECS.
    # (#616).
    _test-reconcile-stale) _reconcile_orphaned_stale "$@" ;;
    # _test-post-halt-comment <HALT_CODE> <ISSUE> <REPO> — exercise the
    # _post_halt_comment script-resolution directly. Regression guard for #744:
    # the helper must resolve post-halt-comment.sh next to this script (plugin
    # cache / marketplace) even when $REPO_ROOT/plugins/... does not vendor it
    # (the consumer-repo case that silently no-op'd). Honours
    # MAKATO_POST_HALT_COMMENT_TEST_FILE so no real gh call is made.
    _test-post-halt-comment) _post_halt_comment "$@" ;;
    # _test-reshape-pass — exercise _reshape_pass deterministically using
    # MAKATO_LOOP_RESHAPE_OVERRIDE and MAKATO_LOOP_RESHAPE_TEST_CMD.
    # (#350, epic #319).
    _test-reshape-pass) _reshape_pass "$@" ;;
    # _test-wd-guarded-write <issue> — exercise the watchdog ownership guard
    # (#312) deterministically, without the process-timing flakiness of a real
    # orphaned poll. Runs the exact guarded write the kill path performs:
    # writes active_workflow.killed_by_watchdog=true ONLY when _wd_owns_active
    # <issue> holds. The smoke suite seeds loop-status.json, invokes this, and
    # asserts the slot is resurrected iff ownership matched.
    _test-wd-guarded-write)
      _test_issue="${1:?issue required}"
      if _wd_owns_active "$_test_issue"; then
        _patch_status '.active_workflow.killed_by_watchdog' 'true'
        echo "wrote (owns)"
      else
        echo "skipped (foreign)"
      fi
      ;;
    # _test-is-orphan <issue> — exercise _is_orphan_issue directly.
    # Exits 0 if orphan, 1 if not. Uses SPECS_DIR env override.
    # (#357).
    _test-is-orphan)
      _test_issue="${1:?issue required}"
      _is_orphan_issue "$_test_issue"
      ;;
    # _test-session-orphan-reset <issue> — simulate a session start
    # (reset orphan_dispatches to 0) then dispatch once so the counter
    # increments to 1. Used by T-orphan-8 to assert session-scoped reset.
    # (#357).
    _test-session-orphan-reset)
      _test_issue="${1:?issue required}"
      # Simulate session start: reset orphan_dispatches to 0.
      _patch_status '.orphan_dispatches' '0'
      cmd_dispatch "$_test_issue"
      ;;
    # _test-apply-nhr-gate <issue> <origin> — exercise the origin-gated
    # _apply_needs_human_review_reshape deterministically (#446).
    # Passes origin via MAKATO_LOOP_NHR_ORIGIN_OVERRIDE so no state-file
    # lookup or gh calls are needed in the offline test environment.
    # Uses MAKATO_LOOP_LABEL_TEST_FILE so no real gh calls are made.
    _test-apply-nhr-gate)
      _test_issue="${1:?issue required}"
      _test_origin="${2:-}"   # empty string = legacy (no origin field)
      MAKATO_LOOP_NHR_ORIGIN_OVERRIDE="$_test_origin" \
        _apply_needs_human_review_reshape "$_test_issue"
      ;;
    # _test-stall-restart <issue> [spec-folder] — exercise _stall_restart
    # deterministically. Reads stall_cause from loop-status.json (pre-seeded
    # by the test) and routes through halt_emitted / transient / no_progress.
    # Returns _stall_restart's exit code. (#444)
    _test-stall-restart)
      _test_issue="${1:?issue required}"
      _test_spec="${2:-}"
      _stall_restart "$_test_issue" "$_test_spec" ""
      ;;
    # _test-stall-resume <issue> <key> [spec-folder] [log-file] — exercise
    # _stall_resume deterministically. Reads stall_restart_count from
    # loop-status.json (pre-seeded by the test). Returns _stall_resume's
    # exit code. (#531)
    _test-stall-resume)
      _test_issue="${1:?issue required}"
      _test_key="${2:-}"
      _test_spec="${3:-}"
      _test_log="${4:-}"
      _stall_resume "$_test_issue" "$_test_key" "$_test_spec" "$_test_log"
      ;;
    # _test-parse-dispatch-result [log-file] — exercise _parse_dispatch_result
    # deterministically. Prints the verdict (complete/incomplete/errored).
    # (#531)
    _test-parse-dispatch-result)
      _test_logfile="${1:-}"
      _parse_dispatch_result "$_test_logfile"
      ;;
    # _test-pre-dispatch-plan-guard <key> — exercise _pre_dispatch_plan_guard
    # deterministically. SPECS_DIR and CLAUDE_BIN are consumed from the
    # environment; the caller sets them to ephemeral test fixtures so no real
    # claude process or GitHub calls are needed.
    _test-pre-dispatch-plan-guard)
      _test_pdpg_key="${1:?key required}"
      _pre_dispatch_plan_guard "$_test_pdpg_key"
      ;;
    # _test-compute-vcr — exercise _compute_vcr deterministically.
    # Reads SPECS_DIR from the environment (caller sets it to an ephemeral
    # fixture dir). Prints the compact JSON object {"activated":…,"verified":…,
    # "rate":…} to stdout. (#585)
    _test-compute-vcr) _compute_vcr ;;
    # _test-check-tool-deps — exercise _check_tool_deps in isolation (#587).
    # Inherits PATH from the caller so the smoke tests can shadow binaries
    # without launching a full cmd_run (which requires the mutex, status-dir,
    # and board fixture).
    #
    # MAKATO_LOOP_TEST_MISSING_TOOL (test-only env var): when set to a tool
    # name (e.g. "jq"), simulates that tool being absent — portable across macOS
    # and Linux where /bin may be a symlink to /usr/bin, making PATH exclusion
    # unreliable for command-v based checks.
    _test-check-tool-deps)
      if [[ -n "${MAKATO_LOOP_TEST_MISSING_TOOL:-}" ]]; then
        # Simulate missing tool: temporarily shadow command -v for the target
        # tool by using a wrapper that intercepts the named binary.
        _mock_missing="$MAKATO_LOOP_TEST_MISSING_TOOL"
        _td_tmpdir="$(mktemp -d)"
        printf '#!/usr/bin/env bash\necho "loop: pre-flight error — required tool '"'"'%s'"'"' not found on PATH; install it and retry" >&2\nexit 127\n' \
          "$_mock_missing" > "$_td_tmpdir/$_mock_missing"
        chmod +x "$_td_tmpdir/$_mock_missing"
        # Replace command with non-executable so command -v fails for it.
        # Trick: put a non-executable placeholder so command -v succeeds but
        # calling it exits 127 — but we need command -v to FAIL.
        # Simpler: put the stub FIRST in PATH so it shadows the real binary,
        # AND make _check_tool_deps call the binary to verify it works.
        # Since _check_tool_deps uses `command -v` (not invocation), use
        # a subshell override instead: unset the binary via a wrapper function.
        rm -f "$_td_tmpdir/$_mock_missing"  # remove executable; leave dir empty for tool
        # Now shadow PATH so the tool is genuinely absent: the tmpdir has no
        # binary for it, and we override PATH to ONLY include the tmpdir plus
        # real system dirs BUT on a sub-process so only affects this test.
        # Since /bin == /usr/bin on Ubuntu, use a different approach:
        # call _check_tool_deps with the tool forced absent via bash function.
        _check_tool_deps_test() {
          local tool
          for tool in jq gh git python3; do
            if [[ "$tool" == "$_mock_missing" ]] || ! command -v "$tool" >/dev/null 2>&1; then
              echo "loop: pre-flight error — required tool '$tool' not found on PATH; install it and retry" >&2
              return 1
            fi
          done
          if [[ -z "${MAKATO_LOOP_GH_OVERRIDE:-}" \
             && -z "${MAKATO_LOOP_POLL_TEST_CMD:-}" \
             && -z "${MAKATO_LOOP_GRAPHQL_TEST_CMD:-}" ]]; then
            local _host
            _host="$(jq -r '.github_project.host // "github.com"' "${CONFIG_FILE}" 2>/dev/null || echo "github.com")"
            if ! GH_HOST="$_host" gh auth status --hostname "$_host" >/dev/null 2>&1; then
              echo "loop: pre-flight error — gh auth status failed for $_host; run 'gh auth login --hostname $_host' and retry" >&2
              return 1
            fi
          fi
          return 0
        }
        rmdir "$_td_tmpdir"
        _check_tool_deps_test
      else
        _check_tool_deps
      fi
      ;;
    # _test-reset-board-card-to-ready <issue> — exercise _reset_board_card_to_ready
    # in isolation (#687). Caller sets MAKATO_LOOP_RESET_BOARD_TEST_FILE,
    # CONFIG_FILE, and SPECS_DIR to ephemeral fixtures so no gh call is made.
    _test-reset-board-card-to-ready)
      _reset_board_card_to_ready "${1:?issue required}"
      ;;
    *) echo "loop: unknown test hook: $SUBCMD" >&2; exit 64 ;;
  esac
  exit 0
fi

case "$SUBCMD" in
  run)        cmd_run "$@" ;;
  poll)       cmd_poll "$@" ;;
  next)       cmd_next "$@" ;;
  status)     cmd_status ;;
  dispatch)   cmd_dispatch "$@" ;;
  promote-ready) echo "loop: promote-ready subcommand removed (status:ready-for-dev label bridge is no longer supported)" >&2; exit 1 ;;
  auto-seed)  cmd_auto_seed ;;
  reconcile-orphaned) cmd_reconcile_orphaned ;;
  reshape-pass) _reshape_pass ;;
  remove-worktrees) cmd_remove_worktrees ;;
  check-halt) cmd_check_halt ;;
  *) echo "loop: unknown subcommand: $SUBCMD" >&2; exit 64 ;;
esac
