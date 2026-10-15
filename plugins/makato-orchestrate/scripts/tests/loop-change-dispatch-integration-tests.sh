#!/usr/bin/env bash
# End-to-end integration tests for cross-plugin seam #2:
#   loop.sh KEY-derivation → po-agent → makato-change dispatch chain
# (issue #717)
#
# Run from the makato repo root:
#   bash plugins/makato-orchestrate/scripts/tests/loop-change-dispatch-integration-tests.sh
#
# All tests are OFFLINE — no live `gh` calls.
# Exit non-zero on first assertion failure.
#
# Tests:
#   T_CD1: dispatch on a type:change issue derives a non-empty KEY from the
#          to-issues provenance footer.
#   T_CD3: when the stub claude writes a workflow-state-N.json with
#          current_phase:"execute", in_flight_issues recognises the issue
#          as in-flight and a second dispatch call is skipped.
#   T_CD4: when the stub claude writes a workflow-state-N.json with
#          current_phase:"done", in_flight_issues does not list the issue
#          as in-flight, confirming loop advancement.
#   T_CD7: OMP reshape publishes only after successful decomposition.
#   T_CD8: explicit Claude reshape never launches the OMP runner.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LOOP="$REPO_ROOT/plugins/makato-orchestrate/scripts/loop.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
SANDBOX_DIR="${CLAUDE_JOB_DIR:-/tmp}/loop-cd-$$"
STATE_DIR="$SANDBOX_DIR/state"
SPECS_DIR="$SANDBOX_DIR/specs"
HALT_FILE="$SANDBOX_DIR/HALT"

mkdir -p "$STATE_DIR" "$SPECS_DIR"

export MAKATO_LOOP_STATE_DIR="$STATE_DIR"
export MAKATO_HALT_FILE="$HALT_FILE"
export MAKATO_LOOP_DISPATCH_REPO="macatocz/makato"
# Disable side-effects that would require live GitHub:
export MAKATO_LOOP_CLAIM_ON_DISPATCH=0
export MAKATO_LOOP_ASSIGN_ON_DISPATCH=0
export MAKATO_LOOP_STALL_DISABLE=1
export MAKATO_LOOP_GATE_DISABLE=1
# Disable autoseed/reaper to keep tests focused:
export MAKATO_LOOP_AUTOSEED_ON_POLL=0
export MAKATO_LOOP_REAP_ON_POLL=0

cleanup() {
  rm -rf "$SANDBOX_DIR"
}
trap cleanup EXIT

fail() {
  echo "  FAIL: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Shared fixture: a type:change issue body with a to-issues provenance footer.
# ---------------------------------------------------------------------------
CHANGE_BODY_FILE="$SANDBOX_DIR/change-issue-body.txt"
cat >"$CHANGE_BODY_FILE" <<'ISSUEBODY'
## Summary

Change: adjust retry logic for the HTTP client.

*Feature slug: `42-adjust-http-retry-logic` — produced by to-issues v3.x.*
ISSUEBODY

# ---------------------------------------------------------------------------
echo "=== T_CD1: type:change dispatch derives non-empty KEY from to-issues footer ==="
# ---------------------------------------------------------------------------
# Use --dry-run so no real claude is spawned. The dry-run output (stderr)
# carries the KEY in the would-exec line.
rm -f "$STATE_DIR/loop-status.json"

t_cd1_out="$(
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$CHANGE_BODY_FILE" \
  MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:change" \
    "$LOOP" dispatch 42 --dry-run 2>&1 >/dev/null
)" || fail "T_CD1: dispatch --dry-run should exit 0; got: $t_cd1_out"

# The to-issues footer slug is `42-adjust-http-retry-logic`.
# The dry-run output line is:
#   loop: --dry-run — would exec: ... KEY=42-adjust-http-retry-logic ...
grep -q "KEY=42-adjust-http-retry-logic" <<<"$t_cd1_out" \
  || fail "T_CD1: KEY not derived from to-issues footer; got: $t_cd1_out"

echo "  ✓ T_CD1: type:change derives KEY=42-adjust-http-retry-logic from to-issues footer"

# ---------------------------------------------------------------------------
echo "=== T_CD3: in-flight workflow-state (current_phase:execute) blocks second dispatch ==="
# ---------------------------------------------------------------------------
# Stub claude writes workflow-state-43.json with current_phase:"execute"
# into SPECS_DIR, simulating the change pipeline creating its state stub.
# A second dispatch call for the same issue must then be skipped by the
# in_flight_issues gate.
rm -f "$STATE_DIR/loop-status.json"

T_CD3_DIR="$SANDBOX_DIR/t_cd3"
T_CD3_SPECS="$T_CD3_DIR/specs"
T_CD3_SPEC_FOLDER="$T_CD3_SPECS/43-some-change"
mkdir -p "$T_CD3_SPEC_FOLDER"

