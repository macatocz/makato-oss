#!/usr/bin/env bash
# loop-supervisor.sh — external supervisor that restarts a dead loop.sh.
#
# This is the OUTERMOST safety net for the autonomous loop. It is deliberately
# shallow: it reads only loop-status.json and the run-mutex pidfile — no loop
# internals. The existing run-mutex in loop.sh makes a restart safe even when
# the loop is actually alive (it refuses the second start with exit 3).
#
# Usage:
#   plugins/makato-orchestrate/scripts/loop-supervisor.sh
#
# Environment overrides:
#   MAKATO_LOOP_STATE_DIR     State directory (default: REPO_ROOT/.claude/state)
#   MAKATO_LOOP_PIDFILE       Pidfile path override (default: STATE_DIR/loop.pid)
#   MAKATO_HALT_FILE          HALT-file path (default: ~/.claude/HALT)
#   SUPERVISOR_STALE_SECS     Staleness threshold in seconds (default: 600)
#   MAKATO_REPO_ROOT          Repository root (default: derived from script location)
#   MAKATO_LOOP_SCRIPT        Path to loop.sh (default: resolved from REPO_ROOT)
#   MAKATO_SUPERVISOR_AUDIT   Supervisor audit log (default: STATE_DIR/supervisor-audit.jsonl)
#   MAKATO_SUPERVISOR_DRY_RUN Set to 1 to skip the actual restart (dry-run / test mode)
#   MAKATO_SUPERVISOR_GH_CMD  Override the gh command used for autonomous:halt label check
#
# Audit log:
#   Appends one JSON line per supervisor tick to supervisor-audit.jsonl:
#   {"ts":"<ISO8601>","action":"<no_action|restart|halt_skip|reconcile_abort>","reason":"<why>",
#    "pid_status":"<alive|dead|missing>","stale_secs":<int-or-null>}
#
#   reconcile-before-resume.sh appends its own entries with the reconcile_result / poison_pill_detected
#   action keys. See scripts/reconcile-before-resume.sh for that schema.
#
# Environment overrides:
#   MAKATO_LOOP_STATE_DIR     State directory (default: REPO_ROOT/.claude/state)
#   MAKATO_LOOP_PIDFILE       Pidfile path override (default: STATE_DIR/loop.pid)
#   MAKATO_HALT_FILE          HALT-file path (default: ~/.claude/HALT)
#   SUPERVISOR_STALE_SECS     Staleness threshold in seconds (default: 600)
#   MAKATO_REPO_ROOT          Repository root (default: derived from script location)
#   MAKATO_LOOP_SCRIPT        Path to loop.sh (default: resolved from REPO_ROOT)
#   MAKATO_RECONCILE_SCRIPT   Path to reconcile-before-resume.sh (default: resolved from REPO_ROOT)
#                             Set to a stub path in tests to inject a canned reconcile exit code.
#   MAKATO_SUPERVISOR_AUDIT   Supervisor audit log (default: STATE_DIR/supervisor-audit.jsonl)
#   MAKATO_SUPERVISOR_DRY_RUN Set to 1 to skip the actual restart (dry-run / test mode)
#   MAKATO_SUPERVISOR_GH_CMD  Override the gh command used for autonomous:halt label check

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Resolve REPO_ROOT — walk up from script directory to find the repo root.
# ---------------------------------------------------------------------------
if [[ -n "${MAKATO_REPO_ROOT:-}" ]]; then
  REPO_ROOT="$MAKATO_REPO_ROOT"
else
  # script lives at plugins/makato-orchestrate/scripts/ — four levels up is root
  REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi

if [[ ! -d "$REPO_ROOT" ]]; then
  echo "loop-supervisor: ERROR — REPO_ROOT '$REPO_ROOT' does not exist" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
STATE_DIR="${MAKATO_LOOP_STATE_DIR:-$REPO_ROOT/.claude/state}"
PIDFILE="${MAKATO_LOOP_PIDFILE:-$STATE_DIR/loop.pid}"
STATUS_FILE="$STATE_DIR/loop-status.json"
# HALT_FILE is intentionally operator-global (HALT-000) — the documented
# exception to issue #6 path re-homing. Do NOT default it under STATE_DIR.
HALT_FILE="${MAKATO_HALT_FILE:-$HOME/.claude/HALT}"
STALE_SECS="${SUPERVISOR_STALE_SECS:-600}"
AUDIT_LOG="${MAKATO_SUPERVISOR_AUDIT:-$STATE_DIR/supervisor-audit.jsonl}"
DRY_RUN="${MAKATO_SUPERVISOR_DRY_RUN:-0}"
GH_CMD="${MAKATO_SUPERVISOR_GH_CMD:-gh}"

