#!/usr/bin/env bash
# Smoke tests for scripts/context-handoff.sh — the HALT-007B proactive
# handoff path (GAP-004 / #30). Run from any checkout or linked worktree of the
# makato repo; it operates on the checkout that contains the working directory.
#
# Usage:
#   plugins/makato-orchestrate/scripts/tests/context-handoff-smoke-tests.sh
#
# Test scenarios (per issue #30 AC):
#   T1: below threshold → no-op (exit 0, no state mutation)
#   T2: threshold crossed, restart succeeds → HANDOFF (exit 2,
#       session_count incremented, handoff_reason set, halt_audit[HALT-007B])
#   T3: threshold crossed, claude binary missing → HALT-007 fallback
#       (exit 1, restart_failed: true, halt_audit[HALT-007])
#   T4: session_count >= MAKATO_MAX_HANDOFFS → HALT-007 (exit 1, no
#       handoff_reason mutation, halt_audit[HALT-007])
#
# Plus three contract-detail tests:
#   T5:  emit-resume produces an idempotent, executable resume script
#        (default OMP mode bakes in --yolo, never the Claude-only flag)
#   T5b: MAKATO_HARNESS_MODE=claude — the explicit compatibility mode —
#        bakes in --dangerously-skip-permissions instead (Task 3)
#   T6:  emit-resume's idempotency guard fires when current_phase == done
#   T7:  missing session_summary triggers HALT-007 fallback (NEVER 6)
#
# Plus three #281 delta-baseline tests (HALT-007B evaluates the per-session
# delta, not the cumulative total, so a resumed session does not restart-storm):
#   T8:  resumed session below the delta threshold → no-op (storm prevented)
#   T9:  delta above threshold still hands off; baseline advances to consumed
#   T10: absent session_baseline_tokens (pre-#281 state) defaults to 0
#
# Plus four #284 liveness-watchdog tests (spawned_pid recorded on the live
# fork; check-pid supervises the resumed subprocess):
#   T11: live fork (non-dry-run) records spawned_pid in workflow-state
#   T12: check-pid clears the pid when a fresh resume_ack is present (healthy)
#   T13: check-pid fires HALT-007 when the pid is alive but no ack within timeout
#   T14: check-pid fires HALT-007 immediately when the pid is dead (no wait)
#   T15: check-pid is idempotent — after a fallback fires it clears spawned_pid,
#        so a re-check on the same state no-ops (no duplicate HALT-007 audit)
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# Run in the context of THIS session's checkout. Without the pin,
# workflow-state.sh resolves the shared main checkout through --git-common-dir
# (the per-run-worktree contract, #282), so a test started from a linked
# worktree wrote its state into the main checkout's specs/ while SANDBOX, the
# resume script and change-state globs stayed in the worktree. In the main
# checkout both roots are the same directory, so nothing changes there. Set
# unconditionally: an inherited target root must not redirect a smoke test
# into another repository.
export MAKATO_TARGET_REPO_ROOT="$REPO_ROOT"
WS="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"
HANDOFF="$REPO_ROOT/plugins/makato-orchestrate/scripts/context-handoff.sh"
KEY="gap-004-handoff-smoke"
ISSUE=30
SANDBOX="$REPO_ROOT/specs/${KEY}"
RESUME_SCRIPT="$REPO_ROOT/.claude/state/resume-${KEY}-${ISSUE}.sh"

# Stub claude binary used in tests that should NOT find a real claude
# on PATH. Lives under the job's tmp dir; cleaned up by trap.
STUB_DIR="${CLAUDE_JOB_DIR:-/tmp}/handoff-tests-$$"

cleanup() {
  rm -rf "$SANDBOX" "$STUB_DIR" "$RESUME_SCRIPT"
}
trap cleanup EXIT
# Pre-clean leftovers from a previous aborted run, BUT don't nuke the
# stub directory we're about to create below.
rm -rf "$SANDBOX" "$RESUME_SCRIPT"

mkdir -p "$STUB_DIR"
STUB_CLAUDE="$STUB_DIR/claude-stub"
cat > "$STUB_CLAUDE" <<STUB
#!/usr/bin/env bash
# Stub claude binary — records its argv and exits 0.
printf '%s\n' "\$@" > "$STUB_DIR/claude-args.log"
exit 0
STUB
chmod +x "$STUB_CLAUDE"

