#!/usr/bin/env bash
# Smoke tests for workflow-state.sh. Run from the makato repo root.
# Exits non-zero on first failure. Cleans up its sandbox on success.
#
# Usage: plugins/makato-orchestrate/skills/workflow-state/references/smoke-tests.sh
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WS="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"
KEY="gap-003-smoke-test"
SANDBOX="$REPO_ROOT/specs/${KEY}"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

cleanup
mkdir -p "$SANDBOX"

echo "=== T1: schema is valid JSON ==="
python3 -m json.tool \
  "$REPO_ROOT/plugins/makato-orchestrate/skills/workflow-state/references/workflow-state.schema.json" \
  > /dev/null
echo "  ✓ schema parses"

echo "=== T2: init creates a valid file ==="
"$WS" init "$KEY" macatocz/test feat/gap-003 26
test -f "$SANDBOX/workflow-state.json"
echo "  ✓ workflow-state.json exists"

echo "=== T3: init refuses duplicate ==="
if "$WS" init "$KEY" macatocz/test feat/gap-003 26 2>/dev/null; then
  echo "  ✗ FAIL: expected non-zero exit"
  exit 1
fi
echo "  ✓ duplicate refused"

echo "=== T4: read returns the file ==="
"$WS" read "$KEY" | jq -e '.repo == "macatocz/test"' > /dev/null
echo "  ✓ repo field set"

echo "=== T5: read on missing key returns {} ==="
"$WS" read "no-such-key-$$" | jq -e '. == {}' > /dev/null
echo "  ✓ missing returns {}"

echo "=== T6: patch updates field AND updated_at advances ==="
BEFORE=$("$WS" read "$KEY" | jq -r '.updated_at')
sleep 1
"$WS" patch "$KEY" .current_phase '"implement"'
AFTER=$("$WS" read "$KEY" | jq -r '.updated_at')
[[ "$AFTER" > "$BEFORE" ]] || { echo "  ✗ FAIL: updated_at did not advance"; exit 1; }
"$WS" read "$KEY" | jq -e '.current_phase == "implement"' > /dev/null
echo "  ✓ field set, timestamp advanced"

echo "=== T7: patch supports indexed array path ==="
"$WS" write "$KEY" \
  "$("$WS" read "$KEY" | jq '.sub_tasks = [{id:1,description:"Add model",status:"pending",phase:"tdd",agent_result:null}]')"
"$WS" patch "$KEY" '.sub_tasks[0].status' '"complete"'
"$WS" read "$KEY" | jq -e '.sub_tasks[0].status == "complete"' > /dev/null
echo "  ✓ indexed patch works"

echo "=== T8: append-lesson grows the array (GAP-015 / #37 typed schema) ==="
"$WS" append-lesson "$KEY" 0 ci_failure "tracer bullet essential" "src/foo.py" "tests/test_foo.py"
"$WS" read "$KEY" | jq -e '.lessons_learned | length == 1' > /dev/null
"$WS" read "$KEY" | jq -e '.lessons_learned[0].description == "tracer bullet essential"' > /dev/null
"$WS" read "$KEY" | jq -e '.lessons_learned[0].trigger == "ci_failure"' > /dev/null
"$WS" read "$KEY" | jq -e '.lessons_learned[0].cycle == 0' > /dev/null
"$WS" read "$KEY" | jq -e '.lessons_learned[0].files_affected == ["src/foo.py","tests/test_foo.py"]' > /dev/null
"$WS" read "$KEY" | jq -e '.lessons_learned[0].ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' > /dev/null
echo "  ✓ lesson appended with ts/cycle/trigger/description/files_affected"

echo "=== T9: invalid write halts ==="
if "$WS" write "$KEY" '{"broken":true}' 2>/dev/null; then
  echo "  ✗ FAIL: expected non-zero exit"
  exit 1
fi
echo "  ✓ schema validation halted invalid write"