LOOP_SCRIPT="${MAKATO_LOOP_SCRIPT:-$REPO_ROOT/plugins/makato-orchestrate/scripts/loop.sh}"
RECONCILE_SCRIPT="${MAKATO_RECONCILE_SCRIPT:-$REPO_ROOT/plugins/makato-orchestrate/scripts/reconcile-before-resume.sh}"

if [[ ! -f "$LOOP_SCRIPT" ]]; then
  echo "loop-supervisor: ERROR — loop.sh not found at '$LOOP_SCRIPT'" >&2
  exit 1
fi

mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_ts() { date -u +"%Y-%m-%dT%H:%M:%S.000Z"; }

_append_audit() {
  local action="$1" reason="$2" pid_status="$3" stale_secs="$4"
  local ts; ts="$(_ts)"
  local stale_json
  if [[ "$stale_secs" == "null" ]]; then
    stale_json="null"
  else
    stale_json="$stale_secs"
  fi
  printf '{"ts":"%s","action":"%s","reason":"%s","pid_status":"%s","stale_secs":%s}\n' \
    "$ts" "$action" "$reason" "$pid_status" "$stale_json" \
    >> "$AUDIT_LOG"
}

# ---------------------------------------------------------------------------
# Step 1 — Kill-switch guard: HALT file or autonomous:halt label
# ---------------------------------------------------------------------------
if [[ -e "$HALT_FILE" ]]; then
  echo "loop-supervisor: HALT file present at '$HALT_FILE' — skipping restart" >&2
  _append_audit "halt_skip" "halt_file_present" "unchecked" "null"
  exit 0
fi

# Check autonomous:halt label on the repo (best-effort; skip on gh failure)
REPO_SLUG=""
if [[ -f "$REPO_ROOT/.claude/config.json" ]]; then
  REPO_SLUG="$(jq -r '(.github_project.owner // "") + "/" + (.github_project.repo // "")' \
    "$REPO_ROOT/.claude/config.json" 2>/dev/null || true)"
fi

if [[ -n "$REPO_SLUG" && "$REPO_SLUG" != "/" ]]; then
  if "$GH_CMD" label list --repo "$REPO_SLUG" --json name \
    --jq '[.[].name] | contains(["autonomous:halt"])' 2>/dev/null | grep -q "^true$"; then
    echo "loop-supervisor: 'autonomous:halt' label present on $REPO_SLUG — skipping restart" >&2
    _append_audit "halt_skip" "autonomous_halt_label" "unchecked" "null"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Step 2 — Liveness check: read pidfile and probe the PID
# ---------------------------------------------------------------------------
PID_STATUS="missing"
PID=""

if [[ -f "$PIDFILE" ]]; then
  PID="$(cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    PID_STATUS="alive"
  else
    PID_STATUS="dead"
  fi
fi