# Helper: reset state to a known-good baseline for each test.
_init_state() {
  local consumed="${1:-0}"
  local count="${2:-0}"
  local with_summary="${3:-yes}"
  local baseline="${4:-0}"
  # #616: last_session_id — the UUID `claude --resume` requires. Defaults to a
  # fixed fake UUID so every emit-resume/handoff fixture has one; pass "none"
  # to simulate a state file where no session id was ever captured (exercises
  # the HALT-007 fallback in _emit_resume).
  local session_id="${5:-11111111-2222-3333-4444-555555555555}"
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX"
  MAKATO_CONTEXT_WARN_TOKENS=150000 "$WS" init "$KEY" macatocz/test feat/gap-004 "$ISSUE" >/dev/null 2>&1
  "$WS" patch "$KEY" "$ISSUE" '.budget_consumed_tokens' "$consumed"
  "$WS" patch "$KEY" "$ISSUE" '.session_baseline_tokens' "$baseline"
  "$WS" patch "$KEY" "$ISSUE" '.session_count' "$count"
  "$WS" patch "$KEY" "$ISSUE" '.resume_point' '"task:7"'
  if [[ "$session_id" != "none" ]]; then
    "$WS" patch "$KEY" "$ISSUE" '.last_session_id' "\"$session_id\""
  fi
  if [[ "$with_summary" == "yes" ]]; then
    "$WS" patch "$KEY" "$ISSUE" '.session_summary' '"RUN: test · issue #30 · session 1\n\nDONE (0 tasks)\n\nNEXT: task:7"'
  fi
}

echo "=== T1: below threshold → no-op ==="
_init_state 100000 0 yes
"$HANDOFF" check "$KEY" "$ISSUE"  # exit 0 expected
COUNT_AFTER=$("$WS" read "$KEY" "$ISSUE" | jq -r '.session_count')
HANDOFF_AFTER=$("$WS" read "$KEY" "$ISSUE" | jq -r '.handoff_reason')
[[ "$COUNT_AFTER" == "0" ]]      || { echo "  ✗ FAIL: session_count mutated"; exit 1; }
[[ "$HANDOFF_AFTER" == "null" ]] || { echo "  ✗ FAIL: handoff_reason set"; exit 1; }
[[ ! -f "$RESUME_SCRIPT" ]]      || { echo "  ✗ FAIL: resume script emitted"; exit 1; }
echo "  ✓ no mutation, no resume script"

echo "=== T2: threshold crossed, restart succeeds (dry-run) → HANDOFF ==="
# NB (#284): this uses MAKATO_HANDOFF_DRY_RUN=1, which exits BEFORE the nohup
# fork, so spawned_pid is intentionally NOT written here. The live-fork PID
# recording is exercised by T11 (the only test that runs the real fork).
_init_state 160000 0 yes
set +e
MAKATO_HARNESS_BIN="$STUB_CLAUDE" MAKATO_HANDOFF_DRY_RUN=1 \
  "$HANDOFF" check "$KEY" "$ISSUE"
RC=$?
set -e
[[ $RC -eq 2 ]]                                                                    || { echo "  ✗ FAIL: expected exit 2, got $RC"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.session_count')" == "1" ]]                       || { echo "  ✗ FAIL: session_count not incremented"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.handoff_reason')" == "context_ceiling" ]]        || { echo "  ✗ FAIL: handoff_reason not set"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.halt_audit[-1].code')" == "HALT-007B" ]]         || { echo "  ✗ FAIL: HALT-007B not appended"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.restart_failed')" == "false" ]]                  || { echo "  ✗ FAIL: restart_failed mistakenly set"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.halt_audit[-1].data.resume_point')" == "task:7" ]] || { echo "  ✗ FAIL: resume_point missing from audit"; exit 1; }
[[ -x "$RESUME_SCRIPT" ]]                                                          || { echo "  ✗ FAIL: resume script not emitted/executable"; exit 1; }
# Audit must NOT include needs-human-review signal — NEVER 9.
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.human_review_cycles')" == "0" ]]                 || { echo "  ✗ FAIL: human_review_cycles incremented on handoff (NEVER 9)"; exit 1; }
# #281: baseline advanced to the cumulative total at handoff so the resumed
# session's context delta restarts at zero.
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.session_baseline_tokens')" == "160000" ]]        || { echo "  ✗ FAIL: session_baseline_tokens not advanced to consumed (#281)"; exit 1; }
echo "  ✓ exit 2, session_count→1, handoff_reason=context_ceiling, baseline→160000, HALT-007B audited, no review cycle"