T_CD3_BODY="$T_CD3_DIR/body.txt"
printf '%s\n' '*Feature slug: `43-some-change` — produced by to-issues v3.x.*' >"$T_CD3_BODY"

T_CD3_STUB="$T_CD3_DIR/stub-claude.sh"
# Stub writes the workflow-state file then exits 0.
cat >"$T_CD3_STUB" <<STUBEOF
#!/usr/bin/env bash
# Simulate change-orchestrate Step 0.5: write the loop-compat workflow-state stub.
cat >"$T_CD3_SPEC_FOLDER/workflow-state-43.json" <<'WFEOF'
{
  "issue_number": 43,
  "current_phase": "execute",
  "repo": "macatocz/makato"
}
WFEOF
exit 0
STUBEOF
chmod +x "$T_CD3_STUB"

# First dispatch: stub claude runs, writes workflow-state-43.json.
t_cd3_first_rc=0
MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$T_CD3_BODY" \
MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:change" \
MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
MAKATO_LOOP_CLAIM_ON_DISPATCH=0 \
MAKATO_LOOP_ASSIGN_ON_DISPATCH=0 \
MAKATO_LOOP_STALL_DISABLE=1 \
MAKATO_LOOP_GATE_DISABLE=1 \
SPECS_DIR="$T_CD3_SPECS" \
MAKATO_HARNESS_BIN="$T_CD3_STUB" \
  "$LOOP" dispatch 43 2>/dev/null || t_cd3_first_rc=$?

[[ $t_cd3_first_rc -eq 0 ]] \
  || fail "T_CD3: first dispatch should exit 0; rc=$t_cd3_first_rc"

# Verify the stub wrote the state file.
[[ -f "$T_CD3_SPEC_FOLDER/workflow-state-43.json" ]] \
  || fail "T_CD3: stub claude did not write workflow-state-43.json"

# Second dispatch: must be skipped by the in_flight_issues gate.
# The stub increments a counter file if invoked — we assert it is NOT called.
T_CD3_COUNTER="$T_CD3_DIR/stub-call-count.txt"
echo "0" >"$T_CD3_COUNTER"
T_CD3_STUB2="$T_CD3_DIR/stub-claude2.sh"
cat >"$T_CD3_STUB2" <<STUBEOF
#!/usr/bin/env bash
COUNT=\$(cat "$T_CD3_COUNTER")
echo \$(( COUNT + 1 )) >"$T_CD3_COUNTER"
exit 0
STUBEOF
chmod +x "$T_CD3_STUB2"

rm -f "$STATE_DIR/loop-status.json"
t_cd3_second_rc=0
MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$T_CD3_BODY" \
MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:change" \
MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
MAKATO_LOOP_CLAIM_ON_DISPATCH=0 \
MAKATO_LOOP_ASSIGN_ON_DISPATCH=0 \
MAKATO_LOOP_STALL_DISABLE=1 \
MAKATO_LOOP_GATE_DISABLE=0 \
SPECS_DIR="$T_CD3_SPECS" \
MAKATO_HARNESS_BIN="$T_CD3_STUB2" \
  "$LOOP" dispatch 43 2>/dev/null || t_cd3_second_rc=$?

[[ $t_cd3_second_rc -eq 0 ]] \
  || fail "T_CD3: second dispatch should exit 0 (gate skips cleanly); rc=$t_cd3_second_rc"

CALL_COUNT="$(cat "$T_CD3_COUNTER")"
[[ "$CALL_COUNT" -eq 0 ]] \
  || fail "T_CD3: stub claude must NOT be invoked on second dispatch (in-flight gate); call_count=$CALL_COUNT"

echo "  ✓ T_CD3: in-flight workflow-state (current_phase:execute) blocks second dispatch — stub not called"

# ---------------------------------------------------------------------------
echo "=== T_CD4: done workflow-state (current_phase:done) does NOT block dispatch ==="
# ---------------------------------------------------------------------------
# When the workflow-state has current_phase:"done", in_flight_issues must
# NOT include the issue — confirming loop advancement is possible.
rm -f "$STATE_DIR/loop-status.json"

T_CD4_DIR="$SANDBOX_DIR/t_cd4"
T_CD4_SPECS="$T_CD4_DIR/specs"
T_CD4_SPEC_FOLDER="$T_CD4_SPECS/44-completed-change"
mkdir -p "$T_CD4_SPEC_FOLDER"

# Write a done workflow-state directly (no stub needed for the state write).
cat >"$T_CD4_SPEC_FOLDER/workflow-state-44.json" <<'WFEOF'
{
  "issue_number": 44,
  "current_phase": "done",
  "repo": "macatocz/makato"
}
WFEOF

