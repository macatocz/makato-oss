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
# Conventions: matches scripts/context-handoff.sh (POSIX-ish bash, `set
# -euo pipefail`, python3 for ISO-8601 millisecond timestamps, jq for
# JSON work).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SPECS_DIR="$REPO_ROOT/specs"
STATE_DIR="${MAKATO_LOOP_STATE_DIR:-$REPO_ROOT/.claude/state}"
STATUS_FILE="$STATE_DIR/loop-status.json"
HALT_FILE="${MAKATO_HALT_FILE:-$HOME/.claude/HALT}"
CLAUDE_BIN="${MAKATO_CLAUDE_BIN:-claude}"
CONFIG_FILE="${MAKATO_LOOP_CONFIG:-$REPO_ROOT/.claude/config.json}"
DEFAULT_INTERVAL="${MAKATO_LOOP_INTERVAL:-300}"
DEFAULT_STATUS="${MAKATO_LOOP_STATUS:-Ready}"

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

# Merged-worktree reaper (#265). Worktrees under .claude/worktrees/ pile up on
# the operator's local disk: the per-issue `worktree.sh cleanup` only fires for
# a fully-autonomous run that reaches merge inside its own session, but most
# worktrees are hand-created (EnterWorktree) or orphaned by a dead session and
# carry no workflow-state, so nothing ever removes them. The reaper is a
# name-agnostic pre-poll sweep: it walks `git worktree list --porcelain` and
# removes worktrees whose branch has a MERGED PR, skipping any that are dirty,
# locked, retained, detached, nested, or the main checkout (see the guard stack
# in _reap_merged_worktrees). It runs on the operator's machine because that is
# where the worktrees physically live — a cloud GitHub Action cannot reach the
# local disk. Best-effort: any `gh`/`git` failure logs a WARN and never blocks
# the tick.
#   - MAKATO_LOOP_REAP_ON_POLL=0 disables the reaper entirely (default on).
#   - MAKATO_LOOP_REAP_INTERVAL throttles the pass to at most once per N seconds
#     (default 3600 = 1h); the function is called every tick but no-ops until
#     the window elapses. Set 0 to run every call (tests / one-shot cleanup).
REAP_ON_POLL="${MAKATO_LOOP_REAP_ON_POLL:-1}"
REAP_INTERVAL_SECS="${MAKATO_LOOP_REAP_INTERVAL:-3600}"

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
# Args: JSON object string
# ---------------------------------------------------------------------------
_write_status() {
  local payload="$1"
  local now
  now="$(_now)"
  local stamped
  stamped="$(jq --arg ts "$now" '. + {updated_at: $ts}' <<<"$payload")"
  local tmp
  tmp="$(mktemp)"
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
    # empty (issue #156). Route host through the env var instead, and let
    # gh's stderr surface real failures so callers see them (the outer
    # `run` loop retries next tick regardless — the loss was diagnostics).
    # `--limit 9999` mirrors plugins/makato-plan/.../board-audit.md — same
    # ceiling, same WARN-on-truncation contract.
    raw="$(GH_HOST="$host" gh project item-list "$number" \
      --owner "$owner" --format json --limit 9999 || echo '{"items":[]}')"
  fi
  jq --arg status "$status_name" \
    '[.items[]
      | select(.content.type == "Issue")
      | select(.status == $status)
      | {
          issue: .content.number,
          repository: .content.repository,
          title: .content.title,
          url: .content.url,
          status: .status,
          labels: (.labels // [])
        }]' <<<"$raw"
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
  _read_status | jq .
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
      # Snapshot the kill audit BEFORE signalling — active_workflow will
      # be nulled by cmd_dispatch shortly, but last_watchdog_kill is a
      # sibling field that survives.
      local kill_stamp
      kill_stamp="$(_now)"
      local audit
      audit="$(jq -n --argjson issue "$issue" \
        --arg stamped_at "$kill_stamp" \
        --argjson idle "$idle" \
        --argjson kill_secs "$STALL_KILL_SECS" \
        '{issue: $issue, killed_at: $stamped_at, idle_seconds: $idle, stall_kill_seconds: $kill_secs}')"
      _patch_status '.last_watchdog_kill' "$audit"
      _patch_status '.active_workflow.killed_by_watchdog' 'true'
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
      local warn_stamp
      warn_stamp="$(_now)"
      _patch_status '.active_workflow.stalled' 'true'
      _patch_status '.active_workflow.stalled_since' "\"$warn_stamp\""
      echo "loop: watchdog WARN — PO-agent idle for ${idle}s ≥ ${STALL_WARN_SECS}s (issue #$issue)" >&2
      warn_stamped=1
    fi

    sleep "$STALL_POLL_SECS"
  done
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
_derive_key_for_issue() {
  local issue="$1"
  local repo="${2:-${MAKATO_LOOP_DISPATCH_REPO:-}}"

  # Declare the repo flag once — both the body fetch and the title fetch
  # (#232 third fallback below) reuse it.
  local -a repo_flag=()
  [[ -n "$repo" ]] && repo_flag=(--repo "$repo")

  local body
  if [[ -n "${MAKATO_LOOP_ISSUE_BODY_OVERRIDE:-}" ]]; then
    body="$(cat "$MAKATO_LOOP_ISSUE_BODY_OVERRIDE" 2>/dev/null)" || return 1
  else
    body="$(gh issue view "$issue" "${repo_flag[@]}" --json body --jq '.body' 2>/dev/null)" || return 1
  fi
  [[ -n "$body" ]] || return 1

  # Primary: footer line  *Feature slug: `<slug>` — produced by to-issues …*
  # BSD/macOS `sed` compatible (no -E, no PCRE lookarounds).
  local slug
  slug="$(printf '%s\n' "$body" \
    | sed -n "s/.*Feature slug: \`\([^\`]*\)\` — produced by to-issues.*/\1/p" \
    | head -1)"

  # Fallback: top-of-body provenance  specs/<slug>/stories.json
  if [[ -z "$slug" ]]; then
    slug="$(printf '%s\n' "$body" \
      | sed -n 's|.*specs/\([^/]*\)/stories\.json.*|\1|p' \
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
      title="$(gh issue view "$issue" "${repo_flag[@]}" --json title --jq '.title' 2>/dev/null)" || true
    fi
    if [[ -n "$title" ]]; then
      # seed-issue normalization: lowercase, non-alnum → '-', collapse runs,
      # strip leading/trailing '-', truncate to 40 chars, strip a trailing '-'
      # left by truncation. sed -E with basic classes only (macOS + GNU safe).
      local norm
      norm="$(printf '%s' "$title" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
        | cut -c1-40 \
        | sed -E 's/-+$//')"
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
  local dispatch_status="${MAKATO_LOOP_DISPATCH_STATUS:-$DEFAULT_STATUS}"

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
    board="$(GH_HOST="$host" gh project item-list "$number" --owner "$owner" \
      --format json --limit 9999 2>/dev/null || echo '{"items":[]}')"
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
# _promote_labelled_ready — bridge label → board for non-to-issues issues
# (#231). loop's queue is the board Status=Ready set (cmd_poll); nothing moves
# a card TO Ready except seed-issue (manual) or issue-to-project autonomous
# mode (a strict created-issues.json consumer). So a hand-filed / auto-filed
# issue carrying status:ready-for-dev sits off-queue forever. This pass lists
# open status:ready-for-dev issues and promotes those that are (a) not already
# at board Status=Ready and (b) not carrying an exclusion label, using the same
# `gh project item-edit` seed-issue uses.
#
# Best-effort: any gh failure logs a WARN and is swallowed — a GitHub hiccup
# must never block a tick (mirrors _assign_issue's contract).
#
# Test hooks (offline):
#   MAKATO_LOOP_PROMOTE_OVERRIDE — path to a JSON file mimicking
#       `gh issue list --json number,labels` output.
#   MAKATO_LOOP_PROMOTE_DRYRUN=1 — log "would promote #N → Ready" instead of
#       calling `gh project item-edit` (asserted by T28).
# ---------------------------------------------------------------------------
# Labels that veto promotion even when status:ready-for-dev is present.
# `needs-human-review` is applied on every HALT path but `status:ready-for-dev`
# is never stripped there — without this veto the promotion pass would drag a
# halted card back onto Ready every tick, where the in-flight guard then blocks
# dispatch, leaving the issue stuck. Excluding it keeps a halted issue off Ready
# until a human clears the label (#286).
_PROMOTE_EXCLUSION_LABELS="triage experimental status:blocked autonomous:halt needs-human-review"
_PROMOTE_READY_LABEL="status:ready-for-dev"

_promote_labelled_ready() {
  local dryrun="${MAKATO_LOOP_PROMOTE_DRYRUN:-}"

  # Candidate list: open issues carrying the ready label.
  local candidates
  if [[ -n "${MAKATO_LOOP_PROMOTE_OVERRIDE:-}" ]]; then
    candidates="$(cat "$MAKATO_LOOP_PROMOTE_OVERRIDE" 2>/dev/null || echo '[]')"
  else
    local -a repo_flag=()
    [[ -n "${MAKATO_LOOP_DISPATCH_REPO:-}" ]] && repo_flag=(--repo "${MAKATO_LOOP_DISPATCH_REPO}")
    candidates="$(gh issue list "${repo_flag[@]}" \
      --label "$_PROMOTE_READY_LABEL" --state open \
      --json number,labels --limit 200 2>/dev/null || echo '[]')"
  fi
  [[ -n "$candidates" ]] || candidates='[]'

  local count
  count="$(jq 'length' <<<"$candidates" 2>/dev/null || echo 0)"
  [[ "$count" -gt 0 ]] || return 0

  # Board mutation needs the status field id + Ready option id from config.
  # Resolve them once; if absent we cannot write the board — WARN and skip the
  # whole pass (degrade to pre-#231 behavior, never fail the tick). Skipped
  # under DRYRUN so the offline smoke test does not need a full config.
  local status_field_id ready_option_id host owner number
  if [[ -z "$dryrun" ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
      echo "loop: WARN — promote-ready skipped: .claude/config.json not found" >&2
      return 0
    fi
    status_field_id="$(jq -r '.github_project.fields.status.id // empty' "$CONFIG_FILE")"
    ready_option_id="$(jq -r '.github_project.fields.status.options.ready // empty' "$CONFIG_FILE")"
    host="$(jq -r '.github_project.host // "github.com"' "$CONFIG_FILE")"
    owner="$(jq -r '.github_project.owner // empty' "$CONFIG_FILE")"
    number="$(jq -r '.github_project.number // empty' "$CONFIG_FILE")"
    if [[ -z "$status_field_id" || -z "$ready_option_id" || -z "$owner" || -z "$number" ]]; then
      echo "loop: WARN — promote-ready skipped: status field / ready option / project missing in config" >&2
      return 0
    fi
  fi

  # Snapshot the current Ready set so we skip already-Ready issues (idempotent,
  # avoids a redundant item-edit). Best-effort — an empty snapshot just means
  # we may attempt a promote that the board no-ops.
  local ready_now=""
  if [[ -z "$dryrun" ]]; then
    ready_now="$(cmd_poll Ready 2>/dev/null | jq -r '.[].issue' 2>/dev/null || true)"
  fi

  local n labels excluded lbl
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    labels="$(jq -r --argjson i "$n" \
      '.[] | select(.number == $i) | [.labels[].name] | join(" ")' \
      <<<"$candidates" 2>/dev/null || echo "")"

    # Exclusion guard: any excluded label vetoes promotion.
    excluded=""
    for lbl in $_PROMOTE_EXCLUSION_LABELS; do
      if [[ " $labels " == *" $lbl "* ]]; then excluded="$lbl"; break; fi
    done
    if [[ -n "$excluded" ]]; then
      echo "loop: promote-ready — skip #$n (carries exclusion label '$excluded')" >&2
      continue
    fi

    # Skip issues already at Ready.
    if [[ -n "$ready_now" ]] && grep -qx "$n" <<<"$ready_now"; then
      echo "loop: promote-ready — skip #$n (already at Status=Ready)" >&2
      continue
    fi

    if [[ -n "$dryrun" ]]; then
      echo "loop: would promote #$n → Ready" >&2
      continue
    fi

    # Add to board if absent, then set Status=Ready. Both best-effort.
    local item_id=""
    item_id="$(GH_HOST="$host" gh project item-add "$number" --owner "$owner" \
      --url "https://github.com/${MAKATO_LOOP_DISPATCH_REPO:-}/issues/$n" \
      --format json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)"
    if [[ -z "$item_id" ]]; then
      # Already on the board — find its item id from the board listing.
      item_id="$(GH_HOST="$host" gh project item-list "$number" --owner "$owner" \
        --format json --limit 9999 2>/dev/null \
        | jq -r --argjson i "$n" '.items[] | select(.content.number == $i) | .id' 2>/dev/null \
        | head -1 || true)"
    fi
    if [[ -z "$item_id" ]]; then
      echo "loop: WARN — promote-ready could not resolve board item for #$n; skipping" >&2
      continue
    fi
    if GH_HOST="$host" gh project item-edit --id "$item_id" \
        --project-id "$(jq -r '.github_project.project_node_id // empty' "$CONFIG_FILE")" \
        --field-id "$status_field_id" \
        --single-select-option-id "$ready_option_id" >/dev/null 2>&1; then
      echo "loop: promote-ready — set #$n → Status=Ready" >&2
    else
      echo "loop: WARN — promote-ready failed to set #$n → Ready (tick continues)" >&2
    fi
  done < <(jq -r '.[].number' <<<"$candidates" 2>/dev/null)

  return 0
}

# ---------------------------------------------------------------------------
# promote-ready — standalone entry point for the label→board promotion pass
# (#231). Also called by cmd_run before each poll when Status=Ready.
# ---------------------------------------------------------------------------
cmd_promote_ready() {
  _promote_labelled_ready
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
    # Guard 8: the branch's work must have LANDED on the base branch — either a
    # merged PR (any merge style) OR the HEAD is already an ancestor of the
    # base ref (catches renamed-head branches the PR lookup misses). A worktree
    # whose work is not yet in base is live and must survive.
    local landed
    landed="$(_reap_branch_landed "$cur_head" "$branch" "$repo" "$base_ref")"
    if [[ -z "$landed" ]]; then
      echo "loop: reap skip $rp (branch $branch not landed on $base_ref)" >&2; return 0
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
# remove-worktrees — standalone entry point for the merged-worktree reaper
# (#265). Also called by cmd_run before each poll. Bypass the throttle with
# MAKATO_LOOP_REAP_INTERVAL=0; inspect safely with MAKATO_LOOP_REAP_DRYRUN=1.
# ---------------------------------------------------------------------------
cmd_remove_worktrees() {
  _reap_merged_worktrees
}

# ---------------------------------------------------------------------------
# dispatch <ISSUE_NUMBER> [--dry-run]
# ---------------------------------------------------------------------------
cmd_dispatch() {
  local issue="${1:?issue number required}"
  local dry_run="${2:-}"

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
    branch="feat/${issue}-${key}"
  else
    key=""
    echo "loop: WARN — could not derive KEY for issue #${issue} (no to-issues provenance in body); po-agent will fail input validation" >&2
  fi

  # Routing: issues labelled type:change are dispatched through the
  # makato-change:orchestrate --autonomous path; everything else goes to
  # the po-agent (makato-build pipeline).
  # Test hook: MAKATO_LOOP_ISSUE_TYPE_OVERRIDE — when set, its value is used
  # as issue_type directly (keeps routing smoke tests offline).
  local issue_type=""
  if [[ -n "${MAKATO_LOOP_ISSUE_TYPE_OVERRIDE:-}" ]]; then
    issue_type="$MAKATO_LOOP_ISSUE_TYPE_OVERRIDE"
  else
    issue_type="$(gh issue view "$issue" --repo "${MAKATO_LOOP_DISPATCH_REPO:-}" \
      --json labels \
      --jq '[.labels[].name | select(startswith("type:"))] | first // ""' 2>/dev/null || true)"
  fi

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
    # Block on child. `wait` returns the child's exit status if we name it.
    wait "$child_pid" || rc=$?
    # Reap watchdog — it either exited already (kill path or child-exit)
    # or is between polls; killing is a no-op in the former case.
    if [[ -n "$watchdog_pid" ]] && kill -0 "$watchdog_pid" 2>/dev/null; then
      kill -TERM "$watchdog_pid" 2>/dev/null || true
      wait "$watchdog_pid" 2>/dev/null || true
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
# run — long-running poll loop. CLI flags override env defaults.
# ---------------------------------------------------------------------------
cmd_run() {
  local status_name="$DEFAULT_STATUS"
  local interval="$DEFAULT_INTERVAL"
  local dry_run=""
  local once=""
  local force=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status)   status_name="${2:?--status requires a value}"; shift 2 ;;
      --interval) interval="${2:?--interval requires a value}"; shift 2 ;;
      --dry-run)  dry_run="--dry-run"; shift ;;
      --once)     once="1"; shift ;;
      --force)    force="1"; shift ;;
      *) echo "loop: unknown flag: $1" >&2; return 64 ;;
    esac
  done

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

  while true; do
    if ! cmd_check_halt; then
      _patch_status '.last_halt_at' "\"$(_now)\""
      return 0
    fi

    # Pre-poll bridge (#231): promote any status:ready-for-dev issue that is
    # off-board-Ready onto Ready, so hand-filed / auto-filed issues (no
    # to-issues provenance, no created-issues.json) enter the queue the same
    # tick. Only meaningful when polling the Ready status; a custom-status run
    # must not force-promote to Ready. Best-effort — never blocks the tick.
    if [[ "$status_name" == "Ready" && -z "$dry_run" ]]; then
      _promote_labelled_ready || true
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

    local queue queue_depth
    queue="$(cmd_poll "$status_name" || echo '[]')"
    queue_depth="$(jq 'length' <<<"$queue")"
    # Batch the three poll-result fields into a single status write — saves
    # three `_patch_status` invocations (each reads + jq-merges + mktemp + mv).
    local now
    now="$(_now)"
    _write_status "$(jq \
      --arg ts "$now" \
      --argjson depth "$queue_depth" \
      --argjson q "$(jq '[.[].issue]' <<<"$queue")" \
      '. + {last_poll: $ts, queue_depth: $depth, queue: $q}' \
      <<<"$(_read_status)")"

    local in_flight
    in_flight="$(in_flight_issues)"
    local next_issue
    next_issue="$(jq -r --argjson in_flight \
      "$(jq -R . <<<"$in_flight" | jq -sc 'map(select(length>0))')" \
      '.[] | .issue as $n
        | select(($in_flight | index($n|tostring) | not)) | $n' \
      <<<"$queue" | head -1)"

    if [[ -n "$next_issue" ]]; then
      echo "loop: dispatching issue #$next_issue (status=$status_name, queue_depth=$queue_depth)" >&2
      # Resolve the owning repository for this issue from the poll result
      # (the board is cross-repo — every item carries its own repository).
      # Passed to cmd_dispatch via env so the public `dispatch <ISSUE>`
      # signature is unchanged; the assign-on-dispatch step needs it for
      # `gh issue edit --repo`.
      local next_repo
      next_repo="$(jq -r --argjson n "$next_issue" \
        'map(select(.issue == $n)) | .[0].repository // empty' <<<"$queue")"
      # `cmd_dispatch` already clears active_workflow on return; we ignore
      # the PO-agent's exit code — it writes its own HALT audit to
      # workflow-state.json; the loop's job is to surface the next issue,
      # not to second-guess the orchestrator's terminal state.
      MAKATO_LOOP_DISPATCH_REPO="$next_repo" cmd_dispatch "$next_issue" "$dry_run" || true
    else
      echo "loop: queue empty or fully in-flight (depth=$queue_depth) — idle" >&2
    fi

    if [[ -n "$once" ]]; then
      return 0
    fi

    # #171 — wall-clock-guaranteed sleep. Naive `sleep "$interval"` can
    # return early after a macOS host suspend/resume; _guarded_sleep
    # re-enters raw sleep until the requested wall-clock has elapsed.
    _guarded_sleep "$interval"
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
  promote-ready) cmd_promote_ready ;;
  remove-worktrees) cmd_remove_worktrees ;;
  check-halt) cmd_check_halt ;;
  *) echo "loop: unknown subcommand: $SUBCMD" >&2; exit 64 ;;
esac