echo "=== T3: threshold crossed, claude binary missing → HALT-007 ==="
_init_state 160000 0 yes
set +e
MAKATO_HARNESS_BIN="/does/not/exist/claude" "$HANDOFF" check "$KEY" "$ISSUE" 2>/dev/null
RC=$?
set -e
[[ $RC -eq 1 ]]                                                              || { echo "  ✗ FAIL: expected exit 1, got $RC"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.restart_failed')" == "true" ]]             || { echo "  ✗ FAIL: restart_failed not set"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.halt_audit[-1].code')" == "HALT-007" ]]    || { echo "  ✗ FAIL: HALT-007 not appended"; exit 1; }
echo "  ✓ exit 1, restart_failed=true, HALT-007 audited"

echo "=== T4: session_count >= MAKATO_MAX_HANDOFFS → HALT-007 ==="
_init_state 160000 5 yes
set +e
MAKATO_MAX_HANDOFFS=5 MAKATO_HARNESS_BIN="$STUB_CLAUDE" \
  "$HANDOFF" check "$KEY" "$ISSUE" 2>/dev/null
RC=$?
set -e
[[ $RC -eq 1 ]]                                                              || { echo "  ✗ FAIL: expected exit 1, got $RC"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.halt_audit[-1].code')" == "HALT-007" ]]    || { echo "  ✗ FAIL: HALT-007 not appended"; exit 1; }
# handoff_reason must remain null — this is HALT-007 territory, not HALT-007B.
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.handoff_reason')" == "null" ]]             || { echo "  ✗ FAIL: handoff_reason set on cap-fallback"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.session_count')" == "5" ]]                 || { echo "  ✗ FAIL: session_count mutated on cap-fallback"; exit 1; }
echo "  ✓ exit 1, HALT-007 audited, handoff_reason untouched, session_count untouched"

echo "=== T5: emit-resume produces idempotent executable script (default OMP mode) ==="
_init_state 160000 0 yes
"$HANDOFF" emit-resume "$KEY" "$ISSUE"
[[ -x "$RESUME_SCRIPT" ]]                                                  || { echo "  ✗ FAIL: resume script not executable"; exit 1; }
# Default mode (no MAKATO_HARNESS_MODE at emit time) must bake in --yolo (OMP),
# NEVER the Claude-only --dangerously-skip-permissions flag (Task 3: harness-neutral
# dispatch/resume — "no selection of Claude when OMP is configured").
grep -qE -- '--yolo.*--resume'    "$RESUME_SCRIPT"   || { echo "  ✗ FAIL: resume script missing --yolo dispatch command"; exit 1; }
grep -qE -- '--dangerously-skip-permissions' "$RESUME_SCRIPT" && { echo "  ✗ FAIL: default-mode resume script must not bake in --dangerously-skip-permissions"; exit 1; } || true
grep -qE 'current_phase[[:space:]]*=.*done'                    "$RESUME_SCRIPT"   || { echo "  ✗ FAIL: resume script missing idempotency guard"; exit 1; }
# #616: --resume must receive the session UUID, NOT the spec KEY. Assert the
# UUID is baked in and the KEY is NOT the --resume argument.
grep -q 'SESSION_ID="11111111-2222-3333-4444-555555555555"' "$RESUME_SCRIPT" || { echo "  ✗ FAIL: resume script did not bake in last_session_id UUID"; exit 1; }
grep -qE -- '--resume "\$SESSION_ID"' "$RESUME_SCRIPT"                        || { echo "  ✗ FAIL: resume script does not pass \$SESSION_ID to --resume"; exit 1; }
grep -qE -- '--resume "\$KEY"' "$RESUME_SCRIPT"                               && { echo "  ✗ FAIL: resume script still passes KEY to --resume (#616 regression)"; exit 1; } || true
echo "  ✓ resume script executable, --yolo dispatch + idempotency guard, --resume uses SESSION_ID (not KEY)"