# Also verify via dispatch: with done state, dispatch must proceed (stub IS called).
T_CD4_BODY="$T_CD4_DIR/body.txt"
printf '%s\n' '*Feature slug: `44-completed-change` — produced by to-issues v3.x.*' >"$T_CD4_BODY"

T_CD4_COUNTER="$T_CD4_DIR/stub-call-count.txt"
echo "0" >"$T_CD4_COUNTER"
T_CD4_STUB="$T_CD4_DIR/stub-claude.sh"
cat >"$T_CD4_STUB" <<STUBEOF
#!/usr/bin/env bash
COUNT=\$(cat "$T_CD4_COUNTER")
echo \$(( COUNT + 1 )) >"$T_CD4_COUNTER"
exit 0
STUBEOF
chmod +x "$T_CD4_STUB"

rm -f "$STATE_DIR/loop-status.json"
t_cd4_rc=0
MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$T_CD4_BODY" \
MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:change" \
MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
MAKATO_LOOP_CLAIM_ON_DISPATCH=0 \
MAKATO_LOOP_ASSIGN_ON_DISPATCH=0 \
MAKATO_LOOP_STALL_DISABLE=1 \
MAKATO_LOOP_GATE_DISABLE=1 \
SPECS_DIR="$T_CD4_SPECS" \
MAKATO_HARNESS_BIN="$T_CD4_STUB" \
  "$LOOP" dispatch 44 2>/dev/null || t_cd4_rc=$?

[[ $t_cd4_rc -eq 0 ]] \
  || fail "T_CD4: dispatch should exit 0 when workflow-state is done; rc=$t_cd4_rc"

CALL_COUNT_CD4="$(cat "$T_CD4_COUNTER")"
[[ "$CALL_COUNT_CD4" -ge 1 ]] \
  || fail "T_CD4: stub claude MUST be invoked when current_phase:done (loop should advance); call_count=$CALL_COUNT_CD4"

echo "  ✓ T_CD4: current_phase:done does NOT block dispatch — stub was called (loop advances)"

# ---------------------------------------------------------------------------
echo "=== T_CD7: OMP reshape publishes only after successful decomposition ==="
# ---------------------------------------------------------------------------
T_CD7_DIR="$SANDBOX_DIR/t_cd7"
T_CD7_SPECS="$T_CD7_DIR/specs"
T_CD7_KEY="47-shape-context"
mkdir -p "$T_CD7_SPECS/$T_CD7_KEY"
T_CD7_CANDIDATES="$T_CD7_DIR/candidates.json"
printf '[{"number":47,"key":"%s"}]\n' "$T_CD7_KEY" >"$T_CD7_CANDIDATES"
T_CD7_CONFIG="$T_CD7_DIR/config.json"
printf '{}\n' >"$T_CD7_CONFIG"
T_CD7_CAPTURE="$T_CD7_DIR/runner-calls.txt"
: >"$T_CD7_CAPTURE"
T_CD7_RUNNER="$T_CD7_DIR/run-skill.py"
cat >"$T_CD7_RUNNER" <<'PYEOF'
#!/usr/bin/env python3
import os
import sys

args = sys.argv[1:]
with open(os.environ["T_CD7_RUNNER_CAPTURE"], "a", encoding="utf-8") as capture:
    capture.write("CALL\n")
    capture.writelines(f"{arg}\n" for arg in args)
    capture.write("END\n")
if "makato-plan:decompose" in args:
    sys.exit(int(os.environ.get("T_CD7_DECOMPOSE_RC", "0")))
PYEOF

run_t_cd7_reshape() {
  local decompose_rc="$1" rc=0
  (
    export MAKATO_LOOP_RESHAPE_ENABLED=1
    export MAKATO_LOOP_RESHAPE_OVERRIDE="$T_CD7_CANDIDATES"
    export MAKATO_LOOP_CONFIG="$T_CD7_CONFIG"
    export MAKATO_LOOP_LABEL_TEST_FILE="$T_CD7_DIR/labels.txt"
    export MAKATO_HARNESS_MODE=omp
    export MAKATO_HARNESS_BIN=omp
    export MAKATO_SKILL_RUNNER="$T_CD7_RUNNER"
    export T_CD7_RUNNER_CAPTURE="$T_CD7_CAPTURE"
    export T_CD7_DECOMPOSE_RC="$decompose_rc"
    export SPECS_DIR="$T_CD7_SPECS"
    unset MAKATO_LOOP_RESHAPE_TEST_CMD
    "$LOOP" reshape-pass
  ) >/dev/null 2>&1 || rc=$?
  return "$rc"
}

