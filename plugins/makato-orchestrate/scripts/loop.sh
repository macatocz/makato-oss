#!/usr/bin/env bash
# loop.sh — autonomous polling driver for the PO-agent (GAP-007 / #33).
#
# Polls a GitHub Projects v2 board and dispatches the PO-agent serially against
# each Ready item, single-threaded. Main flow only: cmd_run + the subcommand
# dispatcher. Helper/subcommand functions live in functions.sh; tunable
# parameters + their env overrides live in ../config/config.yml (see config.md).
# Run `loop.sh --help` for the subcommand/flag overview.
#
# Conventions: POSIX-ish bash, `set -euo pipefail`, python3 for timestamps, jq
# for JSON (matches scripts/context-handoff.sh).
#
# SC2034: config vars + runtime paths are consumed in functions.sh (sourced).
# SC1091: functions.sh is resolved at runtime, not a static input.
# shellcheck disable=SC2034,SC1091
set -euo pipefail

# ---------------------------------------------------------------------------
# Help — `loop.sh -h | --help | help` prints a short overview and exits.
# ---------------------------------------------------------------------------
_print_help() {
  cat <<'HELP'
loop.sh — autonomous polling driver for the PO-agent (makato-orchestrate).

USAGE
  loop.sh <subcommand> [options]

SUBCOMMANDS
  run [options]              Long-running poll loop; dispatches Ready board items serially.
  poll [STATUS]              Print the board queue as JSON.
  next [STATUS]              Print the next issue number that would be dispatched.
  status                     Pretty-print .claude/state/loop-status.json.
  dispatch <ISSUE> [--dry-run] [--resume]
                             Dispatch one issue (needs MAKATO_LOOP_DISPATCH_REPO);
                             --resume continues a HALTed/orphaned run from its kept workflow-state.
  auto-seed                  Run one pre-poll auto-seed pass over unprepared issues.
  reconcile-orphaned         Move orphaned In-progress cards to Blocked+needs-human-review.
  reshape-pass               Run one Needs-Planning reshape pass.
  remove-worktrees           Reap merged worktrees + orphaned specs/ folders once.
  check-halt                 Exit 0 if no HALT file, 1 if present.
  -h, --help                 Show this help.

`run` OPTIONS
  --status NAME              Board Status to dispatch from (default Ready; comma-list ok).
  --interval S               Seconds between poll ticks (default 300).
  --dry-run                  Show what would dispatch without spawning anything.
  --once                     Run a single poll+dispatch cycle, then exit.
  --force                    Reclaim a live incumbent loop (SIGTERM→SIGKILL).
  --promote-unblocked        Promote unblocked Todo/Blocked issues to Ready each tick.

CONFIG
  MAKATO_TARGET_REPO_ROOT optionally selects a consumer checkout when the
  installed orchestrator is launched from another repository or directory.
  Otherwise the current checkout is used.
  Tunable parameters + env overrides live in ../config/config.yml
  and are documented in ../config/config.md.
HELP
}

# Help short-circuits before any git/config work so it runs from anywhere.
case "${1:-}" in
  -h|--help|help) _print_help; exit 0 ;;
esac

# `MAKATO_TARGET_REPO_ROOT` is set by the suite runner when the installed
# orchestrator is dispatching a consumer repository from another CWD.
if [[ -n "${MAKATO_TARGET_REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$MAKATO_TARGET_REPO_ROOT" 2>/dev/null && pwd -P)" || {
    echo "loop: target repository root is not a directory: $MAKATO_TARGET_REPO_ROOT" >&2
    exit 1
  }
  git -C "$REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || {
    echo "loop: target repository root is not a git checkout: $REPO_ROOT" >&2
    exit 1
  }
else
  REPO_ROOT="$(git rev-parse --show-toplevel)"