echo "=== T10: GAP-004 fields populated at init with safe defaults ==="
"$WS" read "$KEY" | jq -e '.session_count == 0' > /dev/null
"$WS" read "$KEY" | jq -e '.session_summary == null' > /dev/null
"$WS" read "$KEY" | jq -e '.handoff_reason == null' > /dev/null
"$WS" read "$KEY" | jq -e '.restart_failed == false' > /dev/null
"$WS" read "$KEY" | jq -e '.context_warn_tokens >= 1' > /dev/null
echo "  ✓ session_count / session_summary / handoff_reason / restart_failed / context_warn_tokens"

echo "=== T11: handoff_reason rejects values outside the enum ==="
if "$WS" patch "$KEY" .handoff_reason '"not_a_real_reason"' 2>/dev/null; then
  echo "  ✗ FAIL: expected non-zero exit"
  exit 1
fi
echo "  ✓ enum violation halted"

echo "=== T12: handoff_reason accepts the canonical value ==="
"$WS" patch "$KEY" .handoff_reason '"context_ceiling"'
"$WS" read "$KEY" | jq -e '.handoff_reason == "context_ceiling"' > /dev/null
echo "  ✓ context_ceiling persisted"

echo "=== T13: MAKATO_CONTEXT_WARN_TOKENS env override at init ==="
KEY2="gap-003-smoke-test-ctx"
SANDBOX2="$REPO_ROOT/specs/${KEY2}"
rm -rf "$SANDBOX2"
mkdir -p "$SANDBOX2"
MAKATO_CONTEXT_WARN_TOKENS=180000 "$WS" init "$KEY2" macatocz/test feat/gap-003 26
"$WS" read "$KEY2" | jq -e '.context_warn_tokens == 180000' > /dev/null
rm -rf "$SANDBOX2"
echo "  ✓ env override honored"

echo "=== T14: GAP-017 worktree fields seeded at init ==="
"$WS" read "$KEY" | jq -e '.worktree_path == null' > /dev/null
"$WS" read "$KEY" | jq -e '.worktree_retained == false' > /dev/null
"$WS" read "$KEY" | jq -e '.worktree_retain_reason == null' > /dev/null
echo "  ✓ worktree_path / worktree_retained / worktree_retain_reason"

echo "=== T15: worktree_retained rejects non-boolean values ==="
if "$WS" patch "$KEY" .worktree_retained '"yes"' 2>/dev/null; then
  echo "  ✗ FAIL: expected non-zero exit"
  exit 1
fi
echo "  ✓ schema rejects non-boolean"

echo "=== T16: append-lesson rejects invalid trigger (GAP-015 / #37 enum) ==="
if "$WS" append-lesson "$KEY" 0 not_a_trigger "anything" 2>/dev/null; then
  echo "  ✗ FAIL: expected non-zero exit"
  exit 1
fi
echo "  ✓ enum violation halts"

echo "=== T17: append-lesson rejects non-integer cycle ==="
if "$WS" append-lesson "$KEY" "abc" ci_failure "anything" 2>/dev/null; then
  echo "  ✗ FAIL: expected non-zero exit"
  exit 1
fi
echo "  ✓ non-integer cycle halts"

echo "=== T18: append-lesson truncates description at 200 chars (GAP-015 / #37 AC) ==="
LONG_DESC="$(printf 'x%.0s' {1..400})"
"$WS" append-lesson "$KEY" 1 halt "$LONG_DESC"
ACTUAL_LEN=$("$WS" read "$KEY" | jq -r '.lessons_learned[-1].description | length')
[[ "$ACTUAL_LEN" -le 200 ]] || { echo "  ✗ FAIL: description was $ACTUAL_LEN chars, expected ≤ 200"; exit 1; }
"$WS" read "$KEY" | jq -e '.lessons_learned[-1].description | endswith("…")' > /dev/null
echo "  ✓ description truncated to ≤ 200 chars with '…' suffix"

echo "=== T19: append-lesson accepts zero files_affected (variadic optional) ==="
"$WS" append-lesson "$KEY" 1 sensor "ruff F401 unused import"
"$WS" read "$KEY" | jq -e '.lessons_learned[-1].files_affected == []' > /dev/null
echo "  ✓ files_affected empty array when no positional file args"

