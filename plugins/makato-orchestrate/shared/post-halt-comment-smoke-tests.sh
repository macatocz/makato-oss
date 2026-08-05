#!/usr/bin/env bash
# Smoke tests for shared/post-halt-comment.sh. Run from the makato repo root.
# Fully offline: gh is never called — the MAKATO_POST_HALT_COMMENT_TEST_FILE
# hook captures all output in a scratch file. Cleans up on exit.
#
# Usage: plugins/makato-orchestrate/shared/post-halt-comment-smoke-tests.sh
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PHC="$REPO_ROOT/plugins/makato-orchestrate/shared/post-halt-comment.sh"

REPO="macatocz/test"
ISSUE=999

TEST_FILE="$(mktemp)"
cleanup() { rm -f "$TEST_FILE"; }
trap cleanup EXIT
cleanup 2>/dev/null || true

pass=0
fail=0

# check <label> <condition-cmd...>  — passes when the command exits 0.
check() {
  local label="$1"; shift
  if "$@"; then
    pass=$((pass + 1)); printf '  PASS %s\n' "$label"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n' "$label"
  fi
}

# Run the helper and capture its comment body output via the test hook.
# Usage: run_phc [args...]
# Sets CAPTURED to the content written to TEST_FILE for this call.
run_phc() {
  # Reset the test file for each scenario.
  : >"$TEST_FILE"
  MAKATO_POST_HALT_COMMENT_TEST_FILE="$TEST_FILE" bash "$PHC" "$@"
  CAPTURED="$(cat "$TEST_FILE")"
}

# ---------------------------------------------------------------------------
# T1: HALT-006 → comment body contains HALT-006 and all three headings
# ---------------------------------------------------------------------------
echo "=== T1: HALT-006 contains HALT-006 and all three structured headings ==="
run_phc HALT-006 "$ISSUE" "$REPO"
check "body contains HALT-006"          grep -q "HALT-006"            <<<"$CAPTURED"
check "body contains '## Needs human review'" grep -q "## Needs human review" <<<"$CAPTURED"
check "body contains '**Reason:**'"     grep -q "\*\*Reason:\*\*"     <<<"$CAPTURED"
check "body contains '**What to fix:**'" grep -q "\*\*What to fix:\*\*" <<<"$CAPTURED"
check "body contains '**Next step:**'" grep -q "\*\*Next step:\*\*"  <<<"$CAPTURED"

# ---------------------------------------------------------------------------
# T2: HALT-003 → comment body contains HALT-003 and CRITICAL-findings recovery text
# ---------------------------------------------------------------------------
echo "=== T2: HALT-003 contains HALT-003 and CRITICAL-findings recovery text ==="
run_phc HALT-003 "$ISSUE" "$REPO"
check "body contains HALT-003"          grep -q "HALT-003"            <<<"$CAPTURED"
check "body contains CRITICAL findings reference" grep -qi "critical\|findings\|build\.jsonl" <<<"$CAPTURED"
check "body contains '**Reason:**'"     grep -q "\*\*Reason:\*\*"     <<<"$CAPTURED"
check "body contains '**What to fix:**'" grep -q "\*\*What to fix:\*\*" <<<"$CAPTURED"

# ---------------------------------------------------------------------------
# T3: MAKATO_POST_HALT_COMMENT_DISABLE=1 → exit 0, no output written
# ---------------------------------------------------------------------------
echo "=== T3: DISABLE env var → exit 0, no output written ==="
: >"$TEST_FILE"
set +e
MAKATO_POST_HALT_COMMENT_DISABLE=1 \
  MAKATO_POST_HALT_COMMENT_TEST_FILE="$TEST_FILE" \
  bash "$PHC" HALT-006 "$ISSUE" "$REPO" >/dev/null 2>&1
RC=$?
set -e
check "exit 0 when disabled"            test "$RC" -eq 0
check "test file is empty when disabled" test ! -s "$TEST_FILE"

# ---------------------------------------------------------------------------
# T4: missing required args → exits non-zero with usage message, no gh call
# ---------------------------------------------------------------------------
echo "=== T4: missing required args → exits non-zero with usage message ==="
set +e
MAKATO_POST_HALT_COMMENT_TEST_FILE="$TEST_FILE" \
  bash "$PHC" 2>/tmp/phc-t4-stderr.tmp
RC=$?
set -e
check "exits non-zero on missing args"  test "$RC" -ne 0
check "stderr contains 'usage'"         grep -qi "usage" /tmp/phc-t4-stderr.tmp
rm -f /tmp/phc-t4-stderr.tmp

# ---------------------------------------------------------------------------
# T5: unknown HALT code → exits 0, generic fallback text present
# ---------------------------------------------------------------------------
echo "=== T5: unknown HALT code → exits 0, generic fallback text ==="
run_phc HALT-UNKNOWN-XYZ "$ISSUE" "$REPO"
check "exits 0 on unknown code"         true  # run_phc would have failed on non-zero
check "body still has '## Needs human review'" grep -q "## Needs human review" <<<"$CAPTURED"
check "body contains HALT-UNKNOWN-XYZ"  grep -q "HALT-UNKNOWN-XYZ"  <<<"$CAPTURED"
check "body contains '**Reason:**'"     grep -q "\*\*Reason:\*\*"    <<<"$CAPTURED"
check "body contains '**What to fix:**'" grep -q "\*\*What to fix:\*\*" <<<"$CAPTURED"

# ---------------------------------------------------------------------------
# T6: --reason and --what-to-fix overrides appear verbatim in the comment body
# ---------------------------------------------------------------------------
echo "=== T6: --reason and --what-to-fix overrides appear verbatim ==="
run_phc HALT-007 "$ISSUE" "$REPO" \
  --reason "custom reason text for T6" \
  --what-to-fix "custom fix instructions for T6"
check "override reason present verbatim"  grep -q "custom reason text for T6"       <<<"$CAPTURED"
check "override what-to-fix present verbatim" grep -q "custom fix instructions for T6" <<<"$CAPTURED"
check "HALT-007 code still present"       grep -q "HALT-007"                        <<<"$CAPTURED"
check "override does not contain built-in reason" \
  bash -c '! grep -q "Token budget exhausted" <<<"'"$CAPTURED"'"'

echo ""
echo "post-halt-comment smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