fi
SPECS_DIR="${SPECS_DIR:-$REPO_ROOT/specs}"
STATE_DIR="${MAKATO_LOOP_STATE_DIR:-$REPO_ROOT/.claude/state}"
STATUS_FILE="$STATE_DIR/loop-status.json"
# HALT_FILE is intentionally operator-global (HALT-000): one file stops every
# loop/fleet/supervisor on the host. It is the documented exception to issue #6
# path re-homing — do NOT move its default under STATE_DIR. Override per-run
# with MAKATO_HALT_FILE.
HALT_FILE="${MAKATO_HALT_FILE:-$HOME/.claude/HALT}"
CLAUDE_BIN="${MAKATO_HARNESS_BIN:-omp}"
CONFIG_FILE="${MAKATO_LOOP_CONFIG:-$REPO_ROOT/.claude/config.json}"

# --- Tunable parameters — sourced from config/config.yml (see config.md) ---
# parse-config.py emits `NAME="${ENV:-default}"` so the env-override contract is
# unchanged. MAKATO_LOOP_CONFIG_YML / MAKATO_LOOP_FUNCTIONS override the sibling
# file paths (plugin-cache copies, tests run from a temp dir). The parser is
# resolved next to config.yml so relocating the config relocates its parser too.
_LOOP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LOOP_CONFIG_YML="${MAKATO_LOOP_CONFIG_YML:-$_LOOP_SCRIPT_DIR/../config/config.yml}"
_LOOP_FUNCTIONS="${MAKATO_LOOP_FUNCTIONS:-$_LOOP_SCRIPT_DIR/functions.sh}"
_LOOP_CONFIG_PARSER="${MAKATO_LOOP_CONFIG_PARSER:-$(dirname "$_LOOP_CONFIG_YML")/parse-config.py}"
eval "$(python3 "$_LOOP_CONFIG_PARSER" "$_LOOP_CONFIG_YML")"