echo "=== T20: append-lesson accepts merge_conflict trigger (resolve-pr-conflict path) ==="
"$WS" append-lesson "$KEY" 2 merge_conflict "irreconcilable conflict after rebase + merge -X ours" "a.py" "b.py"
"$WS" read "$KEY" | jq -e '.lessons_learned[-1].trigger == "merge_conflict"' > /dev/null
"$WS" read "$KEY" | jq -e '.lessons_learned[-1].files_affected == ["a.py","b.py"]' > /dev/null
echo "  ✓ merge_conflict trigger persisted"

echo "=== T21: patch preserves lessons_learned[] (GAP-015 / #37 AC5) ==="
BEFORE_LEN=$("$WS" read "$KEY" | jq '.lessons_learned | length')
"$WS" patch "$KEY" .current_phase '"pr"'
AFTER_LEN=$("$WS" read "$KEY" | jq '.lessons_learned | length')
[[ "$AFTER_LEN" == "$BEFORE_LEN" ]] || { echo "  ✗ FAIL: lessons clobbered ($BEFORE_LEN → $AFTER_LEN)"; exit 1; }
echo "  ✓ patch preserves $AFTER_LEN existing lessons"

echo "=== T22: recall-lessons returns top-N most recent across specs/ (GAP-015 / #37 AC3) ==="
# Seed a sibling spec for the same repo and a different one to verify filtering.
KEY3="gap-003-smoke-test-sibling"
SANDBOX3="$REPO_ROOT/specs/${KEY3}"
KEY4="gap-003-smoke-test-other-repo"
SANDBOX4="$REPO_ROOT/specs/${KEY4}"
rm -rf "$SANDBOX3" "$SANDBOX4"
mkdir -p "$SANDBOX3" "$SANDBOX4"
"$WS" init "$KEY3" macatocz/test feat/gap-003-sib 27
"$WS" append-lesson "$KEY3" 0 halt "sibling repo lesson 1" "src/x.py"
"$WS" append-lesson "$KEY3" 1 review_comment "sibling repo lesson 2" "src/y.py"
"$WS" init "$KEY4" macatocz/other-repo feat/other 28
"$WS" append-lesson "$KEY4" 0 ci_failure "OTHER repo lesson — must be filtered out"

# Top-3 across matching repo should return newest-first lessons only.
RECALLED=$("$WS" recall-lessons macatocz/test 3)
echo "$RECALLED" | jq -e 'length == 3' > /dev/null
echo "$RECALLED" | jq -e 'all(.[]; (.description | contains("OTHER repo") | not))' > /dev/null
# Highest cycle should sort first; tests above seeded `cycle=2` (T20) into the
# primary key. Assertion is `>= 2` so a future test adding higher-cycle lessons
# before T22 does not break the test — recall must still surface the newest.
echo "$RECALLED" | jq -e '.[0].cycle >= 2' > /dev/null
echo "  ✓ recall-lessons filters by repo and returns top-3 newest-first"

# Cleanup the seeded sandboxes (the EXIT trap only removes the primary SANDBOX).
rm -rf "$SANDBOX3" "$SANDBOX4"

echo "=== T23: recall-lessons returns [] when no matching repo ==="
"$WS" recall-lessons macatocz/nonexistent-repo 3 | jq -e '. == []' > /dev/null
echo "  ✓ empty result for unknown repo"

echo "=== T24: summarise-lessons writes specs/<key>-*/lessons-YYYYMMDD.md (AC4) ==="
LESSONS_MD="$("$WS" summarise-lessons "$KEY")"
test -f "$LESSONS_MD" || { echo "  ✗ FAIL: $LESSONS_MD not written"; exit 1; }
grep -q "# Lessons learned" "$LESSONS_MD" || { echo "  ✗ FAIL: header missing"; exit 1; }
grep -q "macatocz/test" "$LESSONS_MD" || { echo "  ✗ FAIL: repo missing"; exit 1; }
grep -q "merge_conflict" "$LESSONS_MD" || { echo "  ✗ FAIL: most recent trigger missing"; exit 1; }
echo "  ✓ markdown summary contains header, repo, and lesson triggers"