# ---------------------------------------------------------------------------
# Step 3 — If alive, check for staleness (only when board has queued items)
# ---------------------------------------------------------------------------
if [[ "$PID_STATUS" == "alive" ]]; then
  # Loop process is running. Check if it is stale (stuck with work queued).
  LAST_DISPATCH_AT=""
  QUEUE_DEPTH=0

  if [[ -f "$STATUS_FILE" ]]; then
    LAST_DISPATCH_AT="$(jq -r '.last_dispatch_at // empty' "$STATUS_FILE" 2>/dev/null || true)"
    QUEUE_DEPTH="$(jq -r '.queue_depth // 0' "$STATUS_FILE" 2>/dev/null || echo 0)"
  fi

  # Idle with empty board is healthy — no restart needed regardless of age.
  if [[ "${QUEUE_DEPTH:-0}" -eq 0 ]]; then
    echo "loop-supervisor: loop alive (pid=$PID), board empty — no action" >&2
    _append_audit "no_action" "loop_alive_board_empty" "alive" "null"
    exit 0
  fi

  # Mid-dispatch guard: active_workflow takes precedence over last_dispatch_at age.
  # When a dispatch is in flight and not stalled, the loop is healthy regardless of
  # how old last_dispatch_at is (it is written once at dispatch start, never refreshed).
  ACTIVE_WF_ISSUE="$(jq -r '.active_workflow.issue // empty' "$STATUS_FILE" 2>/dev/null || true)"
  ACTIVE_WF_STALLED="$(jq -r '.active_workflow.stalled // false' "$STATUS_FILE" 2>/dev/null || true)"

  if [[ -n "$ACTIVE_WF_ISSUE" && "$ACTIVE_WF_STALLED" != "true" ]]; then
    echo "loop-supervisor: loop alive (pid=$PID), mid-dispatch (issue=${ACTIVE_WF_ISSUE}, stalled=false) — no action" >&2
    _append_audit "no_action" "loop_alive_mid_dispatch" "alive" "null"
    exit 0
  fi

  # Board has queued items — check staleness.
  STALE_ELAPSED="null"
  if [[ -n "$LAST_DISPATCH_AT" ]]; then
    NOW_EPOCH="$(date -u +%s 2>/dev/null || python3 -c 'import time; print(int(time.time()))')"
    DISPATCH_EPOCH=""
    # Parse ISO8601 timestamp portably (macOS date -j vs GNU date -d)
    if date -j -f "%Y-%m-%dT%H:%M:%S" "${LAST_DISPATCH_AT%.*}" +%s >/dev/null 2>&1; then
      DISPATCH_EPOCH="$(date -j -f "%Y-%m-%dT%H:%M:%S" "${LAST_DISPATCH_AT%.*}" +%s 2>/dev/null || true)"
    elif date -d "$LAST_DISPATCH_AT" +%s >/dev/null 2>&1; then
      DISPATCH_EPOCH="$(date -d "$LAST_DISPATCH_AT" +%s 2>/dev/null || true)"
    else
      DISPATCH_EPOCH="$(python3 -c "
import sys
from datetime import datetime, timezone
ts = '$LAST_DISPATCH_AT'.rstrip('Z').split('.')[0]
dt = datetime.strptime(ts, '%Y-%m-%dT%H:%M:%S').replace(tzinfo=timezone.utc)
print(int(dt.timestamp()))
" 2>/dev/null || true)"
    fi

    if [[ -n "$DISPATCH_EPOCH" && -n "$NOW_EPOCH" ]]; then
      STALE_ELAPSED=$(( NOW_EPOCH - DISPATCH_EPOCH ))
    fi
  fi

  if [[ "$STALE_ELAPSED" != "null" && "$STALE_ELAPSED" -lt "$STALE_SECS" ]]; then
    echo "loop-supervisor: loop alive (pid=$PID), healthy (age=${STALE_ELAPSED}s < threshold=${STALE_SECS}s) — no action" >&2
    _append_audit "no_action" "loop_alive_healthy" "alive" "$STALE_ELAPSED"
    exit 0
  fi

  # Stale but alive — restart anyway (run-mutex in loop.sh will refuse if truly alive)
  REASON="loop_stale_with_queued_items"
  if [[ "$STALE_ELAPSED" == "null" ]]; then
    REASON="loop_stale_no_dispatch_timestamp"
  fi
  echo "loop-supervisor: loop appears stale (pid=$PID age=${STALE_ELAPSED}s >= ${STALE_SECS}s, queue_depth=${QUEUE_DEPTH}) — restarting" >&2
  _do_restart=1
  _restart_reason="$REASON"
else
  # Dead or missing pidfile — check if board has queued items before restarting.
  QUEUE_DEPTH=0
  if [[ -f "$STATUS_FILE" ]]; then
    QUEUE_DEPTH="$(jq -r '.queue_depth // 0' "$STATUS_FILE" 2>/dev/null || echo 0)"
  fi

  if [[ "${QUEUE_DEPTH:-0}" -eq 0 ]]; then
    echo "loop-supervisor: loop dead/absent (pid_status=$PID_STATUS), board empty — no action" >&2
    _append_audit "no_action" "loop_dead_board_empty" "$PID_STATUS" "null"
    exit 0
  fi

  echo "loop-supervisor: loop dead/absent (pid_status=$PID_STATUS, queue_depth=${QUEUE_DEPTH}) — restarting" >&2
  _do_restart=1
  _restart_reason="loop_dead_with_queued_items"