_resolve_plugin_root() {
  local plugin="$1" candidate
  case "$plugin" in
    makato-orchestrate)
      candidate="$(cd "$_LOOP_SCRIPT_DIR/.." && pwd)"
      [[ -f "$candidate/.claude-plugin/plugin.json" ]] && {
        printf '%s\n' "$candidate"
        return 0
      }
      ;;
  esac

  local plugin_cache_parent
  plugin_cache_parent="$(cd "$_LOOP_SCRIPT_DIR/../.." && pwd)"
  for candidate in \
    "$REPO_ROOT/plugins/$plugin" \
    "$plugin_cache_parent/$plugin" \
    "$plugin_cache_parent"/makato-suite___"$plugin"___*; do
    if [[ -f "$candidate/.claude-plugin/plugin.json" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
}

MAKATO_ORCHESTRATE_ROOT="${MAKATO_ORCHESTRATE_ROOT:-$(_resolve_plugin_root makato-orchestrate)}"
MAKATO_BUILD_ROOT="${MAKATO_BUILD_ROOT:-$(_resolve_plugin_root makato-build)}"
MAKATO_PLAN_ROOT="${MAKATO_PLAN_ROOT:-$(_resolve_plugin_root makato-plan)}"
export MAKATO_ORCHESTRATE_ROOT MAKATO_BUILD_ROOT MAKATO_PLAN_ROOT
# API_FORCE_IDLE_TIMEOUT is opt-in (see config.md); export only when set.
if [[ -n "${API_FORCE_IDLE_TIMEOUT:-}" ]]; then
  export API_FORCE_IDLE_TIMEOUT
fi
# Open-model endpoint (issue #7): forward MAKATO_OPEN_ENDPOINT_URL as
# ANTHROPIC_BASE_URL so omp / Claude Code routes every dispatch through the
# configured cloud open-model API. A no-op when the var is empty (default).
if [[ -n "${MAKATO_OPEN_ENDPOINT_URL:-}" ]]; then
  export ANTHROPIC_BASE_URL="$MAKATO_OPEN_ENDPOINT_URL"
fi
# Provider-neutral profile/harness-mode propagation (Task 3,
# local-openai-gpt-macos-compatibility): forward the caller's selected model
# profile (config/model-profiles.yml, scripts/resolve-model-profile.py) and
# harness mode (plugins/makato-orchestrate/scripts/harness-command.sh) into
# every dispatched/resumed child process's environment. Neither var carries a
# credential — profile installation and credential handling remain the
# caller's responsibility via scripts/select-model-profile.sh. No-op when
# either var is unset (default: whatever OMP/Claude Code already has active).
if [[ -n "${MAKATO_MODEL_PROFILE:-}" ]]; then
  export MAKATO_MODEL_PROFILE
fi
if [[ -n "${MAKATO_HARNESS_MODE:-}" ]]; then
  export MAKATO_HARNESS_MODE
fi
PIDFILE="${MAKATO_LOOP_PIDFILE:-$STATE_DIR/loop.pid}"

# --- Floor guards: clamp hostile/non-numeric overrides to safe values ---
if [[ ! "$IDLE_BACKOFF_FACTOR" =~ ^[0-9]+$ ]] || (( IDLE_BACKOFF_FACTOR < 1 )); then
  IDLE_BACKOFF_FACTOR=2
fi
if [[ ! "$IDLE_BACKOFF_MAX" =~ ^[0-9]+$ ]] || (( IDLE_BACKOFF_MAX < DEFAULT_INTERVAL )); then
  IDLE_BACKOFF_MAX="$DEFAULT_INTERVAL"
fi
if [[ ! "$POLL_RETRIES" =~ ^[0-9]+$ ]] || [[ "$POLL_RETRIES" -lt 1 ]]; then
  POLL_RETRIES=1
fi
if [[ ! "$POLL_BACKOFF_BASE_SECS" =~ ^[0-9]+$ ]]; then
  POLL_BACKOFF_BASE_SECS=2
fi
if [[ ! "$FALLBACK_RETRIES" =~ ^[0-9]+$ ]] || [[ "$FALLBACK_RETRIES" -lt 1 ]]; then
  FALLBACK_RETRIES=1
fi
if [[ ! "$FALLBACK_BACKOFF_BASE_SECS" =~ ^[0-9]+$ ]]; then
  FALLBACK_BACKOFF_BASE_SECS=2
fi
if [[ ! "$SLEEP_MAX_STEP_SECS" =~ ^[0-9]+$ ]] || [[ "$SLEEP_MAX_STEP_SECS" -lt 1 ]]; then
  SLEEP_MAX_STEP_SECS=1
fi

mkdir -p "$STATE_DIR"

# --- Load helper + subcommand functions ---
# shellcheck source=functions.sh
source "$_LOOP_FUNCTIONS"
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

    # Pre-poll stale status:blocked reconciliation (#32): heal issues whose only
    # blocked-by:N predecessor is already merged/closed but whose stale
    # status:blocked label still vetoes them in the dispatch gate — silently
    # starving the queue. The safety-net (_reconcile_blocked_by_labels) lived
    # only in promote-ready.sh's promote mode, so a plain `run --status Ready`
    # never triggered it. Run it every tick as a standalone pass, independent of
    # ALLOW_TODO. Best-effort — a non-zero exit is logged and the tick continues.
    # Skipped under --dry-run. Toggle via MAKATO_LOOP_RECONCILE_BLOCKED_ON_POLL.
    if [[ "${RECONCILE_BLOCKED_ON_POLL}" != "0" && -z "$dry_run" ]]; then
      local _rb_bin="${MAKATO_PROMOTE_PATH:-}"
      if [[ -z "$_rb_bin" ]]; then
        _rb_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/promote-ready.sh"
      fi
      if [[ -x "$_rb_bin" ]]; then
        local _rb_rc=0
        "$_rb_bin" reconcile-blocked 2>&1 | while IFS= read -r _line; do
          echo "loop: reconcile-blocked: $_line" >&2
        done || _rb_rc=$?
        if [[ "$_rb_rc" -ne 0 ]]; then
          echo "loop: reconcile-blocked: promote-ready.sh exited $_rb_rc (logged, tick continues)" >&2
        fi
      fi
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

    # Pre-poll resume of parked issues: build-grill-with-docs parks an issue on ONE batched questions comment
    # (card -> Blocked, awaiting-answers-<N>.json in the spec folder). A Blocked card never shows up in the Ready
    # poll, so ask the helper whether the human moved it back (Ready / In progress) and resume it with
    # `dispatch --resume`. Skipped under --dry-run. Best-effort. Toggle via MAKATO_LOOP_AWAITING_RESUME_DISABLE.
    if [[ "${AWAITING_RESUME_DISABLE}" != "1" && -z "$dry_run" ]]; then
      _resume_answered_questions || true
      if [[ -n "${_LOOP_RESUMED_ISSUE:-}" ]]; then
        dispatched_issues+=("$_LOOP_RESUMED_ISSUE")
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
# When sourced (tests call helpers directly), define functions and stop here —
# do not run the argv dispatcher.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # shellcheck disable=SC2317  # exit is the fallback when `return` is invalid (not sourced)
  return 0 2>/dev/null || exit 0
fi

SUBCMD="${1:?subcommand required: run|poll|next|status|dispatch|check-halt (see --help)}"
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
    # _test-check-heal-stale-blocked <issue> <repo> <labels_json> — exercise the
    # #32 gate anti-starvation helper. Blocker state comes from
    # MAKATO_LOOP_BLOCKER_STATE_OVERRIDE; label writes go to MAKATO_LOOP_LABEL_TEST_FILE;
    # the per-issue skip counter persists in loop-status.json under MAKATO_LOOP_STATE_DIR.
    # Exits 1 when self-healed (dispatch proceeds), 0 when skipped/escalated.
    _test-check-heal-stale-blocked) _check_and_heal_stale_blocked "$@" ;;
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
    # _test-resume-answered — exercise _resume_answered_questions (parked-on-questions resume pass).
    # cmd_dispatch is replaced by a recorder appending "dispatch <args> repo=<r> status=<s>" to
    # MAKATO_LOOP_AWAITING_TEST_FILE (escalations land in the same file); MAKATO_HUMAN_QUESTIONS
    # points at a stub helper, SPECS_DIR / MAKATO_LOOP_STATE_DIR at the fixtures.
    _test-resume-answered)
      cmd_dispatch() {
        echo "dispatch $* repo=${MAKATO_LOOP_DISPATCH_REPO:-} status=${MAKATO_LOOP_ITEM_STATUS:-}" \
          >>"${MAKATO_LOOP_AWAITING_TEST_FILE:?MAKATO_LOOP_AWAITING_TEST_FILE required}"
      }
      _resume_answered_questions "$@"
      echo "resumed=${_LOOP_RESUMED_ISSUE:-}"
      ;;
    # _test-issue-awaiting-answers <issue> [specs-dir] — exit 0 when a parked marker exists.
    _test-issue-awaiting-answers) _issue_awaiting_answers "$@" ;;
    # _test-reap-awaiting <realpath> — exit 0 when the worktree's issue is parked on questions (reaper guard 7b).
    _test-reap-awaiting) _reap_is_awaiting_answers "$@" ;;
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
    # _test-pre-dispatch-plan-guard <key> [issue] — exercise
    # _pre_dispatch_plan_guard deterministically. SPECS_DIR and CLAUDE_BIN are
    # consumed from the environment; the caller sets them to ephemeral test
    # fixtures so no real claude process or GitHub calls are needed.
    _test-pre-dispatch-plan-guard)
      _test_pdpg_key="${1:?key required}"
      _test_pdpg_issue="${2:-}"
      _pre_dispatch_plan_guard "$_test_pdpg_key" "$_test_pdpg_issue"
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
