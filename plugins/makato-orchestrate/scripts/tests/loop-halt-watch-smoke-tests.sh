#!/usr/bin/env bash
# Smoke tests for scripts/loop-halt-watch.sh — the operator-side macOS HALT
# notifier. Fully offline: the notify() path is stubbed via MAKATO_WATCH_NOTIFY_CMD
# so no real notification fires and no `terminal-notifier`/`osascript` is invoked.
#
# Usage:
#   plugins/makato-orchestrate/scripts/tests/loop-halt-watch-smoke-tests.sh
#
# Scenarios:
#   T1: baseline poll against a live loop with clean state → no notification
#   T2: HALT file appears at runtime → fires "Loop HALT"
#   T3: last_halt_at advances at runtime (clean HALT exit) → fires "Loop HALT"
#   T4: loop PID dies while queue_depth > 0 → fires "Loop spadl"
#   T5: pre-existing watchdog kill at startup → baseline, no notification
#   T5b: last_watchdog_kill changes at runtime → fires "Watchdog kill"
#   T6: pre-existing last_halt_at at startup → baseline, no notification

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER="$SCRIPT_DIR/../loop-halt-watch.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

pass() { PASS=$((PASS + 1)); echo "  ok  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); echo "  FAIL $1 — $2"; }

# Fresh sandbox: a fake repo root with .claude/state.
new_sandbox() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/.claude/state"
  echo "$d"
}

# Run one baseline+mutation cycle of the watcher and capture notifications.
# Args: <repo> <halt_file> <notify_log>
run_watch_cycle() {
  local repo="$1" halt="$2" notify_log="$3"
  MAKATO_WATCH_ONCE=1 \
  MAKATO_HALT_FILE="$halt" \
  MAKATO_WATCH_NOTIFY_CMD="$notify_log" \
    bash "$WATCHER" "$repo" >/dev/null 2>&1 || true
}

# ---- T1: baseline poll, clean state → no notification -------------------------
t1() {
  local d; d="$(new_sandbox)"
  echo "$$" > "$d/.claude/state/loop.pid"   # this test process = alive PID
  echo '{"queue_depth":3,"last_halt_at":null,"last_watchdog_kill":null}' \
    > "$d/.claude/state/loop-status.json"
  local nl="$d/notify.log"; : > "$nl"
  run_watch_cycle "$d" "$d/NO_HALT" "$nl"
  if [ ! -s "$nl" ]; then pass "T1 baseline clean → no notification"
  else fail "T1" "unexpected notifications: $(cat "$nl")"; fi
  rm -rf "$d"
}

# ---- T2: HALT file appears AT RUNTIME → fires -------------------------------
# The watcher treats startup state as baseline, so the HALT file must appear
# *after* launch. Run the watcher live (fast interval), touch HALT mid-run.
t2() {
  local d; d="$(new_sandbox)"
  echo "$$" > "$d/.claude/state/loop.pid"
  echo '{"queue_depth":3,"last_halt_at":null,"last_watchdog_kill":null}' \
    > "$d/.claude/state/loop-status.json"
  local nl="$d/notify.log"; : > "$nl"
  local halt="$d/HALT"   # absent at startup → baseline halt_file_seen=0
  MAKATO_WATCH_INTERVAL=1 MAKATO_HALT_FILE="$halt" MAKATO_WATCH_NOTIFY_CMD="$nl" \
    bash "$WATCHER" "$d" >/dev/null 2>&1 &
  local wpid=$!
  sleep 2
  touch "$halt"          # HALT appears at runtime → transition
  sleep 2
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  if grep -qi "HALT" "$nl"; then pass "T2 HALT file appears at runtime → HALT notification"
  else fail "T2" "no HALT notification; log=$(cat "$nl")"; fi
  rm -rf "$d"
}