echo "=== T5b: emit-resume with MAKATO_HARNESS_MODE=claude bakes in --dangerously-skip-permissions ==="
_init_state 160000 0 yes
rm -f "$RESUME_SCRIPT"
MAKATO_HARNESS_MODE=claude "$HANDOFF" emit-resume "$KEY" "$ISSUE"
[[ -x "$RESUME_SCRIPT" ]]                                                  || { echo "  ✗ FAIL: resume script not executable (claude mode)"; exit 1; }
grep -qE -- '--dangerously-skip-permissions.*--resume' "$RESUME_SCRIPT"    || { echo "  ✗ FAIL: MAKATO_HARNESS_MODE=claude resume script missing --dangerously-skip-permissions"; exit 1; }
grep -qE -- '--yolo' "$RESUME_SCRIPT"                                       && { echo "  ✗ FAIL: claude-mode resume script must not also bake in --yolo"; exit 1; } || true
echo "  ✓ MAKATO_HARNESS_MODE=claude → resume script bakes in --dangerously-skip-permissions, not --yolo"

echo "=== T6: resume script no-ops when current_phase == done ==="
"$WS" patch "$KEY" "$ISSUE" '.current_phase' '"done"'
set +e
MAKATO_HARNESS_BIN="$STUB_CLAUDE" bash "$RESUME_SCRIPT" >/dev/null 2>&1
RC=$?
set -e
[[ $RC -eq 0 ]]                                                            || { echo "  ✗ FAIL: resume script returned $RC instead of 0"; exit 1; }
[[ ! -f "$STUB_DIR/claude-args.log" ]]                                     || { echo "  ✗ FAIL: stub claude was invoked despite done phase"; exit 1; }
echo "  ✓ resume script no-ops when phase=done; stub claude not invoked"

echo "=== T7: missing session_summary triggers HALT-007 fallback (NEVER 6) ==="
_init_state 160000 0 no
set +e
MAKATO_HARNESS_BIN="$STUB_CLAUDE" MAKATO_HANDOFF_DRY_RUN=1 \
  "$HANDOFF" check "$KEY" "$ISSUE" 2>/dev/null
RC=$?
set -e
[[ $RC -eq 1 ]]                                                              || { echo "  ✗ FAIL: expected exit 1, got $RC"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.halt_audit[-1].code')" == "HALT-007" ]]    || { echo "  ✗ FAIL: HALT-007 not appended"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.restart_failed')" == "true" ]]             || { echo "  ✗ FAIL: restart_failed not set"; exit 1; }
echo "  ✓ exit 1, restart_failed=true, HALT-007 audited"

echo "=== T8: #281 — resumed session below the delta threshold does NOT re-hand-off ==="
# Simulate the resumed session after one handoff: cumulative consumption is far
# past context_warn_tokens (as it would be post-handoff), but the baseline was
# advanced to that same value, so the per-session delta is 0. Pre-#281 this
# re-fired HALT-007B on the first boundary → restart storm.
_init_state 320000 1 yes 300000   # consumed=320k, baseline=300k → delta=20k < 150k
rm -f "$RESUME_SCRIPT"             # clear any script emitted by earlier tests
set +e
MAKATO_HARNESS_BIN="$STUB_CLAUDE" MAKATO_HANDOFF_DRY_RUN=1 \
  "$HANDOFF" check "$KEY" "$ISSUE"
RC=$?
set -e
[[ $RC -eq 0 ]]                                                              || { echo "  ✗ FAIL: expected exit 0 (no-op), got $RC — storm not prevented"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.session_count')" == "1" ]]                 || { echo "  ✗ FAIL: session_count mutated on a below-delta check"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.session_baseline_tokens')" == "300000" ]]  || { echo "  ✗ FAIL: baseline mutated on a below-delta check"; exit 1; }
[[ ! -f "$RESUME_SCRIPT" ]]                                                  || { echo "  ✗ FAIL: resume script emitted on a below-delta check"; exit 1; }
echo "  ✓ delta 20k < 150k → no-op; no second handoff, baseline/session_count untouched"

echo "=== T9: #281 — delta above threshold still hands off (baseline honoured) ==="
# consumed=480k, baseline=300k → delta=180k >= 150k: this session genuinely
# accrued enough context pressure, so a handoff is correct.
# NB (#284): dry-run again — no fork, so spawned_pid stays null (see T11).
_init_state 480000 1 yes 300000
set +e
MAKATO_HARNESS_BIN="$STUB_CLAUDE" MAKATO_HANDOFF_DRY_RUN=1 \
  "$HANDOFF" check "$KEY" "$ISSUE"
