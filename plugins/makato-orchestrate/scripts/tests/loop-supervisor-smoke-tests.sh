#!/usr/bin/env bash
# Smoke tests for scripts/loop-supervisor.sh — the external supervisor
# (issue #532). Fully offline: no real loop.sh, no gh invocations.
#
# Usage:
#   plugins/makato-orchestrate/scripts/tests/loop-supervisor-smoke-tests.sh
#
# Scenarios:
#   T1: live loop with recent dispatch + queued items → no action
#   T2: dead pidfile + queued items → restart (dry-run captures invocation)
#   T3: HALT file present → halt_skip, no restart
#   T4: stale last_dispatch_at but board empty → no action
#   (Each scenario asserts the correct `action` in supervisor-audit.jsonl)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISOR="$SCRIPT_DIR/../loop-supervisor.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

pass() { PASS=$((PASS + 1)); echo "  ok  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); echo "  FAIL $1 — $2"; }

# Create a fresh sandbox for each test.
new_sandbox() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/state" "$d/specs"
  # Create a stub loop.sh that the supervisor can point to (must exist).
  cat >"$d/loop.sh" <<'LOOPSTUB'
#!/usr/bin/env bash
# Stub loop.sh — records invocation for supervisor smoke tests.
echo "loop-stub: invoked with args: $*" >&2
echo "loop-stub: invoked with args: $*" >> "$(dirname "$0")/stub-calls.log"
LOOPSTUB
  chmod +x "$d/loop.sh"
  printf '%s\n' "$d"
}

# Extract the `action` field from the last line of supervisor-audit.jsonl.
last_action() {
  local audit_file="$1"
  jq -r '.action' "$audit_file" 2>/dev/null | tail -1
}

# Run supervisor with a sandbox.
run_supervisor() {
  local sb="$1"; shift
  MAKATO_REPO_ROOT="$sb" \
  MAKATO_LOOP_STATE_DIR="$sb/state" \
  MAKATO_LOOP_PIDFILE="$sb/state/loop.pid" \
  MAKATO_HALT_FILE="$sb/HALT" \
  MAKATO_LOOP_SCRIPT="$sb/loop.sh" \
  MAKATO_SUPERVISOR_AUDIT="$sb/state/supervisor-audit.jsonl" \
  MAKATO_SUPERVISOR_GH_CMD="true" \
  SUPERVISOR_STALE_SECS="${SUPERVISOR_STALE_SECS:-600}" \
  "$@" \
    bash "$SUPERVISOR"
}