# ---- T3: last_halt_at advances at runtime (clean HALT exit) → fires ---------
t3() {
  local d; d="$(new_sandbox)"
  echo "$$" > "$d/.claude/state/loop.pid"
  echo '{"queue_depth":3,"last_halt_at":null,"last_watchdog_kill":null}' \
    > "$d/.claude/state/loop-status.json"
  local nl="$d/notify.log"; : > "$nl"
  MAKATO_WATCH_INTERVAL=1 MAKATO_HALT_FILE="$d/NO_HALT" MAKATO_WATCH_NOTIFY_CMD="$nl" \
    bash "$WATCHER" "$d" >/dev/null 2>&1 &
  local wpid=$!
  sleep 2
  echo '{"queue_depth":0,"last_halt_at":"2026-08-06T14:11:00Z","last_watchdog_kill":null}' \
    > "$d/.claude/state/loop-status.json"   # clean HALT exit stamps last_halt_at
  sleep 2
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  if grep -qi "HALT" "$nl"; then pass "T3 last_halt_at advances → HALT notification"
  else fail "T3" "no HALT notification; log=$(cat "$nl")"; fi
  rm -rf "$d"
}

# ---- T4: dead PID + queued work → fires -------------------------------------
t4() {
  local d; d="$(new_sandbox)"
  echo "999999" > "$d/.claude/state/loop.pid"  # nonexistent PID
  echo '{"queue_depth":5,"last_halt_at":null,"last_watchdog_kill":null}' \
    > "$d/.claude/state/loop-status.json"
  local nl="$d/notify.log"; : > "$nl"
  run_watch_cycle "$d" "$d/NO_HALT" "$nl"
  if grep -qi "spadl\|crash\|neběží" "$nl"; then pass "T4 dead PID + queue → crash notification"
  else fail "T4" "no crash notification; log=$(cat "$nl")"; fi
  rm -rf "$d"
}

# ---- T5: watchdog kill present at startup is baseline; must NOT fire ---------
t5_baseline() {
  local d; d="$(new_sandbox)"
  echo "$$" > "$d/.claude/state/loop.pid"
  echo '{"queue_depth":3,"last_halt_at":null,"last_watchdog_kill":{"issue":146,"idle_seconds":3600}}' \
    > "$d/.claude/state/loop-status.json"
  local nl="$d/notify.log"; : > "$nl"
  run_watch_cycle "$d" "$d/NO_HALT" "$nl"
  if [ ! -s "$nl" ]; then pass "T5 pre-existing watchdog kill = baseline → no notification"
  else fail "T5" "baseline watchdog kill wrongly fired: $(cat "$nl")"; fi
  rm -rf "$d"
}

# ---- T5b: last_watchdog_kill changes at runtime → fires ---------------------
t5_runtime() {
  local d; d="$(new_sandbox)"
  echo "$$" > "$d/.claude/state/loop.pid"
  echo '{"queue_depth":3,"last_halt_at":null,"last_watchdog_kill":null}' \
    > "$d/.claude/state/loop-status.json"
  local nl="$d/notify.log"; : > "$nl"
  MAKATO_WATCH_INTERVAL=1 MAKATO_HALT_FILE="$d/NO_HALT" MAKATO_WATCH_NOTIFY_CMD="$nl" \
    bash "$WATCHER" "$d" >/dev/null 2>&1 &
  local wpid=$!
  sleep 2
  echo '{"queue_depth":3,"last_halt_at":null,"last_watchdog_kill":{"issue":452,"idle_seconds":3600}}' \
    > "$d/.claude/state/loop-status.json"   # watchdog kill appears at runtime
  sleep 2
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  if grep -qi "Watchdog" "$nl"; then pass "T5b watchdog kill changes → Watchdog notification"
  else fail "T5b" "no watchdog notification; log=$(cat "$nl")"; fi
  rm -rf "$d"
}

# ---- T6: pre-existing HALT state at startup is baseline → no notification ----
t6() {
  local d; d="$(new_sandbox)"
  echo "$$" > "$d/.claude/state/loop.pid"
  echo '{"queue_depth":0,"last_halt_at":"2026-07-20T19:01:52Z","last_watchdog_kill":null}' \
    > "$d/.claude/state/loop-status.json"
  local nl="$d/notify.log"; : > "$nl"
  run_watch_cycle "$d" "$d/NO_HALT" "$nl"   # no HALT file, last_halt_at is old baseline
  if [ ! -s "$nl" ]; then pass "T6 pre-existing last_halt_at = baseline → no notification"
  else fail "T6" "baseline last_halt_at wrongly fired: $(cat "$nl")"; fi
  rm -rf "$d"
}

echo "== loop-halt-watch smoke tests =="
t1; t2; t3; t4; t5_baseline; t5_runtime; t6

echo ""
echo "Passed: $PASS   Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed tests: %s\n' "${FAILED_TESTS[*]}"
  exit 1
fi