RC=$?
set -e
[[ $RC -eq 2 ]]                                                              || { echo "  ✗ FAIL: expected exit 2 (HANDOFF), got $RC"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.session_count')" == "2" ]]                 || { echo "  ✗ FAIL: session_count not incremented"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.session_baseline_tokens')" == "480000" ]]  || { echo "  ✗ FAIL: baseline not advanced to new consumed"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.halt_audit[-1].data.session_delta_tokens')" == "180000" ]] || { echo "  ✗ FAIL: session_delta_tokens not audited"; exit 1; }
echo "  ✓ delta 180k >= 150k → HANDOFF, baseline→480000, delta audited"

echo "=== T10: #281 — absent session_baseline_tokens (pre-fix state) defaults to 0 ==="
# In-flight state files created before #281 have no session_baseline_tokens.
# The reader must default it to 0 → delta == cumulative, i.e. identical to the
# original behaviour (no regression for legacy runs).
_init_state 160000 0 yes 0
LEGACY_STATE="$("$WS" read "$KEY" "$ISSUE" | jq 'del(.session_baseline_tokens)')"
"$WS" write "$KEY" "$ISSUE" "$LEGACY_STATE"
[[ "$("$WS" read "$KEY" "$ISSUE" | jq 'has("session_baseline_tokens")')" == "false" ]] || { echo "  ✗ FAIL: could not strip session_baseline_tokens for the legacy fixture"; exit 1; }
set +e
MAKATO_HARNESS_BIN="$STUB_CLAUDE" MAKATO_HANDOFF_DRY_RUN=1 \
  "$HANDOFF" check "$KEY" "$ISSUE"
RC=$?
set -e
[[ $RC -eq 2 ]]                                                              || { echo "  ✗ FAIL: expected exit 2 (HANDOFF on cumulative fallback), got $RC"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.session_baseline_tokens')" == "160000" ]]  || { echo "  ✗ FAIL: baseline not written on handoff from legacy state"; exit 1; }
echo "  ✓ absent baseline → treated as 0, handoff fires, baseline written for next session"

echo "=== T11: #284 — live fork (non-dry-run) records spawned_pid in state ==="
# The only test that exercises the REAL nohup fork. The stub claude exits 0
# immediately; the resume script's idempotency guard is not the point here —
# we assert that context-handoff.sh captured $! and persisted it before disown.
_init_state 160000 0 yes
rm -f "$RESUME_SCRIPT"
set +e
MAKATO_HARNESS_BIN="$STUB_CLAUDE" "$HANDOFF" check "$KEY" "$ISSUE" 2>/dev/null
RC=$?
set -e
[[ $RC -eq 2 ]]                                                                     || { echo "  ✗ FAIL: expected exit 2 (HANDOFF), got $RC"; exit 1; }
PID_AFTER=$("$WS" read "$KEY" "$ISSUE" | jq -r '.spawned_pid')
[[ "$PID_AFTER" =~ ^[0-9]+$ ]]                                                       || { echo "  ✗ FAIL: spawned_pid not recorded or not an integer (got '$PID_AFTER')"; exit 1; }
[[ "$PID_AFTER" -ge 1 ]]                                                             || { echo "  ✗ FAIL: spawned_pid not >= 1"; exit 1; }
echo "  ✓ live fork recorded spawned_pid=$PID_AFTER before disown"
# Reap the stub subprocess so it does not linger.
wait "$PID_AFTER" 2>/dev/null || true

# Helper: an ISO-8601 (ms, UTC) timestamp shifted by N seconds from now.
# Positive N = future, negative N = past. Mirrors context-handoff.sh:_now.
_ts_shift() {
  python3 -c "import sys,datetime
n=datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=int(sys.argv[1]))
print(n.strftime('%Y-%m-%dT%H:%M:%S.')+f'{n.microsecond//1000:03d}Z')" "$1"
}

# Helper: seed a state file with a pending HALT-007B handoff. Args:
#   $1 spawned_pid (JSON int or null)   $2 resume_ack (JSON string or null)
#   $3 handoff-audit age in seconds (how far in the PAST the HALT-007B fired)
_seed_handoff() {
  local pid="$1" ack="$2" age="$3"
  local hts; hts="$(_ts_shift "-${age}")"
  _init_state 160000 1 yes 160000
  "$WS" write "$KEY" "$ISSUE" "$("$WS" read "$KEY" "$ISSUE" | jq \
    --argjson pid "$pid" --argjson ack "$ack" --arg hts "$hts" \
    '.handoff_reason = "context_ceiling"
     | .spawned_pid = $pid
     | .resume_ack = $ack
     | .halt_audit = [{code: "HALT-007B", ts: $hts, data: {}}]')" >/dev/null 2>&1
}