echo "=== T25: summarise-lessons is idempotent on re-run (same-day overwrite) ==="
"$WS" summarise-lessons "$KEY" > /dev/null
"$WS" summarise-lessons "$KEY" > /dev/null
COUNT=$(find "$SANDBOX" -name "lessons-*.md" | wc -l | tr -d ' ')
[[ "$COUNT" == "1" ]] || { echo "  ✗ FAIL: expected 1 lessons-*.md file, got $COUNT"; exit 1; }
echo "  ✓ one lessons-YYYYMMDD.md after re-run"

echo "=== T26: GAP-016 merge_conflict_cycles seeded at init with default 0 ==="
"$WS" read "$KEY" | jq -e '.merge_conflict_cycles == 0' > /dev/null
echo "  ✓ merge_conflict_cycles default 0"

echo "=== T27: merge_conflict_cycles accepts non-negative integer patch ==="
"$WS" patch "$KEY" .merge_conflict_cycles '2'
"$WS" read "$KEY" | jq -e '.merge_conflict_cycles == 2' > /dev/null
echo "  ✓ patch persists merge_conflict_cycles = 2"

echo "=== T28: merge_conflict_cycles rejects negative values (schema minimum 0) ==="
if "$WS" patch "$KEY" .merge_conflict_cycles '-1' 2>/dev/null; then
  echo "  ✗ FAIL: expected non-zero exit"
  exit 1
fi
echo "  ✓ schema rejects negative integer"

# -- T29..T34: append-halt subcommand (#118) ------------------------------

echo "=== T29: append-halt with valid code + object data appends one entry ==="
BEFORE_LEN=$("$WS" read "$KEY" | jq '.halt_audit | length')
"$WS" append-halt "$KEY" HALT-007 '{"reason":"test","budget":100000}'
AFTER_LEN=$("$WS" read "$KEY" | jq '.halt_audit | length')
if [[ "$AFTER_LEN" -ne $((BEFORE_LEN + 1)) ]]; then
  echo "  ✗ expected length $((BEFORE_LEN + 1)), got $AFTER_LEN" >&2
  exit 1
fi
echo "  ✓ append-halt appended one entry"

echo "=== T30: append-halt entry has canonical {code, ts, data} shape ==="
"$WS" read "$KEY" | jq -e '.halt_audit[-1] | (.code == "HALT-007") and (.ts | type == "string") and (.data | type == "object") and (.data.reason == "test") and (.data.budget == 100000)' > /dev/null
echo "  ✓ entry shape verified"

echo "=== T31: append-halt accepts HALT-007B (suffixed variant) ==="
"$WS" append-halt "$KEY" HALT-007B '{"session":2}'
"$WS" read "$KEY" | jq -e '.halt_audit[-1].code == "HALT-007B"' > /dev/null
echo "  ✓ HALT-007B accepted"

echo "=== T32: append-halt accepts HALT-STRUCTURAL ==="
"$WS" append-halt "$KEY" HALT-STRUCTURAL '{}'
"$WS" read "$KEY" | jq -e '.halt_audit[-1].code == "HALT-STRUCTURAL"' > /dev/null
echo "  ✓ HALT-STRUCTURAL accepted"

echo "=== T33: append-halt rejects malformed code (BAD-CODE) ==="
if "$WS" append-halt "$KEY" BAD-CODE '{}' 2>/dev/null; then
  echo "  ✗ malformed code was accepted (should have rejected)" >&2
  exit 1
fi
echo "  ✓ malformed code rejected"

echo "=== T34: append-halt rejects non-object data (string, array, garbage) ==="
if "$WS" append-halt "$KEY" HALT-007 '"a-string"' 2>/dev/null; then
  echo "  ✗ string data accepted (should have rejected)" >&2
  exit 1
fi
if "$WS" append-halt "$KEY" HALT-007 '[1,2]' 2>/dev/null; then
  echo "  ✗ array data accepted (should have rejected)" >&2
  exit 1
fi
if "$WS" append-halt "$KEY" HALT-007 'malformed' 2>/dev/null; then
  echo "  ✗ malformed json accepted (should have rejected)" >&2
  exit 1
fi
echo "  ✓ non-object data rejected"

echo
echo "All 34 smoke tests passed."
