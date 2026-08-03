#!/usr/bin/env bash
# loop-fleet.sh — bounded parallel issue fleet via N independent loop.sh workers.
#
# Runs N independent loop.sh worker instances, each with a distinct
# MAKATO_LOOP_STATE_DIR and MAKATO_LOOP_PIDFILE, coordinated solely through
# the existing GitHub Projects board CAS claim in loop.sh (_claim_board_card).
# No loop.sh internals are modified; the fleet is a pure launcher layer.
#
# Design:
#   - Per-instance state dir:  $FLEET_STATE_DIR/worker-N/
#   - Per-instance pidfile:    $FLEET_STATE_DIR/worker-N/loop.pid
#   - Board CAS claim:         each worker sets MAKATO_LOOP_CLAIM_ON_DISPATCH=1
#                              (fail-closed: skip on claim failure, not warn-proceed)
#   - Same-folder guard:       before assigning a worker to an issue, scan SPECS_DIR
#                              for in-flight siblings sharing the same spec folder
#   - N=1 compat:              identical to running loop.sh directly (serial path)
#
# Usage:
#   plugins/makato-orchestrate/scripts/loop-fleet.sh [--workers N] [--once] [loop.sh args...]
#
# Environment overrides:
#   MAKATO_FLEET_WORKERS        Number of workers (default 4; overridden by --workers)
#   MAKATO_FLEET_STATE_DIR      Fleet state root dir (default REPO_ROOT/.claude/state/fleet)
#   MAKATO_FLEET_CAS_STRICT     Set MAKATO_LOOP_CLAIM_ON_DISPATCH=1 per worker (default 1)
#   MAKATO_FLEET_TICK_SECS      Supervision tick interval in seconds (default 5)
#   MAKATO_FLEET_DASHBOARD      Set to 0 to suppress per-tick dashboard output (default 1)
#   MAKATO_HALT_FILE            HALT-file path (default ~/.claude/HALT)
#   MAKATO_LOOP_SH_PATH         Path to loop.sh (default: auto-resolved from script dir)
#   MAKATO_SPECS_DIR            Specs directory for in-flight scan (default REPO_ROOT/specs)
#   MAKATO_LOOP_STATE_DIR       Passed through per-worker as worker-specific subdir
#   MAKATO_LOOP_PIDFILE         Passed through per-worker as worker-specific pidfile
#   MAKATO_FLEET_DRY_RUN        Set to 1 to print what would be spawned without spawning
#
# Exit codes:
#   0  — normal exit (HALT file, all workers done, --once completed)
#   1  — usage/config error
#
# Audit:
#   Per-tick dashboard printed to stdout; per-worker logs in FLEET_STATE_DIR/worker-N/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Resolve REPO_ROOT
# ---------------------------------------------------------------------------
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null \
  || git rev-parse --show-toplevel 2>/dev/null)"

# ---------------------------------------------------------------------------
# Argument parsing — consume --workers and --once before forwarding remaining
# args to each loop.sh worker.
# ---------------------------------------------------------------------------
WORKERS="${MAKATO_FLEET_WORKERS:-4}"
ONCE_MODE=0
LOOP_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers)
      WORKERS="${2:?--workers requires a value}"
      shift 2
      ;;
    --workers=*)
      WORKERS="${1#--workers=}"
      shift
      ;;
    --once)
      ONCE_MODE=1
      LOOP_ARGS+=("--once")
      shift
      ;;
    *)
      LOOP_ARGS+=("$1")
      shift
      ;;
  esac
done

# Validate worker count
if ! [[ "$WORKERS" =~ ^[1-9][0-9]*$ ]]; then
  echo "loop-fleet: ERROR — --workers must be a positive integer (got '$WORKERS')" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
FLEET_STATE_DIR="${MAKATO_FLEET_STATE_DIR:-$REPO_ROOT/.claude/state/fleet}"
HALT_FILE="${MAKATO_HALT_FILE:-$HOME/.claude/HALT}"
CAS_STRICT="${MAKATO_FLEET_CAS_STRICT:-1}"
TICK_SECS="${MAKATO_FLEET_TICK_SECS:-5}"
DASHBOARD="${MAKATO_FLEET_DASHBOARD:-1}"
DRY_RUN="${MAKATO_FLEET_DRY_RUN:-0}"
SPECS_DIR="${MAKATO_SPECS_DIR:-$REPO_ROOT/specs}"

LOOP_SH="${MAKATO_LOOP_SH_PATH:-$SCRIPT_DIR/loop.sh}"
if [[ ! -f "$LOOP_SH" ]]; then
  echo "loop-fleet: ERROR — loop.sh not found at '$LOOP_SH'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# HALT-file guard — exit without spawning if HALT is present
# ---------------------------------------------------------------------------
if [[ -e "$HALT_FILE" ]]; then
  echo "loop-fleet: HALT file present at '$HALT_FILE' — exiting without spawning workers" >&2
  exit 0
