#!/usr/bin/env bash
# Smoke tests for scripts/context-handoff.sh — the HALT-007B proactive
# handoff path (GAP-004 / #30). Run from the makato repo root.
#
# Usage:
#   plugins/makato-orchestrate/scripts/context-handoff-smoke-tests.sh
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
#   T5: emit-resume produces an idempotent, executable resume script
#   T6: emit-resume's idempotency guard fires when current_phase == done
#   T7: missing session_summary triggers HALT-007 fallback (NEVER 6)
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WS="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"
HANDOFF="$REPO_ROOT/plugins/makato-orchestrate/scripts/context-handoff.sh"
KEY="gap-004-handoff-smoke"
SANDBOX="$REPO_ROOT/specs/${KEY}"
STATE_FILE="$SANDBOX/workflow-state.json"
RESUME_SCRIPT="$REPO_ROOT/.claude/state/resume-${KEY}.sh"

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
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX"
  MAKATO_CONTEXT_WARN_TOKENS=150000 "$WS" init "$KEY" macatocz/test feat/gap-004 30 >/dev/null 2>&1
  "$WS" patch "$KEY" '.budget_consumed_tokens' "$consumed"
  "$WS" patch "$KEY" '.session_count' "$count"
  "$WS" patch "$KEY" '.resume_point' '"task:7"'
  if [[ "$with_summary" == "yes" ]]; then
    "$WS" patch "$KEY" '.session_summary' '"RUN: test · issue #30 · session 1\n\nDONE (0 tasks)\n\nNEXT: task:7"'
  fi
}

echo "=== T1: below threshold → no-op ==="
_init_state 100000 0 yes
"$HANDOFF" check "$KEY"  # exit 0 expected
COUNT_AFTER=$("$WS" read "$KEY" | jq -r '.session_count')
HANDOFF_AFTER=$("$WS" read "$KEY" | jq -r '.handoff_reason')
[[ "$COUNT_AFTER" == "0" ]]      || { echo "  ✗ FAIL: session_count mutated"; exit 1; }
[[ "$HANDOFF_AFTER" == "null" ]] || { echo "  ✗ FAIL: handoff_reason set"; exit 1; }
[[ ! -f "$RESUME_SCRIPT" ]]      || { echo "  ✗ FAIL: resume script emitted"; exit 1; }
echo "  ✓ no mutation, no resume script"

echo "=== T2: threshold crossed, restart succeeds (dry-run) → HANDOFF ==="
_init_state 160000 0 yes
set +e
MAKATO_CLAUDE_BIN="$STUB_CLAUDE" MAKATO_HANDOFF_DRY_RUN=1 \
  "$HANDOFF" check "$KEY"
RC=$?
set -e
[[ $RC -eq 2 ]]                                                                    || { echo "  ✗ FAIL: expected exit 2, got $RC"; exit 1; }
[[ "$("$WS" read "$KEY" | jq -r '.session_count')" == "1" ]]                       || { echo "  ✗ FAIL: session_count not incremented"; exit 1; }
[[ "$("$WS" read "$KEY" | jq -r '.handoff_reason')" == "context_ceiling" ]]        || { echo "  ✗ FAIL: handoff_reason not set"; exit 1; }
[[ "$("$WS" read "$KEY" | jq -r '.halt_audit[-1].code')" == "HALT-007B" ]]         || { echo "  ✗ FAIL: HALT-007B not appended"; exit 1; }
[[ "$("$WS" read "$KEY" | jq -r '.restart_failed')" == "false" ]]                  || { echo "  ✗ FAIL: restart_failed mistakenly set"; exit 1; }
[[ "$("$WS" read "$KEY" | jq -r '.halt_audit[-1].data.resume_point')" == "task:7" ]] || { echo "  ✗ FAIL: resume_point missing from audit"; exit 1; }
[[ -x "$RESUME_SCRIPT" ]]                                                          || { echo "  ✗ FAIL: resume script not emitted/executable"; exit 1; }
# Audit must NOT include needs-human-review signal — NEVER 9.
[[ "$("$WS" read "$KEY" | jq -r '.human_review_cycles')" == "0" ]]                 || { echo "  ✗ FAIL: human_review_cycles incremented on handoff (NEVER 9)"; exit 1; }
echo "  ✓ exit 2, session_count→1, handoff_reason=context_ceiling, HALT-007B audited, no review cycle"