echo "=== T12: #284 — check-pid clears pid when a fresh resume_ack is present ==="
# handoff fired 60s ago; ack written just now (fresher) → healthy resume.
FRESH_ACK="$(_ts_shift 0)"
_seed_handoff 424242 "\"$FRESH_ACK\"" 60
set +e
"$HANDOFF" check-pid "$KEY" "$ISSUE" >/dev/null 2>&1
RC=$?
set -e
[[ $RC -eq 0 ]]                                                                     || { echo "  ✗ FAIL: expected exit 0 (healthy), got $RC"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.spawned_pid')" == "null" ]]                        || { echo "  ✗ FAIL: spawned_pid not cleared after healthy ack"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.restart_failed')" == "false" ]]                    || { echo "  ✗ FAIL: restart_failed set on a healthy resume"; exit 1; }
echo "  ✓ fresh ack → pid cleared, no fallback"

echo "=== T13: #284 — check-pid fires HALT-007 when pid alive but no ack in window ==="
# Use this shell's own PID (guaranteed alive), handoff fired 300s ago, no ack,
# ACK_TIMEOUT=1 → the window has elapsed. Fallback must fire.
_seed_handoff "$$" null 300
set +e
MAKATO_HANDOFF_ACK_TIMEOUT=1 MAKATO_HANDOFF_SKIP_LABEL=1 \
  "$HANDOFF" check-pid "$KEY" "$ISSUE" 2>/dev/null
RC=$?
set -e
[[ $RC -eq 1 ]]                                                                     || { echo "  ✗ FAIL: expected exit 1 (fallback), got $RC"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.restart_failed')" == "true" ]]                     || { echo "  ✗ FAIL: restart_failed not set on ack-timeout"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.halt_audit[-1].code')" == "HALT-007" ]]            || { echo "  ✗ FAIL: HALT-007 not appended on ack-timeout"; exit 1; }
echo "  ✓ alive pid + no ack past timeout → exit 1, restart_failed=true, HALT-007 audited"

echo "=== T14: #284 — check-pid fires HALT-007 immediately when the pid is dead ==="
# Spawn a throwaway subprocess and wait for it to exit → its PID is dead.
# ACK_TIMEOUT is huge; the dead-pid fast path must fire WITHOUT waiting for it.
( exit 0 ) &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
_seed_handoff "$DEAD_PID" null 5    # handoff fired only 5s ago — inside any timeout
START_EPOCH=$(python3 -c "import time;print(int(time.time()))")
set +e
MAKATO_HANDOFF_ACK_TIMEOUT=999 MAKATO_HANDOFF_SKIP_LABEL=1 \
  "$HANDOFF" check-pid "$KEY" "$ISSUE" 2>/dev/null
RC=$?
set -e
END_EPOCH=$(python3 -c "import time;print(int(time.time()))")
[[ $RC -eq 1 ]]                                                                     || { echo "  ✗ FAIL: expected exit 1 (fallback), got $RC"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.restart_failed')" == "true" ]]                     || { echo "  ✗ FAIL: restart_failed not set on dead-pid"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.halt_audit[-1].code')" == "HALT-007" ]]            || { echo "  ✗ FAIL: HALT-007 not appended on dead-pid"; exit 1; }
[[ $(( END_EPOCH - START_EPOCH )) -lt 10 ]]                                          || { echo "  ✗ FAIL: dead-pid path waited on the timeout instead of firing immediately"; exit 1; }
echo "  ✓ dead pid → immediate exit 1 (no timeout wait), restart_failed=true, HALT-007 audited"

echo "=== T15: #284 — check-pid is idempotent after a fallback (no duplicate HALT-007) ==="
# Regression for the repeated-fallback bug: the fallback must clear spawned_pid
# so the NEXT loop tick short-circuits at guard (1) instead of re-firing. Seed a
# dead-pid handoff, fire the fallback once, then re-check on the (unchanged apart
# from the fallback's own writes) state and assert no second HALT-007 lands.
( exit 0 ) &
DEAD_PID2=$!
wait "$DEAD_PID2" 2>/dev/null || true
_seed_handoff "$DEAD_PID2" null 5
set +e
MAKATO_HANDOFF_ACK_TIMEOUT=999 MAKATO_HANDOFF_SKIP_LABEL=1 \
  "$HANDOFF" check-pid "$KEY" "$ISSUE" 2>/dev/null