# ---------------------------------------------------------------------------
echo "T1: live loop with recent dispatch + queued items → no_action"
{
  sb="$(new_sandbox)"
  # Write current PID as pidfile (= alive)
  echo "$$" >"$sb/state/loop.pid"
  # Fresh dispatch timestamp (< 600s ago), board non-empty
  NOW="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"
  printf '{"queue_depth":2,"last_dispatch_at":"%s"}\n' "$NOW" >"$sb/state/loop-status.json"

  run_supervisor "$sb" >/dev/null 2>&1

  action="$(last_action "$sb/state/supervisor-audit.jsonl")"
  if [[ "$action" == "no_action" ]]; then
    pass "T1"
  else
    fail "T1" "expected action=no_action, got '$action'"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
echo "T2: dead pidfile + queued items → restart"
{
  sb="$(new_sandbox)"
  # Non-existent PID (= dead)
  echo "99999999" >"$sb/state/loop.pid"
  # Old dispatch timestamp, board non-empty
  printf '{"queue_depth":3,"last_dispatch_at":"2020-01-01T00:00:00.000Z"}\n' \
    >"$sb/state/loop-status.json"

  # DRY_RUN=1 captures the restart decision without spawning a real loop.
  MAKATO_SUPERVISOR_DRY_RUN=1 run_supervisor "$sb" >/dev/null 2>&1

  action="$(last_action "$sb/state/supervisor-audit.jsonl")"
  if [[ "$action" == "restart" ]]; then
    pass "T2"
  else
    fail "T2" "expected action=restart, got '$action'"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
echo "T3: HALT file present → halt_skip, no restart"
{
  sb="$(new_sandbox)"
  # Dead loop + queued items — would normally trigger restart.
  echo "99999999" >"$sb/state/loop.pid"
  printf '{"queue_depth":5,"last_dispatch_at":"2020-01-01T00:00:00.000Z"}\n' \
    >"$sb/state/loop-status.json"
  # But HALT file exists.
  touch "$sb/HALT"

  run_supervisor "$sb" >/dev/null 2>&1

  action="$(last_action "$sb/state/supervisor-audit.jsonl")"
  if [[ "$action" == "halt_skip" ]]; then
    pass "T3"
  else
    fail "T3" "expected action=halt_skip, got '$action'"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
echo "T4: stale last_dispatch_at but board empty → no_action"
{
  sb="$(new_sandbox)"
  # Write current PID (alive), but board is empty.
  echo "$$" >"$sb/state/loop.pid"
  # Very old timestamp, but queue_depth=0 — idle loop, nothing queued.
  printf '{"queue_depth":0,"last_dispatch_at":"2020-01-01T00:00:00.000Z"}\n' \
    >"$sb/state/loop-status.json"

  run_supervisor "$sb" >/dev/null 2>&1

  action="$(last_action "$sb/state/supervisor-audit.jsonl")"
  if [[ "$action" == "no_action" ]]; then
    pass "T4"
  else
    fail "T4" "expected action=no_action, got '$action'"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# T5: dead pidfile, board empty → no_action (loop is gone but nothing to do)
# ---------------------------------------------------------------------------
echo "T5: dead pidfile + board empty → no_action"
{
  sb="$(new_sandbox)"
  echo "99999999" >"$sb/state/loop.pid"
  printf '{"queue_depth":0}\n' >"$sb/state/loop-status.json"

  run_supervisor "$sb" >/dev/null 2>&1

  action="$(last_action "$sb/state/supervisor-audit.jsonl")"
  if [[ "$action" == "no_action" ]]; then
    pass "T5"
  else
    fail "T5" "expected action=no_action, got '$action'"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# T6: missing pidfile + queued items → restart
# ---------------------------------------------------------------------------
echo "T6: missing pidfile + queued items → restart"
{
  sb="$(new_sandbox)"
  # No pidfile at all
  printf '{"queue_depth":1,"last_dispatch_at":"2020-01-01T00:00:00.000Z"}\n' \
    >"$sb/state/loop-status.json"

  MAKATO_SUPERVISOR_DRY_RUN=1 run_supervisor "$sb" >/dev/null 2>&1

  action="$(last_action "$sb/state/supervisor-audit.jsonl")"
  if [[ "$action" == "restart" ]]; then
    pass "T6"
  else
    fail "T6" "expected action=restart, got '$action'"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# T7: alive + stale (old dispatch) + queued items → restart
# ---------------------------------------------------------------------------
echo "T7: alive + stale dispatch + queued items → restart"
{
  sb="$(new_sandbox)"
  echo "$$" >"$sb/state/loop.pid"
  # Very old dispatch timestamp with items queued → stale, and stalled=true so guard doesn't fire
  printf '{"queue_depth":2,"last_dispatch_at":"2020-01-01T00:00:00.000Z","active_workflow":{"issue":42,"stalled":true}}\n' \
    >"$sb/state/loop-status.json"

  MAKATO_SUPERVISOR_DRY_RUN=1 run_supervisor "$sb" >/dev/null 2>&1

  action="$(last_action "$sb/state/supervisor-audit.jsonl")"
  if [[ "$action" == "restart" ]]; then
    pass "T7"
  else
    fail "T7" "expected action=restart, got '$action'"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# T8: alive + active_workflow.stalled=false + stale dispatch + queued items → no_action
# ---------------------------------------------------------------------------
echo "T8: alive + active_workflow.stalled=false + stale dispatch + queued items → no_action"
{
  sb="$(new_sandbox)"
  echo "$$" >"$sb/state/loop.pid"
  # active_workflow present and not stalled — mid-dispatch guard fires
  printf '{"queue_depth":2,"last_dispatch_at":"2020-01-01T00:00:00.000Z","active_workflow":{"issue":42,"stalled":false}}\n' \
    >"$sb/state/loop-status.json"

  run_supervisor "$sb" >/dev/null 2>&1

  action="$(last_action "$sb/state/supervisor-audit.jsonl")"
  if [[ "$action" == "no_action" ]]; then
    pass "T8"
  else
    fail "T8" "expected action=no_action, got '$action'"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# T9: alive + active_workflow.stalled=true + stale dispatch + queued items → restart
# ---------------------------------------------------------------------------
echo "T9: alive + active_workflow.stalled=true + stale dispatch + queued items → restart"
{
  sb="$(new_sandbox)"
  echo "$$" >"$sb/state/loop.pid"
  # active_workflow present but stalled — mid-dispatch guard does NOT fire
  printf '{"queue_depth":2,"last_dispatch_at":"2020-01-01T00:00:00.000Z","active_workflow":{"issue":42,"stalled":true}}\n' \
    >"$sb/state/loop-status.json"

  MAKATO_SUPERVISOR_DRY_RUN=1 run_supervisor "$sb" >/dev/null 2>&1

  action="$(last_action "$sb/state/supervisor-audit.jsonl")"
  if [[ "$action" == "restart" ]]; then
    pass "T9"
  else
    fail "T9" "expected action=restart, got '$action'"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# T10: HALT_FILE default re-homed to STATE_DIR (issue #6 / AC-2)
# Sources the path-init block from loop.sh with MAKATO_LOOP_STATE_DIR set to a
# temp dir and MAKATO_HALT_FILE unset. Asserts HALT_FILE does NOT contain $HOME.
# RED test: fails when HALT_FILE still defaults to $HOME/.claude/HALT.
# ---------------------------------------------------------------------------
echo "T10: HALT_FILE default re-homed to STATE_DIR, not \$HOME"
{
  sb="$(new_sandbox)"
  LOOP_SH="$SCRIPT_DIR/../loop.sh"

  # Extract the path-init block (lines between "Runtime-derived paths" and the
  # next "# ---" comment) and source it with a controlled env, explicitly
  # unset MAKATO_HALT_FILE to exercise the default-path branch.
  path_init_result=$(
    cd "$SCRIPT_DIR/../../../.."   # repo root for git rev-parse
    unset MAKATO_HALT_FILE
    export MAKATO_LOOP_STATE_DIR="$sb/state"
    eval "$(awk '/Runtime-derived paths/{found=1;next} found && /^# ---/{exit} found{print}' "$LOOP_SH")"
    echo "$HALT_FILE"
  )

  if [[ "$path_init_result" != *"$HOME"* ]]; then
    pass "T10 HALT_FILE default does not contain \$HOME (re-homed to STATE_DIR)"
  else
    fail "T10" "HALT_FILE still defaults to HOME path: $path_init_result"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "All $PASS tests passed."
else
  echo "$PASS passed, $FAIL FAILED: ${FAILED_TESTS[*]}"
  exit 1
fi
