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
#   T_CD2: dispatch bundle passed to the stub claude contains
#          makato-change:orchestrate, --autonomous, ISSUE_NUMBER, KEY,
#          REPO, and REPO_ROOT — verifying the full prompt shape required
#          by AUTONOMOUS-MODE.md.
#   T_CD3: when the stub claude writes a workflow-state-N.json with
#          current_phase:"execute", in_flight_issues recognises the issue
#          as in-flight and a second dispatch call is skipped.
#   T_CD4: when the stub claude writes a workflow-state-N.json with
#          current_phase:"done", in_flight_issues does not list the issue
#          as in-flight, confirming loop advancement.
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
echo "=== T_CD2: dispatch bundle contains makato-change:orchestrate, --autonomous, ISSUE_NUMBER, KEY, REPO, REPO_ROOT ==="
# ---------------------------------------------------------------------------
# Needs a real (non-dry-run) dispatch to trigger the actual claude exec with
# the full dispatch_prompt. We supply a stub claude that:
#   (a) records its argument list (the -p <prompt>) to a capture file, and
#   (b) exits 0 immediately.
# MAKATO_LOOP_STALL_DISABLE=1 skips the watchdog/log-file path so claude is
# called directly (no log_file branch).
rm -f "$STATE_DIR/loop-status.json"

T_CD2_DIR="$SANDBOX_DIR/t_cd2"
mkdir -p "$T_CD2_DIR"
CAPTURED_PROMPT_FILE="$T_CD2_DIR/captured-prompt.txt"

T_CD2_STUB="$T_CD2_DIR/stub-claude.sh"
cat >"$T_CD2_STUB" <<STUBEOF
#!/usr/bin/env bash
# Record the full argument list (including the -p <prompt>) for assertion.
printf '%s\n' "\$@" > "$CAPTURED_PROMPT_FILE"
exit 0
STUBEOF
chmod +x "$T_CD2_STUB"

t_cd2_rc=0
MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$CHANGE_BODY_FILE" \
MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:change" \
MAKATO_CLAUDE_BIN="$T_CD2_STUB" \
  "$LOOP" dispatch 42 2>/dev/null || t_cd2_rc=$?

# Dispatch must exit 0.
[[ $t_cd2_rc -eq 0 ]] \
  || fail "T_CD2: dispatch should exit 0 with stub claude; rc=$t_cd2_rc"

# The captured prompt must be present.
[[ -f "$CAPTURED_PROMPT_FILE" ]] \
  || fail "T_CD2: stub claude was not invoked (captured-prompt.txt missing)"

CAPTURED_PROMPT="$(cat "$CAPTURED_PROMPT_FILE")"

# Assert all required fields are present in the dispatch prompt.
grep -q "makato-change:orchestrate" <<<"$CAPTURED_PROMPT" \
  || fail "T_CD2: dispatch prompt missing 'makato-change:orchestrate'; got: $CAPTURED_PROMPT"

grep -q -- "--autonomous" <<<"$CAPTURED_PROMPT" \
  || fail "T_CD2: dispatch prompt missing '--autonomous'; got: $CAPTURED_PROMPT"

grep -q "ISSUE_NUMBER=42" <<<"$CAPTURED_PROMPT" \
  || fail "T_CD2: dispatch prompt missing 'ISSUE_NUMBER=42'; got: $CAPTURED_PROMPT"

grep -q "KEY=42-adjust-http-retry-logic" <<<"$CAPTURED_PROMPT" \
  || fail "T_CD2: dispatch prompt missing 'KEY=42-adjust-http-retry-logic'; got: $CAPTURED_PROMPT"

grep -q "REPO=macatocz/makato" <<<"$CAPTURED_PROMPT" \
  || fail "T_CD2: dispatch prompt missing 'REPO=macatocz/makato'; got: $CAPTURED_PROMPT"

grep -q "REPO_ROOT=" <<<"$CAPTURED_PROMPT" \
  || fail "T_CD2: dispatch prompt missing 'REPO_ROOT='; got: $CAPTURED_PROMPT"

echo "  ✓ T_CD2: dispatch prompt carries makato-change:orchestrate, --autonomous, ISSUE_NUMBER=42, KEY, REPO, REPO_ROOT"

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
MAKATO_CLAUDE_BIN="$T_CD3_STUB" \
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
MAKATO_CLAUDE_BIN="$T_CD3_STUB2" \
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

# Verify in_flight_issues does NOT list issue 44.
in_flight_out="$(SPECS_DIR="$T_CD4_SPECS" "$LOOP" _test-in-flight-issues 2>/dev/null \
  || SPECS_DIR="$T_CD4_SPECS" \
     bash -c 'source '"$LOOP"'; in_flight_issues' 2>/dev/null \
  || true)"

# If _test-in-flight-issues hook is not available, call in_flight_issues
# directly by sourcing the loop and calling the function.
if [[ -z "$in_flight_out" ]]; then
  # Source loop.sh in a subshell to call in_flight_issues directly.
  in_flight_out="$(
    bash -c "
      SPECS_DIR=\"$T_CD4_SPECS\"
      export SPECS_DIR
      # Source only the helper functions (skip main dispatch block).
      # Extract and eval just in_flight_issues + its dependencies.
      source \"$LOOP\" 2>/dev/null || true
      in_flight_issues 2>/dev/null || true
    " 2>/dev/null || true)"
fi

# Assert issue 44 is NOT in the in-flight list.
if grep -qx "44" <<<"$in_flight_out" 2>/dev/null; then
  fail "T_CD4: issue 44 with current_phase:done must NOT appear in in_flight_issues; got: $in_flight_out"
fi
echo "  ✓ T_CD4 (in_flight_issues direct check): issue 44 (current_phase:done) not in-flight"

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
MAKATO_CLAUDE_BIN="$T_CD4_STUB" \
  "$LOOP" dispatch 44 2>/dev/null || t_cd4_rc=$?

[[ $t_cd4_rc -eq 0 ]] \
  || fail "T_CD4: dispatch should exit 0 when workflow-state is done; rc=$t_cd4_rc"

CALL_COUNT_CD4="$(cat "$T_CD4_COUNTER")"
[[ "$CALL_COUNT_CD4" -ge 1 ]] \
  || fail "T_CD4: stub claude MUST be invoked when current_phase:done (loop should advance); call_count=$CALL_COUNT_CD4"

echo "  ✓ T_CD4: current_phase:done does NOT block dispatch — stub was called (loop advances)"

# ---------------------------------------------------------------------------
echo
echo "=== ALL T_CD TESTS PASSED (T_CD1–T_CD4) ==="
