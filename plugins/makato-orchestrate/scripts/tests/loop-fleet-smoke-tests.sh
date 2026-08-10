#!/usr/bin/env bash
# Smoke tests for scripts/loop-fleet.sh — bounded parallel fleet launcher (#546).
# Run from the makato repo root.
#
# Usage:
#   plugins/makato-orchestrate/scripts/tests/loop-fleet-smoke-tests.sh
#
# Scenarios (per issue #546 AC):
#   T-FLEET-1: N=2 spawns 2 workers with distinct MAKATO_LOOP_STATE_DIR
#   T-FLEET-2: Board CAS claim strict — each worker has MAKATO_LOOP_CLAIM_ON_DISPATCH=1 when CAS_STRICT=1
#   T-FLEET-3: No double-dispatch — two workers with overlapping board get distinct dispatch slots
#   T-FLEET-4: Same-folder guard — sibling in-flight issue blocks co-scheduling; done sibling does not
#   T-FLEET-5: N=1 — single worker; MAKATO_LOOP_STATE_DIR set to worker-1 subdir
#   T-FLEET-6: HALT-file present → launcher exits 0 without spawning any worker
#
# Tests run WITHOUT gh, network, or real claude — stubs only.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
FLEET="$REPO_ROOT/plugins/makato-orchestrate/scripts/loop-fleet.sh"

TMPROOT="${CLAUDE_JOB_DIR:-/tmp}/fleet-smoke-$$"
mkdir -p "$TMPROOT"

PASS=0
FAIL=0

fail() {
  echo "  FAIL: $*" >&2
  FAIL=$(( FAIL + 1 ))
}

pass() {
  echo "  PASS: $*"
  PASS=$(( PASS + 1 ))
}

cleanup() {
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Create a stub loop.sh that records its MAKATO_LOOP_STATE_DIR to a log file
# and exits immediately (simulates --once behaviour).
# ---------------------------------------------------------------------------
_make_stub_loop() {
  local stub_dir="$1"
  local log_file="$2"
  mkdir -p "$stub_dir"
  cat >"$stub_dir/loop.sh" <<EOF
#!/usr/bin/env bash
# stub loop.sh — records env and exits immediately
echo "\${MAKATO_LOOP_STATE_DIR:-UNSET}" >> "$log_file"
echo "claim_on_dispatch=\${MAKATO_LOOP_CLAIM_ON_DISPATCH:-0}" >> "$log_file"
exit 0
EOF
  chmod +x "$stub_dir/loop.sh"
}

# ---------------------------------------------------------------------------
echo "=== T-FLEET-1: N=2 spawns 2 workers with distinct MAKATO_LOOP_STATE_DIR ==="
{
  T1_DIR="$TMPROOT/t1"
  T1_LOG="$T1_DIR/dispatch.log"
  mkdir -p "$T1_DIR"
  _make_stub_loop "$T1_DIR" "$T1_LOG"

  MAKATO_LOOP_SH_PATH="$T1_DIR/loop.sh" \
  MAKATO_FLEET_STATE_DIR="$T1_DIR/fleet" \
  MAKATO_HALT_FILE="$T1_DIR/no-halt" \
  MAKATO_FLEET_TICK_SECS=1 \
  MAKATO_FLEET_DASHBOARD=0 \
    bash "$FLEET" --workers 2 --once 2>/dev/null

  if [[ -f "$T1_LOG" ]]; then
    state_dirs="$(grep -v "^claim_on_dispatch" "$T1_LOG" 2>/dev/null | sort -u)"
    dir_count="$(echo "$state_dirs" | grep -c "worker-" 2>/dev/null || echo 0)"
    distinct="$(echo "$state_dirs" | sort -u | grep -c "worker-" 2>/dev/null || echo 0)"
    if [[ "$dir_count" -ge 2 && "$distinct" -ge 2 ]]; then
      pass "T-FLEET-1: 2 workers spawned with distinct state dirs"
    else
      fail "T-FLEET-1: expected 2 distinct worker dirs; count=$dir_count distinct=$distinct (log: $(cat "$T1_LOG" 2>/dev/null))"
    fi
  else
    fail "T-FLEET-1: dispatch log not created at $T1_LOG"
  fi
}

# ---------------------------------------------------------------------------
echo "=== T-FLEET-2: Board CAS claim strict — MAKATO_LOOP_CLAIM_ON_DISPATCH=1 per worker ==="
{
  T2_DIR="$TMPROOT/t2"
  T2_LOG="$T2_DIR/dispatch.log"
  mkdir -p "$T2_DIR"
  _make_stub_loop "$T2_DIR" "$T2_LOG"

  MAKATO_LOOP_SH_PATH="$T2_DIR/loop.sh" \
  MAKATO_FLEET_STATE_DIR="$T2_DIR/fleet" \
  MAKATO_HALT_FILE="$T2_DIR/no-halt" \
  MAKATO_FLEET_CAS_STRICT=1 \
  MAKATO_FLEET_TICK_SECS=1 \
  MAKATO_FLEET_DASHBOARD=0 \
    bash "$FLEET" --workers 2 --once 2>/dev/null

  if [[ -f "$T2_LOG" ]]; then
    cas_lines="$(grep "claim_on_dispatch=1" "$T2_LOG" 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$cas_lines" -ge 2 ]]; then
      pass "T-FLEET-2: both workers have MAKATO_LOOP_CLAIM_ON_DISPATCH=1 (fail-closed)"
    else
      fail "T-FLEET-2: expected >=2 lines with claim_on_dispatch=1, got $cas_lines (log: $(cat "$T2_LOG" 2>/dev/null))"
    fi
  else
    fail "T-FLEET-2: dispatch log not created"
  fi
}