echo "=== T3: threshold crossed, claude binary missing → HALT-007 ==="
_init_state 160000 0 yes
set +e
MAKATO_CLAUDE_BIN="/does/not/exist/claude" "$HANDOFF" check "$KEY" 2>/dev/null
RC=$?
set -e
[[ $RC -eq 1 ]]                                                              || { echo "  ✗ FAIL: expected exit 1, got $RC"; exit 1; }
[[ "$("$WS" read "$KEY" | jq -r '.restart_failed')" == "true" ]]             || { echo "  ✗ FAIL: restart_failed not set"; exit 1; }
[[ "$("$WS" read "$KEY" | jq -r '.halt_audit[-1].code')" == "HALT-007" ]]    || { echo "  ✗ FAIL: HALT-007 not appended"; exit 1; }
echo "  ✓ exit 1, restart_failed=true, HALT-007 audited"

echo "=== T4: session_count >= MAKATO_MAX_HANDOFFS → HALT-007 ==="
_init_state 160000 5 yes
set +e
MAKATO_MAX_HANDOFFS=5 MAKATO_CLAUDE_BIN="$STUB_CLAUDE" \
  "$HANDOFF" check "$KEY" 2>/dev/null
RC=$?
set -e
[[ $RC -eq 1 ]]                                                              || { echo "  ✗ FAIL: expected exit 1, got $RC"; exit 1; }
[[ "$("$WS" read "$KEY" | jq -r '.halt_audit[-1].code')" == "HALT-007" ]]    || { echo "  ✗ FAIL: HALT-007 not appended"; exit 1; }
# handoff_reason must remain null — this is HALT-007 territory, not HALT-007B.
[[ "$("$WS" read "$KEY" | jq -r '.handoff_reason')" == "null" ]]             || { echo "  ✗ FAIL: handoff_reason set on cap-fallback"; exit 1; }
[[ "$("$WS" read "$KEY" | jq -r '.session_count')" == "5" ]]                 || { echo "  ✗ FAIL: session_count mutated on cap-fallback"; exit 1; }
echo "  ✓ exit 1, HALT-007 audited, handoff_reason untouched, session_count untouched"

echo "=== T5: emit-resume produces idempotent executable script ==="
_init_state 160000 0 yes
"$HANDOFF" emit-resume "$KEY"
[[ -x "$RESUME_SCRIPT" ]]                                                  || { echo "  ✗ FAIL: resume script not executable"; exit 1; }
grep -qE 'claude["[:space:]]+.*--session loop --autonomous'    "$RESUME_SCRIPT"   || { echo "  ✗ FAIL: resume script missing dispatch command"; exit 1; }
grep -qE 'current_phase[[:space:]]*=.*done'                    "$RESUME_SCRIPT"   || { echo "  ✗ FAIL: resume script missing idempotency guard"; exit 1; }
echo "  ✓ resume script executable, contains dispatch + idempotency guard"

echo "=== T6: resume script no-ops when current_phase == done ==="
"$WS" patch "$KEY" '.current_phase' '"done"'
set +e
MAKATO_CLAUDE_BIN="$STUB_CLAUDE" bash "$RESUME_SCRIPT" 2>&1 >/dev/null
RC=$?
set -e
[[ $RC -eq 0 ]]                                                            || { echo "  ✗ FAIL: resume script returned $RC instead of 0"; exit 1; }
[[ ! -f "$STUB_DIR/claude-args.log" ]]                                     || { echo "  ✗ FAIL: stub claude was invoked despite done phase"; exit 1; }
echo "  ✓ resume script no-ops when phase=done; stub claude not invoked"

echo "=== T7: missing session_summary triggers HALT-007 fallback (NEVER 6) ==="
_init_state 160000 0 no
set +e
MAKATO_CLAUDE_BIN="$STUB_CLAUDE" MAKATO_HANDOFF_DRY_RUN=1 \
  "$HANDOFF" check "$KEY" 2>/dev/null
RC=$?
set -e
[[ $RC -eq 1 ]]                                                              || { echo "  ✗ FAIL: expected exit 1, got $RC"; exit 1; }
[[ "$("$WS" read "$KEY" | jq -r '.halt_audit[-1].code')" == "HALT-007" ]]    || { echo "  ✗ FAIL: HALT-007 not appended"; exit 1; }
[[ "$("$WS" read "$KEY" | jq -r '.restart_failed')" == "true" ]]             || { echo "  ✗ FAIL: restart_failed not set"; exit 1; }
echo "  ✓ exit 1, restart_failed=true, HALT-007 audited"

echo
echo "All 7 context-handoff smoke tests passed."
