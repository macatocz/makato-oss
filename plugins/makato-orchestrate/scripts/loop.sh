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
# dispatch <ISSUE_NUMBER> [--dry-run]
# ---------------------------------------------------------------------------
cmd_dispatch() {
  local issue="${1:?issue number required}"
  local dry_run="${2:-}"

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

  if [[ "$dry_run" == "--dry-run" ]]; then
    echo "loop: --dry-run — would exec: $CLAUDE_BIN --dangerously-skip-permissions -p \"<dispatch makato-orchestrate:po-agent for issue #${issue}>\"" >&2
    _patch_status '.active_workflow' 'null'
    return 0
  fi

  # Test hook — exercise the full state-machine without forking a subprocess.
  if [[ "${MAKATO_LOOP_DRY_DISPATCH:-0}" == "1" ]]; then
    _patch_status '.last_dispatch_issue' "$issue"
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
  dispatch_prompt="Use the Task tool to dispatch the makato-orchestrate:po-agent subagent to drive GitHub issue #${issue} to a merged PR. Pass the issue number as the sole argument. The po-agent owns the outer loop, workflow-state, and all makato-build --autonomous dispatch; do not invoke makato-build or makato-plan skills directly from this session. Return the po-agent's final R1 envelope verbatim."

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
      MAKATO_HEADLESS=1 "$CLAUDE_BIN" --dangerously-skip-permissions \
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
    # log capture, no watchdog.
    if [[ -n "$child_cmd" ]]; then
      # shellcheck disable=SC2086
      $child_cmd || rc=$?
    else
      MAKATO_HEADLESS=1 "$CLAUDE_BIN" --dangerously-skip-permissions \
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
      # `cmd_dispatch` already clears active_workflow on return; we ignore
      # the PO-agent's exit code — it writes its own HALT audit to
      # workflow-state.json; the loop's job is to surface the next issue,
      # not to second-guess the orchestrator's terminal state.
      cmd_dispatch "$next_issue" "$dry_run" || true
    else
      echo "loop: queue empty or fully in-flight (depth=$queue_depth) — idle" >&2
    fi

    if [[ -n "$once" ]]; then
      return 0
    fi

    sleep "$interval"
  done
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
SUBCMD="${1:?subcommand required: run|poll|next|status|dispatch|check-halt}"
shift || true

case "$SUBCMD" in
  run)        cmd_run "$@" ;;
  poll)       cmd_poll "$@" ;;
  next)       cmd_next "$@" ;;
  status)     cmd_status ;;
  dispatch)   cmd_dispatch "$@" ;;
  check-halt) cmd_check_halt ;;
  *) echo "loop: unknown subcommand: $SUBCMD" >&2; exit 64 ;;
esac