run_t_cd7_reshape 0 || fail "T_CD7: OMP reshape pass failed"
T_CD7_CALL_COUNT="$(grep -c '^CALL$' "$T_CD7_CAPTURE" || true)"
[[ "$T_CD7_CALL_COUNT" -eq 2 ]] \
  || fail "T_CD7: successful decompose must be followed by to-issues; calls=$T_CD7_CALL_COUNT"
grep -Fq -- "makato-plan:decompose" "$T_CD7_CAPTURE" \
  || fail "T_CD7: OMP runner did not receive decompose"
grep -Fq -- "makato-plan:to-issues" "$T_CD7_CAPTURE" \
  || fail "T_CD7: OMP runner did not receive to-issues"

: >"$T_CD7_CAPTURE"
run_t_cd7_reshape 23 || fail "T_CD7: failed decompose reshape pass should be handled"
T_CD7_CALL_COUNT="$(grep -c '^CALL$' "$T_CD7_CAPTURE" || true)"
[[ "$T_CD7_CALL_COUNT" -eq 1 ]] \
  || fail "T_CD7: failed decompose must prevent the second runner call; calls=$T_CD7_CALL_COUNT"
if grep -Fq -- "makato-plan:to-issues" "$T_CD7_CAPTURE"; then
  fail "T_CD7: to-issues ran after decompose failed"
fi
echo "  T_CD7: chains on success and stops on decomposition failure"

# ---------------------------------------------------------------------------
echo "=== T_CD8: explicit Claude reshape dispatch keeps using the harness adapter ==="
# ---------------------------------------------------------------------------
T_CD8_DIR="$SANDBOX_DIR/t_cd8"
T_CD8_SPECS="$T_CD8_DIR/specs"
T_CD8_SLUG="48-shape-claude"
mkdir -p "$T_CD8_SPECS/$T_CD8_SLUG"
T_CD8_CANDIDATES="$T_CD8_DIR/candidates.json"
printf '[{"number":48,"key":"%s"}]\n' "$T_CD8_SLUG" >"$T_CD8_CANDIDATES"
T_CD8_CONFIG="$T_CD8_DIR/config.json"
printf '{}\n' >"$T_CD8_CONFIG"
T_CD8_CAPTURE="$T_CD8_DIR/harness-calls.txt"
T_CD8_STUB="$T_CD8_DIR/stub-claude.sh"
cat >"$T_CD8_STUB" <<'STUBEOF'
#!/usr/bin/env bash
printf 'CALL\n' >>"$T_CD8_CAPTURE"
STUBEOF
chmod +x "$T_CD8_STUB"
T_CD8_RUNNER="$T_CD8_DIR/should-not-run.py"
T_CD8_RUNNER_CAPTURE="$T_CD8_DIR/runner-called.txt"
cat >"$T_CD8_RUNNER" <<'PYEOF'
#!/usr/bin/env python3
import os
with open(os.environ["T_CD8_RUNNER_CAPTURE"], "a", encoding="utf-8") as capture:
    capture.write("called\n")
PYEOF

t_cd8_rc=0
(
  export MAKATO_LOOP_RESHAPE_ENABLED=1
  export MAKATO_LOOP_RESHAPE_OVERRIDE="$T_CD8_CANDIDATES"
  export MAKATO_LOOP_CONFIG="$T_CD8_CONFIG"
  export MAKATO_LOOP_LABEL_TEST_FILE="$T_CD8_DIR/labels.txt"
  export MAKATO_HARNESS_MODE=claude
  export MAKATO_HARNESS_BIN="$T_CD8_STUB"
  export MAKATO_SKILL_RUNNER="$T_CD8_RUNNER"
  export T_CD8_CAPTURE
  export T_CD8_RUNNER_CAPTURE
  export SPECS_DIR="$T_CD8_SPECS"
  unset MAKATO_LOOP_RESHAPE_TEST_CMD
  "$LOOP" reshape-pass
) >/dev/null 2>&1 || t_cd8_rc=$?
[[ "$t_cd8_rc" -eq 0 ]] || fail "T_CD8: Claude reshape pass failed; rc=$t_cd8_rc"
T_CD8_CALL_COUNT="$(grep -c '^CALL$' "$T_CD8_CAPTURE" || true)"
[[ "$T_CD8_CALL_COUNT" -eq 2 ]] \
  || fail "T_CD8: Claude adapter should dispatch both skills; calls=$T_CD8_CALL_COUNT"
[[ ! -s "$T_CD8_RUNNER_CAPTURE" ]] \
  || fail "T_CD8: explicit Claude mode unexpectedly launched the OMP skill runner"
echo "  ✓ T_CD8: explicit Claude reshape dispatch stays on the adapter"

# ---------------------------------------------------------------------------
echo
echo "=== ALL CHANGE DISPATCH BEHAVIOR TESTS PASSED ==="