RC1=$?
set -e
[[ $RC1 -eq 1 ]]                                                                    || { echo "  ✗ FAIL: first check-pid did not fire fallback (got $RC1)"; exit 1; }
HALT_COUNT_1=$("$WS" read "$KEY" "$ISSUE" | jq '[.halt_audit[] | select(.code == "HALT-007")] | length')
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.spawned_pid')" == "null" ]]                        || { echo "  ✗ FAIL: fallback did not clear spawned_pid"; exit 1; }
# Second check on the same state — spawned_pid is now null, so guard (1) no-ops.
set +e
MAKATO_HANDOFF_ACK_TIMEOUT=999 MAKATO_HANDOFF_SKIP_LABEL=1 \
  "$HANDOFF" check-pid "$KEY" "$ISSUE" 2>/dev/null
RC2=$?
set -e
[[ $RC2 -eq 0 ]]                                                                    || { echo "  ✗ FAIL: second check-pid re-fired instead of no-op (got $RC2)"; exit 1; }
HALT_COUNT_2=$("$WS" read "$KEY" "$ISSUE" | jq '[.halt_audit[] | select(.code == "HALT-007")] | length')
[[ "$HALT_COUNT_1" == "$HALT_COUNT_2" ]]                                             || { echo "  ✗ FAIL: duplicate HALT-007 appended on re-check ($HALT_COUNT_1 → $HALT_COUNT_2)"; exit 1; }
echo "  ✓ fallback cleared spawned_pid; re-check no-ops, HALT-007 count stable at $HALT_COUNT_2"

# ---------------------------------------------------------------------------
# T16: emit-resume routes to makato-change:orchestrate when a change-state
#      file exists for the issue (#467). The resume script must re-establish
#      WORKTREE_PATH and must NOT dispatch po-agent.
# ---------------------------------------------------------------------------
echo "=== T16: emit-resume routes to makato-change:orchestrate when change-state exists ==="
_init_state 160000 0 yes
rm -f "$RESUME_SCRIPT"
cat > "$SANDBOX/change-state-${ISSUE}.json" <<JSON
{"schema":"change-state","version":"1.0","issue_key":"$KEY","issue_number":$ISSUE,
 "current_phase":"design","phases_complete":["analyze"],
 "worktree_path":"/tmp/fake-worktrees/test-repo-$ISSUE",
 "pr_url":null,"started_at":"2025-01-01T00:00:00.000Z","updated_at":"2025-01-01T00:00:00.000Z",
 "halt_code":null,"degraded_confidence":false}
JSON
"$HANDOFF" emit-resume "$KEY" "$ISSUE"
[[ -x "$RESUME_SCRIPT" ]]                                    || { echo "  ✗ FAIL: resume script not emitted/executable"; exit 1; }
grep -q 'makato-change:orchestrate' "$RESUME_SCRIPT"        || { echo "  ✗ FAIL: resume script does not route to makato-change:orchestrate"; exit 1; }
grep -q 'WORKTREE_PATH=' "$RESUME_SCRIPT"                   || { echo "  ✗ FAIL: resume script missing WORKTREE_PATH re-establishment"; exit 1; }
grep -q '/tmp/fake-worktrees/test-repo-'"$ISSUE" "$RESUME_SCRIPT" || { echo "  ✗ FAIL: resume script did not bake in the recovered worktree_path"; exit 1; }
grep -q 'po-agent' "$RESUME_SCRIPT"                         && { echo "  ✗ FAIL: change resume script erroneously references po-agent"; exit 1; } || true
rm -f "$SANDBOX/change-state-${ISSUE}.json"
echo "  ✓ change-state present → resume routes to makato-change:orchestrate with baked WORKTREE_PATH"