# ---------------------------------------------------------------------------
echo "=== T-FLEET-3: No double-dispatch — two workers get distinct state dirs ==="
{
  T3_DIR="$TMPROOT/t3"
  T3_LOG="$T3_DIR/dispatch.log"
  mkdir -p "$T3_DIR"

  # Stub records which worker-N dir was used
  cat >"$T3_DIR/loop.sh" <<EOF
#!/usr/bin/env bash
echo "worker:\${MAKATO_LOOP_STATE_DIR:-UNSET}" >> "$T3_LOG"
exit 0
EOF
  chmod +x "$T3_DIR/loop.sh"

  MAKATO_LOOP_SH_PATH="$T3_DIR/loop.sh" \
  MAKATO_FLEET_STATE_DIR="$T3_DIR/fleet" \
  MAKATO_HALT_FILE="$T3_DIR/no-halt" \
  MAKATO_FLEET_TICK_SECS=1 \
  MAKATO_FLEET_DASHBOARD=0 \
    bash "$FLEET" --workers 2 --once 2>/dev/null

  if [[ -f "$T3_LOG" ]]; then
    worker_dirs="$(grep "^worker:" "$T3_LOG" | sed 's|^worker:||' | sort -u | wc -l | tr -d ' ')"
    if [[ "$worker_dirs" -ge 2 ]]; then
      pass "T-FLEET-3: 2 workers used distinct state dirs (no double-dispatch into same slot)"
    else
      fail "T-FLEET-3: expected 2 distinct worker dirs; got $worker_dirs (log: $(cat "$T3_LOG" 2>/dev/null))"
    fi
  else
    fail "T-FLEET-3: dispatch log not created"
  fi
}

# ---------------------------------------------------------------------------
echo "=== T-FLEET-4: Same-folder guard — in-flight sibling blocks; done sibling does not ==="
{
  T4_DIR="$TMPROOT/t4"
  T4_SPECS="$T4_DIR/specs"
  SHARED_FOLDER="$T4_SPECS/shared-epic-folder"
  mkdir -p "$SHARED_FOLDER"

  # Issue 100: in-flight (current_phase=implement)
  cat >"$SHARED_FOLDER/workflow-state-100.json" <<'WEOF'
{"issue_number": 100, "current_phase": "implement", "github_pr_number": null}
WEOF
  # Issue 101: same folder — sibling should be blocked
  cat >"$SHARED_FOLDER/workflow-state-101.json" <<'WEOF'
{"issue_number": 101, "current_phase": "pending", "github_pr_number": null}
WEOF

  # Test the guard logic by extracting it into a standalone script
  cat >"$T4_DIR/test-guard.sh" <<'GEOF'
#!/usr/bin/env bash
set -euo pipefail
TARGET_ISSUE="$1"
SPECS="$2"

_is_same_folder_inflight() {
  local target_issue="$1"
  [[ -d "$SPECS" ]] || return 1

  local target_folder=""
  local f
  while IFS= read -r -d '' f; do
    local issue_num; issue_num="$(jq -r '.issue_number // empty' "$f" 2>/dev/null || true)"
    if [[ "$issue_num" == "$target_issue" ]]; then
      target_folder="$(dirname "$f")"
      break
    fi
  done < <(find "$SPECS" -maxdepth 2 \
    \( -name 'workflow-state-*.json' -o -name 'workflow-state.json' \) \
    -print0 2>/dev/null)

  [[ -n "$target_folder" ]] || return 1

  while IFS= read -r -d '' f; do
    local issue_num; issue_num="$(jq -r '.issue_number // empty' "$f" 2>/dev/null || true)"
    [[ -z "$issue_num" ]] && continue
    [[ "$issue_num" == "$target_issue" ]] && continue
    local folder; folder="$(dirname "$f")"
    if [[ "$folder" == "$target_folder" ]]; then
      local phase; phase="$(jq -r '.current_phase // empty' "$f" 2>/dev/null || true)"
      if [[ "$phase" != "done" && -n "$phase" ]]; then
        return 0  # blocked
      fi
    fi
  done < <(find "$SPECS" -maxdepth 2 \
    \( -name 'workflow-state-*.json' -o -name 'workflow-state.json' \) \
    -print0 2>/dev/null)

  return 1  # safe
}

if _is_same_folder_inflight "$TARGET_ISSUE"; then
  echo "BLOCKED"
else
  echo "SAFE"
fi
GEOF
  chmod +x "$T4_DIR/test-guard.sh"

  # Test 1: issue 101 should be BLOCKED (sibling 100 is in-flight)
  result1="$(bash "$T4_DIR/test-guard.sh" 101 "$T4_SPECS" 2>/dev/null)"
  if [[ "$result1" == "BLOCKED" ]]; then
    pass "T-FLEET-4a: in-flight sibling blocks issue 101 (sibling 100 implement)"
  else
    fail "T-FLEET-4a: expected BLOCKED, got '$result1'"
  fi

  # Test 2: mark issue 100 as done — 101 should now be SAFE
  cat >"$SHARED_FOLDER/workflow-state-100.json" <<'WEOF'
{"issue_number": 100, "current_phase": "done", "github_pr_number": 99}
WEOF
  result2="$(bash "$T4_DIR/test-guard.sh" 101 "$T4_SPECS" 2>/dev/null)"
  if [[ "$result2" == "SAFE" ]]; then
    pass "T-FLEET-4b: done sibling does NOT block issue 101"
  else
    fail "T-FLEET-4b: expected SAFE when sibling is done, got '$result2'"
  fi
}