fi

# ---------------------------------------------------------------------------
# Step 4 — Restart: nohup loop.sh run (run-mutex makes it safe if alive)
# ---------------------------------------------------------------------------
if [[ "${_do_restart:-0}" == "1" ]]; then
  # Compute stale_secs for the audit entry
  AUDIT_STALE="null"
  if [[ -n "${STALE_ELAPSED:-}" && "$STALE_ELAPSED" != "null" ]]; then
    AUDIT_STALE="$STALE_ELAPSED"
  fi

  # ---------------------------------------------------------------------------
  # Reconcile-before-resume: run the D7 decision table before restarting.
  # Exit 0 (CI green) or 2 (CI failed/timeout) → proceed with restart.
  # Exit 1 (poison-pill: no open PR) → board-reset already done; skip restart.
  # Runs before the DRY_RUN check so the abort path is exercisable in tests.
  # ---------------------------------------------------------------------------
  if [[ -f "$RECONCILE_SCRIPT" ]]; then
    RECONCILE_REPO=""
    if [[ -n "${REPO_SLUG:-}" && "$REPO_SLUG" != "/" ]]; then
      RECONCILE_REPO="$REPO_SLUG"
    fi

    # Locate the active workflow-state file (most recently modified)
    WF_STATE_PATH=""
    if command -v find >/dev/null 2>&1; then
      WF_STATE_PATH="$(find "$STATE_DIR/.." -maxdepth 4 \
        -name "workflow-state-*.json" -newer "$PIDFILE" \
        -print 2>/dev/null | head -1 || true)"
      # Fallback: any workflow-state that exists
      if [[ -z "$WF_STATE_PATH" ]]; then
        WF_STATE_PATH="$(find "$STATE_DIR/.." -maxdepth 4 \
          -name "workflow-state-*.json" \
          -print 2>/dev/null | head -1 || true)"
      fi
    fi

    RECONCILE_ARGS=()
    [[ -n "$WF_STATE_PATH" ]] && RECONCILE_ARGS+=(--workflow-state "$WF_STATE_PATH")
    [[ -n "$RECONCILE_REPO" ]] && RECONCILE_ARGS+=(--repo "$RECONCILE_REPO")

    RECONCILE_EXIT=0
    MAKATO_LOOP_STATE_DIR="$STATE_DIR" \
    MAKATO_SUPERVISOR_AUDIT="$AUDIT_LOG" \
      bash "$RECONCILE_SCRIPT" "${RECONCILE_ARGS[@]}" 2>>"$STATE_DIR/supervisor.log" || RECONCILE_EXIT=$?

    if [[ "$RECONCILE_EXIT" -eq 1 ]]; then
      echo "loop-supervisor: reconcile-before-resume exited 1 (poison-pill board-reset) — skipping restart" >&2
      _append_audit "reconcile_abort" "reconcile_poison_pill" "$PID_STATUS" "$AUDIT_STALE"
      exit 0
    fi
    if [[ "$RECONCILE_EXIT" -eq 4 ]]; then
      echo "loop-supervisor: reconcile-before-resume blocked recovery (exit 4) — skipping restart" >&2
      _append_audit "reconcile_abort" "review_runtime_blocked" "$PID_STATUS" "$AUDIT_STALE"
      exit 4
    fi
    # Exit 0 (CI green) or 2 (CI failed) → fall through to restart
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "loop-supervisor: DRY_RUN=1 — would restart loop.sh run (skipping)" >&2
    _append_audit "restart" "dry_run:${_restart_reason}" "$PID_STATUS" "$AUDIT_STALE"
    exit 0
  fi

  # Resolve loop run arguments from REPO_ROOT
  nohup bash "$LOOP_SCRIPT" run \
    >"$STATE_DIR/supervisor-restart.log" 2>&1 &
  SPAWNED_PID=$!
  echo "loop-supervisor: restarted loop.sh (spawned pid=$SPAWNED_PID)" >&2
  _append_audit "restart" "$_restart_reason" "$PID_STATUS" "$AUDIT_STALE"
fi

exit 0