# ---------------------------------------------------------------------------
# T17: emit-resume routes to po-agent when no change-state file exists — the
#      non-change (po-agent) path must be preserved byte-for-byte (#467).
# ---------------------------------------------------------------------------
echo "=== T17: emit-resume routes to po-agent when no change-state file exists ==="
_init_state 160000 0 yes
rm -f "$RESUME_SCRIPT" "$SANDBOX/change-state-${ISSUE}.json"
"$HANDOFF" emit-resume "$KEY" "$ISSUE"
[[ -x "$RESUME_SCRIPT" ]]                                    || { echo "  ✗ FAIL: resume script not emitted/executable"; exit 1; }
grep -q 'po-agent' "$RESUME_SCRIPT"                         || { echo "  ✗ FAIL: resume script should route to po-agent for non-change issues"; exit 1; }
grep -q 'makato-change:orchestrate' "$RESUME_SCRIPT"        && { echo "  ✗ FAIL: resume script routes to makato-change:orchestrate for a non-change issue"; exit 1; } || true
echo "  ✓ no change-state → resume routes to po-agent (non-change issue preserved)"

# ---------------------------------------------------------------------------
# T18: #616 — emit-resume falls back to HALT-007 when last_session_id is absent.
#      Without a captured session UUID there is nothing valid to pass to
#      `claude --resume`, so automatic recovery is impossible and the handoff
#      must degrade to the cost-control fallback rather than emit a resume
#      script that passes the KEY.
# ---------------------------------------------------------------------------
echo "=== T18: #616 — emit-resume HALT-007 fallback when last_session_id absent ==="
_init_state 160000 0 yes 0 none   # session_id="none" (5th arg) → no last_session_id written
rm -f "$RESUME_SCRIPT"
set +e
MAKATO_HANDOFF_SKIP_LABEL=1 "$HANDOFF" emit-resume "$KEY" "$ISSUE" 2>/dev/null
RC=$?
set -e
[[ $RC -eq 1 ]]                                                            || { echo "  ✗ FAIL: expected exit 1 (HALT-007 fallback), got $RC"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.restart_failed')" == "true" ]]           || { echo "  ✗ FAIL: restart_failed not set on missing-UUID fallback"; exit 1; }
[[ "$("$WS" read "$KEY" "$ISSUE" | jq -r '.halt_audit[-1].code')" == "HALT-007" ]]  || { echo "  ✗ FAIL: HALT-007 not appended on missing-UUID fallback"; exit 1; }
[[ ! -f "$RESUME_SCRIPT" ]]                                                || { echo "  ✗ FAIL: a resume script was emitted despite the missing UUID"; exit 1; }
echo "  ✓ absent last_session_id → HALT-007 fallback, no broken resume script emitted"

# ---------------------------------------------------------------------------
# T19: #616 — change-path resume also bakes in the UUID (not the KEY).
# ---------------------------------------------------------------------------
echo "=== T19: #616 — change-state resume uses SESSION_ID (not KEY) ==="
_init_state 160000 0 yes
rm -f "$RESUME_SCRIPT"
cat > "$SANDBOX/change-state-${ISSUE}.json" <<JSON
{"schema":"change-state","version":"1.0","issue_key":"$KEY","issue_number":$ISSUE,
 "current_phase":"design","phases_complete":["analyze"],
 "worktree_path":"/tmp/fake-worktrees/test-repo-$ISSUE",
 "pr_url":null,"started_at":"2025-01-01T00:00:00.000Z","updated_at":"2025-01-01T00:00:00.000Z",
 "halt_code":null,"degraded_confidence":false}
JSON
"$HANDOFF" emit-resume "$KEY" "$ISSUE"
[[ -x "$RESUME_SCRIPT" ]]                                                  || { echo "  ✗ FAIL: resume script not emitted/executable"; exit 1; }
grep -q 'SESSION_ID="11111111-2222-3333-4444-555555555555"' "$RESUME_SCRIPT" || { echo "  ✗ FAIL: change resume script did not bake in last_session_id UUID"; exit 1; }
grep -qE -- '--resume "\$SESSION_ID"' "$RESUME_SCRIPT"                        || { echo "  ✗ FAIL: change resume script does not pass \$SESSION_ID to --resume"; exit 1; }
grep -qE -- '--resume "\$KEY"' "$RESUME_SCRIPT"                               && { echo "  ✗ FAIL: change resume script still passes KEY to --resume (#616 regression)"; exit 1; } || true
rm -f "$SANDBOX/change-state-${ISSUE}.json"
echo "  ✓ change-state resume uses SESSION_ID (not KEY)"

echo
echo "All 20 context-handoff smoke tests passed."