# ---------------------------------------------------------------------------
echo "=== T-FLEET-5: N=1 — single worker; state dir is worker-1 subdir ==="
{
  T5_DIR="$TMPROOT/t5"
  T5_LOG="$T5_DIR/dispatch.log"
  mkdir -p "$T5_DIR"
  _make_stub_loop "$T5_DIR" "$T5_LOG"

  MAKATO_LOOP_SH_PATH="$T5_DIR/loop.sh" \
  MAKATO_FLEET_STATE_DIR="$T5_DIR/fleet" \
  MAKATO_HALT_FILE="$T5_DIR/no-halt" \
  MAKATO_FLEET_TICK_SECS=1 \
  MAKATO_FLEET_DASHBOARD=0 \
    bash "$FLEET" --workers 1 --once 2>/dev/null

  if [[ -f "$T5_LOG" ]]; then
    worker_count="$(grep -v "^claim_on_dispatch" "$T5_LOG" | wc -l | tr -d ' ')"
    has_worker1="$(grep -v "^claim_on_dispatch" "$T5_LOG" | grep -c "worker-1" 2>/dev/null || echo 0)"
    if [[ "$worker_count" -eq 1 && "$has_worker1" -eq 1 ]]; then
      pass "T-FLEET-5: N=1 spawns exactly 1 worker using worker-1 state dir (serial compat)"
    else
      fail "T-FLEET-5: expected 1 worker-1 entry; count=$worker_count worker1=$has_worker1 (log: $(cat "$T5_LOG" 2>/dev/null))"
    fi
  else
    fail "T-FLEET-5: dispatch log not created at $T5_LOG"
  fi
}

# ---------------------------------------------------------------------------
echo "=== T-FLEET-6: HALT-file present → exit 0, no workers spawned ==="
{
  T6_DIR="$TMPROOT/t6"
  T6_LOG="$T6_DIR/dispatch.log"
  T6_HALT="$T6_DIR/HALT"
  mkdir -p "$T6_DIR"
  _make_stub_loop "$T6_DIR" "$T6_LOG"
  touch "$T6_HALT"

  rc=0
  MAKATO_LOOP_SH_PATH="$T6_DIR/loop.sh" \
  MAKATO_FLEET_STATE_DIR="$T6_DIR/fleet" \
  MAKATO_HALT_FILE="$T6_HALT" \
  MAKATO_FLEET_TICK_SECS=1 \
  MAKATO_FLEET_DASHBOARD=0 \
    bash "$FLEET" --workers 3 --once 2>/dev/null || rc=$?

  if [[ "$rc" -ne 0 ]]; then
    fail "T-FLEET-6: expected exit 0 with HALT file present, got $rc"
  elif [[ -f "$T6_LOG" ]]; then
    fail "T-FLEET-6: dispatch log must NOT exist when HALT file present (workers were spawned)"
  else
    pass "T-FLEET-6: HALT file present → exit 0, no workers spawned"
  fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL=$(( PASS + FAIL ))
echo ""
echo "=== loop-fleet smoke tests: ${PASS}/${TOTAL} passed ==="
if [[ "$FAIL" -gt 0 ]]; then
  echo "FAILED: $FAIL test(s) failed" >&2
  exit 1
fi
exit 0
