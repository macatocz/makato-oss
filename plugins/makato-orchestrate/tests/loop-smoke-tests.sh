#!/usr/bin/env bash
# Smoke tests: progress-comment structural guard (#64).
#
# Verifies:
#   T1 — Progress comment created before build dispatch:
#        _init_progress_comment must record a call when MAKATO_LOOP_PROGRESS_COMMENT_TEST_FILE is set.
#   T2 — progress_comment_id persisted in workflow-state after dispatch:
#        workflow-state.sh patch must store non-null progress_comment_id.
#   T3 — Build proceeds when comment creation fails:
#        _init_progress_comment must return empty string on failure and not block dispatch.
#
# Exit code: 0 all pass; non-zero on the first failure (set -e propagation).
#
# Run from repo root:
#   bash plugins/makato-orchestrate/tests/loop-smoke-tests.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LOOP_SCRIPT="$REPO_ROOT/plugins/makato-orchestrate/scripts/loop.sh"
WORKFLOW_STATE="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"

# Confirm dependencies are present before doing anything else.
for _dep in "$LOOP_SCRIPT" "$WORKFLOW_STATE"; do
  if [[ ! -f "$_dep" ]]; then
    echo "FATAL: missing $_dep" >&2
    exit 1
  fi
done

PASS=0
FAIL=0

_pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$(( FAIL + 1 )); }

_cleanup() {
  if [[ -n "${1:-}" ]] && [[ -d "$1" ]]; then
    rm -rf "$1"
  fi
}

# ===========================================================================
# T1 — Progress comment created before build dispatch
#
# _init_progress_comment must record a call when MAKATO_LOOP_PROGRESS_COMMENT_TEST_FILE is set,
# returning a stub comment id.
# ===========================================================================
echo "=== T1: progress comment created before build dispatch ==="

T1_TEST_FILE=""
T1_TEST_FILE=$(mktemp)

(
  export MAKATO_LOOP_PROGRESS_COMMENT_TEST_FILE="$T1_TEST_FILE"
  
  comment_id=$(MAKATO_LOOP_TEST_HOOK=1 bash "$LOOP_SCRIPT" _test-init-progress-comment 64)
  
  # Verify stub comment id was returned
  if [[ -z "$comment_id" ]]; then
    echo "T1: expected non-empty comment_id, got empty" >&2
    exit 1
  fi
  
  # Verify test file was written to
  if [[ ! -s "$T1_TEST_FILE" ]]; then
    echo "T1: expected test file to be written, but it is empty" >&2
    exit 1
  fi
  
  # Verify test file contains the expected call
  if ! grep -q "progress_comment #64" "$T1_TEST_FILE"; then
    echo "T1: expected 'progress_comment #64' in test file" >&2
    exit 1
  fi
) && _pass "T1: progress comment created before build dispatch" \
  || _fail "T1: progress comment creation failed (see above)"

rm -f "$T1_TEST_FILE"

# ===========================================================================
# T2 — progress_comment_id persisted in workflow-state after dispatch
#
# After the structural guard succeeds, workflow-state.sh patch must store
# a non-null progress_comment_id in the workflow state.
# ===========================================================================
echo ""
echo "=== T2: progress_comment_id persisted in workflow-state ==="

T2_STATE_DIR=""
T2_SPECS_DIR=""
T2_STATE_DIR=$(mktemp -d)
T2_SPECS_DIR=$(mktemp -d)

# Create minimal spec folder structure
mkdir -p "$T2_SPECS_DIR/64-test-feature"

trap '_cleanup "$T2_STATE_DIR"; _cleanup "$T2_SPECS_DIR"' EXIT

(
  export SPECS_DIR="$T2_SPECS_DIR"
  export STATE_DIR="$T2_STATE_DIR"
  
  # Initialize workflow state (KEY REPO BRANCH ISSUE)
  bash "$WORKFLOW_STATE" init "64-test-feature" "owner/repo" "feature-branch" 64
  
  # Simulate progress comment guard patch
  COMMENT_ID=123456
  bash "$WORKFLOW_STATE" patch "64-test-feature" 64 '.progress_comment_id' "$COMMENT_ID"
  
  # Verify progress_comment_id is stored
  local_state=$(bash "$WORKFLOW_STATE" read "64-test-feature" 64)
  
  if ! echo "$local_state" | jq -e ".progress_comment_id == 123456" >/dev/null 2>&1; then
    echo "T2: expected progress_comment_id to be 123456" >&2
    echo "T2: got state:" >&2
    echo "$local_state" | jq '.' >&2
    exit 1
  fi
) && _pass "T2: progress_comment_id persisted in workflow-state" \
  || _fail "T2: progress_comment_id persistence failed (see above)"

trap - EXIT
_cleanup "$T2_STATE_DIR"
_cleanup "$T2_SPECS_DIR"
T2_STATE_DIR=""
T2_SPECS_DIR=""

# ===========================================================================
# T3 — Build proceeds when comment creation fails
#
# _init_progress_comment must return empty string on failure and not block dispatch.
# When MAKATO_LOOP_PROGRESS_COMMENT_TEST_FILE is not set, the function should fail gracefully.
# ===========================================================================
echo ""
echo "=== T3: build proceeds when comment creation fails ==="

(
  # Unset test file to simulate failure path
  unset MAKATO_LOOP_PROGRESS_COMMENT_TEST_FILE 2>/dev/null || true
  
  # Capture stderr to check for warning message
  stderr_file=$(mktemp)
  
  # Run the function - it should fail gracefully and return empty string
  comment_id=$(MAKATO_LOOP_TEST_HOOK=1 bash "$LOOP_SCRIPT" _test-init-progress-comment 64 2>"$stderr_file" || true)
  
  # Verify empty comment_id on failure (no test file set, so gh call fails)
  if [[ -n "$comment_id" ]]; then
    echo "T3: expected empty comment_id on failure, got '$comment_id'" >&2
    rm -f "$stderr_file"
    exit 1
  fi
  
  # Verify warning was logged to stderr
  if ! grep -q "WARN" "$stderr_file" 2>/dev/null; then
    echo "T3: expected warning message in stderr" >&2
    echo "T3: stderr was:" >&2
    cat "$stderr_file" >&2
    rm -f "$stderr_file"
    exit 1
  fi
  
  rm -f "$stderr_file"
) && _pass "T3: build proceeds when comment creation fails" \
  || _fail "T3: graceful failure handling failed (see above)"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

exit "$FAIL"
