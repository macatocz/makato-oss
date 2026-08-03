#!/usr/bin/env bash
# Smoke tests for clock-out.sh (#602). Run from the makato repo root.
# Exits non-zero on first failure. Cleans up its sandbox on success.
#
# Usage: plugins/makato-orchestrate/hooks/clock-out-smoke-tests.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/plugins/makato-orchestrate/hooks/clock-out.sh"
WS="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"

# workflow-state.sh derives SPECS_DIR from the git COMMON dir (main checkout),
# not the worktree root. Resolve the main checkout so state reads go to the
# same location workflow-state.sh writes to.
GIT_COMMON="$(git rev-parse --git-common-dir)"
MAIN_ROOT="$(cd "$GIT_COMMON/.." && pwd)"

# Use a unique prefix under the real specs/ dir so workflow-state.sh resolves
# paths correctly (it derives SPECS_DIR from the git common dir, not an env var).
# All test specs folders are cleaned up in the trap.
TEST_PREFIX="test-clockout-smoke-$$"
SPECS_DIR="$MAIN_ROOT/specs"

cleanup() {
  rm -rf "$SPECS_DIR"/${TEST_PREFIX}-*
  rm -rf "$SPECS_DIR"/${TEST_PREFIX}
}
trap cleanup EXIT

PASS=0
FAIL=0

_pass() { PASS=$(( PASS + 1 )); echo "  PASS  $1"; }
_fail() { FAIL=$(( FAIL + 1 )); echo "  FAIL  $1"; }

# ---------------------------------------------------------------------------
# Helper — initialise workflow-state for a given key+issue in the real specs/
# dir so workflow-state.sh resolves the folder via its git-root derivation.
# ---------------------------------------------------------------------------
_make_state() {
  local key="$1"
  local issue="$2"
  "$WS" init "$key" "macatocz/test" "feat/test" "$issue" 2>&1 | grep -v "^workflow-state: initialised" || true
}

echo "clock-out.sh smoke tests"
echo "========================"

# ---------------------------------------------------------------------------
# T1: Missing KEY exits 1
# ---------------------------------------------------------------------------
echo "T1: missing KEY exits 1"
if "$HOOK" 2>/dev/null; then
  _fail "T1: expected exit 1, got 0"
else
  _pass "T1: exit 1 on missing KEY"
fi

# ---------------------------------------------------------------------------
# T2: Missing ISSUE_NUMBER exits 1
# ---------------------------------------------------------------------------
echo "T2: missing ISSUE_NUMBER exits 1"
if "$HOOK" mykey 2>/dev/null; then
  _fail "T2: expected exit 1, got 0"
else
  _pass "T2: exit 1 on missing ISSUE_NUMBER"
fi

# ---------------------------------------------------------------------------
# T3: Missing DESCRIPTION exits 1
# ---------------------------------------------------------------------------
echo "T3: missing DESCRIPTION exits 1"
if "$HOOK" mykey 42 2>/dev/null; then
  _fail "T3: expected exit 1, got 0"
else
  _pass "T3: exit 1 on missing DESCRIPTION"
fi

# ---------------------------------------------------------------------------
# T4: Non-integer ISSUE_NUMBER exits 1
# ---------------------------------------------------------------------------
echo "T4: non-integer ISSUE_NUMBER exits 1"
if "$HOOK" mykey abc "some desc" 2>/dev/null; then
  _fail "T4: expected exit 1, got 0"
else
  _pass "T4: exit 1 on non-integer ISSUE_NUMBER"
fi

# ---------------------------------------------------------------------------
# T5: Zero ISSUE_NUMBER exits 1
# ---------------------------------------------------------------------------
echo "T5: zero ISSUE_NUMBER exits 1"
if "$HOOK" mykey 0 "some desc" 2>/dev/null; then
  _fail "T5: expected exit 1, got 0"
else
  _pass "T5: exit 1 on zero ISSUE_NUMBER"
fi

# ---------------------------------------------------------------------------
# T6: Stderr message mentions usage on missing KEY
# ---------------------------------------------------------------------------
echo "T6: stderr contains usage hint on missing KEY"
STDERR_OUT="$("$HOOK" 2>&1 || true)"
if echo "$STDERR_OUT" | grep -q "Usage:"; then
  _pass "T6: stderr contains Usage hint"
else
  _fail "T6: stderr missing Usage hint (got: $STDERR_OUT)"
fi

# ---------------------------------------------------------------------------
# T7: Successful invocation exits 0 and prints commit command
# ---------------------------------------------------------------------------
echo "T7: successful invocation exits 0 and prints commit command"
KEY7="${TEST_PREFIX}-t7"
_make_state "$KEY7" 99
OUTPUT="$("$HOOK" "$KEY7" 99 "implemented feature X" 2>&1)"
EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]]; then
  _fail "T7: expected exit 0, got $EXIT_CODE"
elif echo "$OUTPUT" | grep -q "git commit"; then
  _pass "T7: exits 0 and prints git commit command"
else
  _fail "T7: exits 0 but no git commit command in output (got: $OUTPUT)"
fi

# ---------------------------------------------------------------------------
# T8: Successful invocation appends lessons_learned entry to state
# ---------------------------------------------------------------------------
echo "T8: lessons_learned entry appended to workflow state"
KEY8="${TEST_PREFIX}-t8"
_make_state "$KEY8" 88
"$HOOK" "$KEY8" 88 "wrote tests for clock-out" 2>&1 | grep -v "^$" || true
STATE_FILE="$SPECS_DIR/${KEY8}/workflow-state-88.json"
LESSON_COUNT="$(jq '.lessons_learned | length' "$STATE_FILE")"
if [[ "$LESSON_COUNT" -ge 1 ]]; then
  _pass "T8: lessons_learned has $LESSON_COUNT entry"
else
  _fail "T8: expected ≥1 lessons_learned entry, got $LESSON_COUNT"
fi

# ---------------------------------------------------------------------------
# T9: Successful invocation updates resume_point in state
# ---------------------------------------------------------------------------
echo "T9: resume_point updated in workflow state"
KEY9="${TEST_PREFIX}-t9"
_make_state "$KEY9" 77
"$HOOK" "$KEY9" 77 "verified AC-4 passes" 2>&1 | grep -v "^$" || true
STATE_FILE="$SPECS_DIR/${KEY9}/workflow-state-77.json"
RESUME="$(jq -r '.resume_point' "$STATE_FILE")"
if [[ -n "$RESUME" && "$RESUME" != "null" ]]; then
  _pass "T9: resume_point set to: $RESUME"
else
  _fail "T9: resume_point not updated (got: $RESUME)"
fi

# ---------------------------------------------------------------------------
# T10: lesson trigger is "halt" (correct enum for human session)
# ---------------------------------------------------------------------------
echo "T10: lessons_learned trigger is 'halt'"
KEY10="${TEST_PREFIX}-t10"
_make_state "$KEY10" 66
"$HOOK" "$KEY10" 66 "human session trigger check" 2>&1 | grep -v "^$" || true
STATE_FILE="$SPECS_DIR/${KEY10}/workflow-state-66.json"
TRIGGER="$(jq -r '.lessons_learned[-1].trigger' "$STATE_FILE")"
if [[ "$TRIGGER" == "halt" ]]; then
  _pass "T10: trigger is 'halt'"
else
  _fail "T10: expected trigger 'halt', got '$TRIGGER'"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