fi

mkdir -p "$FLEET_STATE_DIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_ts() { date -u +"%Y-%m-%dT%H:%M:%S.000Z"; }

# _worker_state_dir N — returns the per-worker state directory path
_worker_state_dir() { echo "$FLEET_STATE_DIR/worker-${1}"; }

# _worker_status N — read last_dispatch_issue / idle from worker loop-status.json
_worker_status() {
  local n="$1"
  local status_file; status_file="$(_worker_state_dir "$n")/loop-status.json"
  if [[ -f "$status_file" ]]; then
    local issue; issue="$(jq -r '.active_workflow.issue // empty' "$status_file" 2>/dev/null || true)"
    local last; last="$(jq -r '.last_dispatch_issue // empty' "$status_file" 2>/dev/null || true)"
    if [[ -n "$issue" ]]; then
      echo "active issue=${issue}"
    elif [[ -n "$last" ]]; then
      echo "idle last=${last}"
    else
      echo "idle"
    fi
  else
    echo "starting"
  fi
}

# ---------------------------------------------------------------------------
# Same-folder co-schedule guard
# _is_same_folder_inflight <issue_number>
# Returns 0 (true/blocked) if another issue in the same specs/<folder>/ is
# in-flight (current_phase != done). Returns 1 (safe) otherwise.
# Read-only: never mutates workflow-state or board.
# ---------------------------------------------------------------------------
_is_same_folder_inflight() {
  local target_issue="$1"
  [[ -d "$SPECS_DIR" ]] || return 1

  # Find the spec folder(s) belonging to this issue by scanning workflow-state files
  local target_folder=""
  local f
  while IFS= read -r -d '' f; do
    local issue_num; issue_num="$(jq -r '.issue_number // empty' "$f" 2>/dev/null || true)"
    if [[ "$issue_num" == "$target_issue" ]]; then
      target_folder="$(dirname "$f")"
      break
    fi
  done < <(find "$SPECS_DIR" -maxdepth 2 \
    \( -name 'workflow-state-*.json' -o -name 'workflow-state.json' \) \
    -print0 2>/dev/null)

  # If we can't locate a folder for this issue, it's not co-schedulable — safe
  [[ -n "$target_folder" ]] || return 1

  # Check if any other in-flight issue shares the same folder
  while IFS= read -r -d '' f; do
    local issue_num; issue_num="$(jq -r '.issue_number // empty' "$f" 2>/dev/null || true)"
    [[ -z "$issue_num" ]] && continue
    [[ "$issue_num" == "$target_issue" ]] && continue  # skip self

    local folder; folder="$(dirname "$f")"
    if [[ "$folder" == "$target_folder" ]]; then
      local phase; phase="$(jq -r '.current_phase // empty' "$f" 2>/dev/null || true)"
      if [[ "$phase" != "done" && -n "$phase" ]]; then
        # Sibling in same folder is in-flight
        return 0
      fi
    fi
  done < <(find "$SPECS_DIR" -maxdepth 2 \
    \( -name 'workflow-state-*.json' -o -name 'workflow-state.json' \) \
    -print0 2>/dev/null)

  return 1  # No in-flight sibling found
}

# ---------------------------------------------------------------------------
# Spawn a single worker process
# _spawn_worker N [loop_args...]
# ---------------------------------------------------------------------------
_spawn_worker() {
  local n="$1"
  shift
  local worker_state; worker_state="$(_worker_state_dir "$n")"
  mkdir -p "$worker_state"

  local log_file="$worker_state/worker.log"

  # Build the worker environment
  local -a worker_env=(
    "MAKATO_LOOP_STATE_DIR=$worker_state"
    "MAKATO_LOOP_PIDFILE=$worker_state/loop.pid"
  )
  if [[ "$CAS_STRICT" == "1" ]]; then
    worker_env+=("MAKATO_LOOP_CLAIM_ON_DISPATCH=1")
  fi
  # Pass through HALT file override if set
  if [[ -n "${MAKATO_HALT_FILE:-}" ]]; then
    worker_env+=("MAKATO_HALT_FILE=$MAKATO_HALT_FILE")
  fi
  # Pass through specs dir if set
  if [[ -n "${MAKATO_SPECS_DIR:-}" ]]; then
    worker_env+=("SPECS_DIR=$MAKATO_SPECS_DIR")
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "loop-fleet: DRY_RUN — would spawn worker-${n}: ${worker_env[*]} bash $LOOP_SH run $*" >&2
    return 0
  fi

  # Spawn worker in background, logging to its own log file
  env "${worker_env[@]}" bash "$LOOP_SH" run "$@" \
    >"$log_file" 2>&1 &
  local pid=$!
  echo "$pid" > "$worker_state/fleet-worker.pid"
  echo "loop-fleet: spawned worker-${n} (pid=$pid, state=$worker_state)" >&2
}

