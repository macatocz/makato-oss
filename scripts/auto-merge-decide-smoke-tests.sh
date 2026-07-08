#!/usr/bin/env bash
# Smoke tests for scripts/auto-merge-decide.sh — the decision helper
# consumed by .github/workflows/auto-merge-release-please.yml (#181).
# Exits non-zero on first failure. Run from the makato repo root.
#
# Usage: scripts/auto-merge-decide-smoke-tests.sh
#
# Contract summary (documented on the helper itself):
#   auto-merge-decide.sh <check-runs-json-file> <self-job-name>
#     - Reads the file (schema mirrors `gh api repos/…/commits/…/check-runs`)
#     - Filters out any run whose `.name == <self-job-name>` (self-reference)
#     - Emits one of four decisions on stdout:
#         zero-checks-detected  — filtered list is empty (exit 0)
#         merge                 — all runs completed AND all conclusions in
#                                 {success, skipped, neutral}  (exit 0)
#         wait                  — no red runs but at least one still pending
#                                 (exit 2)
#         abort                 — at least one run with conclusion in
#                                 {failure, cancelled, timed_out, action_required}
#                                 (exit 1); failing runs echoed to stderr as
#                                 "  - <name>: <conclusion>"
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HELPER="$REPO_ROOT/scripts/auto-merge-decide.sh"
FX="$REPO_ROOT/scripts/fixtures/auto-merge"
SELF="automerge"

# Small assertion helpers so failure messages point at the failing line clearly.
_assert_decision() {
  local fixture="$1" expected_decision="$2" expected_rc="$3"
  local actual_decision actual_rc
  set +e
  actual_decision="$("$HELPER" "$FX/$fixture" "$SELF" 2>/dev/null)"
  actual_rc=$?
  set -e
  if [[ "$actual_decision" != "$expected_decision" ]]; then
    echo "  ✗ FAIL: $fixture — expected decision '$expected_decision', got '$actual_decision'" >&2
    exit 1
  fi
  if [[ "$actual_rc" != "$expected_rc" ]]; then
    echo "  ✗ FAIL: $fixture — expected exit $expected_rc, got $actual_rc" >&2
    exit 1
  fi
}

echo "=== T1: zero-checks fixture → decision=zero-checks-detected, exit 0 ==="
_assert_decision "zero-checks.json" "zero-checks-detected" 0
echo "  ✓ empty check_runs[] → zero-checks-detected"

echo "=== T2: all-green fixture → decision=merge, exit 0 ==="
_assert_decision "all-green.json" "merge" 0
echo "  ✓ 3× success → merge"

echo "=== T3: one-failing fixture → decision=abort, exit 1, stderr names failing check ==="
set +e
STDERR_T3="$("$HELPER" "$FX/one-failing.json" "$SELF" 2>&1 >/dev/null)"
RC_T3=$?
set -e
[[ $RC_T3 -eq 1 ]] || { echo "  ✗ FAIL: expected exit 1, got $RC_T3"; exit 1; }
DECISION_T3="$("$HELPER" "$FX/one-failing.json" "$SELF" 2>/dev/null || true)"
[[ "$DECISION_T3" == "abort" ]] || { echo "  ✗ FAIL: expected 'abort', got '$DECISION_T3'"; exit 1; }
grep -qE "pr-title.*failure" <<<"$STDERR_T3" || { echo "  ✗ FAIL: stderr missing 'pr-title: failure' — got: $STDERR_T3"; exit 1; }
echo "  ✓ 1 red → abort with failing check name on stderr"

echo "=== T4: mixed-pending fixture → decision=wait, exit 2 ==="
_assert_decision "mixed-pending.json" "wait" 2
echo "  ✓ 1 pending + 1 success → wait"

echo "=== T5: self-reference-only → decision=zero-checks-detected (self filtered out) ==="
_assert_decision "self-reference-only.json" "zero-checks-detected" 0
echo "  ✓ only 'automerge' present → filtered to empty → zero-checks-detected"

echo "=== T5b: self-reference + 3 green non-self → decision=merge (self dropped, others count) ==="
_assert_decision "self-plus-green-non-self.json" "merge" 0
echo "  ✓ self-filter runs BEFORE tally — 3 remaining greens → merge"

echo "=== T6: abort-variants (cancelled/timed_out/action_required) → decision=abort, exit 1 ==="
_assert_decision "abort-variants.json" "abort" 1
# Verify each variant is named in stderr — regression bar for callers that grep on names.
set +e
STDERR_T6="$("$HELPER" "$FX/abort-variants.json" "$SELF" 2>&1 >/dev/null)"
set -e
grep -qE "cancelled-check.*cancelled" <<<"$STDERR_T6" || { echo "  ✗ FAIL: cancelled variant missing from stderr"; exit 1; }
grep -qE "timed-out-check.*timed_out" <<<"$STDERR_T6" || { echo "  ✗ FAIL: timed_out variant missing from stderr"; exit 1; }
grep -qE "action-required-check.*action_required" <<<"$STDERR_T6" || { echo "  ✗ FAIL: action_required variant missing from stderr"; exit 1; }
echo "  ✓ cancelled / timed_out / action_required all classified as abort"

echo "=== T7: neutral + skipped conclusions count as success → decision=merge, exit 0 ==="
_assert_decision "neutral-and-skipped.json" "merge" 0
echo "  ✓ neutral & skipped conclusions treated as green"

echo "=== T8: missing fixture file → helper exits non-zero with a clear diagnostic ==="
set +e
STDERR_T8="$("$HELPER" "$FX/does-not-exist.json" "$SELF" 2>&1)"
RC_T8=$?
set -e
[[ $RC_T8 -ne 0 ]] || { echo "  ✗ FAIL: expected non-zero exit on missing file, got 0"; exit 1; }
grep -qi "no such file\|does not exist\|not found" <<<"$STDERR_T8" || { echo "  ✗ FAIL: diagnostic missing from stderr — got: $STDERR_T8"; exit 1; }
echo "  ✓ missing fixture surfaces a diagnostic"

echo "=== T9: missing self-job-name argument → helper exits non-zero ==="
set +e
"$HELPER" "$FX/all-green.json" 2>/dev/null >/dev/null
RC_T9=$?
set -e
[[ $RC_T9 -ne 0 ]] || { echo "  ✗ FAIL: expected non-zero exit when SELF_JOB_NAME missing"; exit 1; }
echo "  ✓ missing SELF_JOB_NAME argument rejected"

echo
echo "All 10 auto-merge-decide smoke tests passed."