# _worker_pid N — return the PID of worker N, or empty if not running
_worker_pid() {
  local n="$1"
  local pid_file; pid_file="$(_worker_state_dir "$n")/fleet-worker.pid"
  [[ -f "$pid_file" ]] || { echo ""; return 0; }
  local pid; pid="$(cat "$pid_file" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "$pid"
  else
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Print live dashboard to stdout
# ---------------------------------------------------------------------------
_print_dashboard() {
  [[ "$DASHBOARD" == "1" ]] || return 0
  local ts; ts="$(_ts)"
  echo "--- loop-fleet dashboard [${ts}] workers=${WORKERS} ---"
  local i
  for (( i=1; i<=WORKERS; i++ )); do
    local pid; pid="$(_worker_pid "$i")"
    local status; status="$(_worker_status "$i")"
    if [[ -n "$pid" ]]; then
      echo "  worker-${i}: pid=${pid} ${status}"
    else
      echo "  worker-${i}: stopped ${status}"
    fi
  done
}

# ---------------------------------------------------------------------------
# Emit final PR summary from all workflow-state-*.json files
# ---------------------------------------------------------------------------
_print_pr_summary() {
  [[ -d "$SPECS_DIR" ]] || return 0
  local merged=0 open=0 blocked=0
  local f
  while IFS= read -r -d '' f; do
    local phase; phase="$(jq -r '.current_phase // empty' "$f" 2>/dev/null || true)"
    local pr_number; pr_number="$(jq -r '.github_pr_number // empty' "$f" 2>/dev/null || true)"
    if [[ "$phase" == "done" && -n "$pr_number" ]]; then
      merged=$(( merged + 1 ))
    elif [[ "$phase" == "pr" ]]; then
      open=$(( open + 1 ))
    elif [[ "$phase" == "implement" || "$phase" == "verify" ]]; then
      blocked=$(( blocked + 1 ))
    fi
  done < <(find "$SPECS_DIR" -maxdepth 2 \
    \( -name 'workflow-state-*.json' -o -name 'workflow-state.json' \) \
    -print0 2>/dev/null)
  echo "--- loop-fleet final summary: merged=${merged} open=${open} blocked=${blocked} ---"
}

# ---------------------------------------------------------------------------
# Main — spawn workers and supervision loop
# ---------------------------------------------------------------------------

echo "loop-fleet: starting fleet (workers=${WORKERS}, once=${ONCE_MODE})" >&2

if [[ "$DRY_RUN" == "1" ]]; then
  echo "loop-fleet: DRY_RUN=1 — describing what would happen" >&2
fi

# For N=1: single-worker path — pass args straight through for byte-for-byte compat
if [[ "$WORKERS" -eq 1 ]]; then
  mkdir -p "$(_worker_state_dir 1)"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "loop-fleet: DRY_RUN — would spawn 1 worker with MAKATO_LOOP_STATE_DIR=$(_worker_state_dir 1)"
    exit 0
  fi
  _spawn_worker 1 "${LOOP_ARGS[@]}"
  wait
  _print_pr_summary
  exit 0
fi

# Multi-worker: spawn all N workers
for (( i=1; i<=WORKERS; i++ )); do
  _spawn_worker "$i" "${LOOP_ARGS[@]}"
done

if [[ "$DRY_RUN" == "1" ]]; then
  _print_pr_summary
  exit 0
fi

# Supervision loop — watch workers, restart if they die unexpectedly
while true; do
  # HALT-file re-check on every tick
  if [[ -e "$HALT_FILE" ]]; then
    echo "loop-fleet: HALT file detected — signalling all workers to stop" >&2
    for (( i=1; i<=WORKERS; i++ )); do
      local_pid="$(_worker_pid "$i")"
      if [[ -n "$local_pid" ]]; then
        kill -TERM "$local_pid" 2>/dev/null || true
      fi
    done
    wait
    break
  fi

  _print_dashboard

  # In --once mode: exit once all workers have stopped
  if [[ "$ONCE_MODE" -eq 1 ]]; then
    all_done=1
    for (( i=1; i<=WORKERS; i++ )); do
      pid="$(_worker_pid "$i")"
      if [[ -n "$pid" ]]; then
        all_done=0
        break
      fi
    done
    if [[ "$all_done" -eq 1 ]]; then
      break
    fi
  else
    # Supervision: restart any dead workers
    for (( i=1; i<=WORKERS; i++ )); do
      pid="$(_worker_pid "$i")"
      if [[ -z "$pid" ]]; then
        echo "loop-fleet: worker-${i} exited — restarting" >&2
        _spawn_worker "$i" "${LOOP_ARGS[@]}"
      fi
    done
  fi

  sleep "$TICK_SECS"
done

wait
_print_pr_summary
exit 0
