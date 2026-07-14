#!/usr/bin/env bash
# Smoke tests for workflow-state.sh. Run from the makato repo root.
# Exits non-zero on first failure. Cleans up its sandbox on success.
#
# Usage: plugins/makato-orchestrate/skills/workflow-state/references/smoke-tests.sh
#
# T1–T34: existing coverage — updated for the per-issue file layout (#173).
# T35–T42: new coverage for the per-issue file layout.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WS="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"
KEY="gap-003-smoke-test"
SANDBOX="$REPO_ROOT/specs/${KEY}"
ISSUE=26

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
"$WS" init "$KEY" macatocz/test feat/gap-003 "$ISSUE"
test -f "$SANDBOX/workflow-state-${ISSUE}.json"
echo "  ✓ workflow-state-${ISSUE}.json exists"

echo "=== T3: init refuses duplicate ==="
if "$WS" init "$KEY" macatocz/test feat/gap-003 "$ISSUE" 2>/dev/null; then
  echo "  ✗ FAIL: expected non-zero exit"
  exit 1
fi
echo "  ✓ duplicate refused"

echo "=== T4: read returns the file ==="
"$WS" read "$KEY" "$ISSUE" | jq -e '.repo == "macatocz/test"' > /dev/null
echo "  ✓ repo field set"

echo "=== T5: read on missing key returns {} ==="
"$WS" read "no-such-key-$$" "$ISSUE" | jq -e '. == {}' > /dev/null
echo "  ✓ missing returns {}"

echo "=== T6: patch updates field AND updated_at advances ==="
BEFORE=$("$WS" read "$KEY" "$ISSUE" | jq -r '.updated_at')
sleep 1
"$WS" patch "$KEY" "$ISSUE" .current_phase '"implement"'
AFTER=$("$WS" read "$KEY" "$ISSUE" | jq -r '.updated_at')
[[ "$AFTER" > "$BEFORE" ]] || { echo "  ✗ FAIL: updated_at did not advance"; exit 1; }
"$WS" read "$KEY" "$ISSUE" | jq -e '.current_phase == "implement"' > /dev/null
echo "  ✓ field set, timestamp advanced"

echo "=== T7: patch supports indexed array path ==="
"$WS" write "$KEY" "$ISSUE" \
  "$("$WS" read "$KEY" "$ISSUE" | jq '.sub_tasks = [{id:1,description:"Add model",status:"pending",phase:"tdd",agent_result:null}]')"
"$WS" patch "$KEY" "$ISSUE" '.sub_tasks[0].status' '"complete"'
"$WS" read "$KEY" "$ISSUE" | jq -e '.sub_tasks[0].status == "complete"' > /dev/null
echo "  ✓ indexed patch works"

echo "=== T8: append-lesson grows the array (GAP-015 / #37 typed schema) ==="
"$WS" append-lesson "$KEY" "$ISSUE" 0 ci_failure "tracer bullet essential" "src/foo.py" "tests/test_foo.py"
"$WS" read "$KEY" "$ISSUE" | jq -e '.lessons_learned | length == 1' > /dev/null
"$WS" read "$KEY" "$ISSUE" | jq -e '.lessons_learned[0].description == "tracer bullet essential"' > /dev/null
"$WS" read "$KEY" "$ISSUE" | jq -e '.lessons_learned[0].trigger == "ci_failure"' > /dev/null
"$WS" read "$KEY" "$ISSUE" | jq -e '.lessons_learned[0].cycle == 0' > /dev/null
"$WS" read "$KEY" "$ISSUE" | jq -e '.lessons_learned[0].files_affected == ["src/foo.py","tests/test_foo.py"]' > /dev/null
"$WS" read "$KEY" "$ISSUE" | jq -e '.lessons_learned[0].ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' > /dev/null
echo "  ✓ lesson appended with ts/cycle/trigger/description/files_affected"

echo "=== T9: invalid write halts ==="
if "$WS" write "$KEY" "$ISSUE" '{"broken":true}' 2>/dev/null; then
  echo "  ✗ FAIL: expected non-zero exit"
  exit 1
fi
echo "  ✓ schema validation halted invalid write"

echo "=== T10: GAP-004 fields populated at init with safe defaults ==="
"$WS" read "$KEY" "$ISSUE" | jq -e '.session_count == 0' > /dev/null
"$WS" read "$KEY" "$ISSUE" | jq -e '.session_summary == null' > /dev/null
"$WS" read "$KEY" "$ISSUE" | jq -e '.handoff_reason == null' > /dev/null
"$WS" read "$KEY" "$ISSUE" | jq -e '.restart_failed == false' > /dev/null
"$WS" read "$KEY" "$ISSUE" | jq -e '.spawned_pid == null' > /dev/null
"$WS" read "$KEY" "$ISSUE" | jq -e '.resume_ack == null' > /dev/null
"$WS" read "$KEY" "$ISSUE" | jq -e '.context_warn_tokens >= 1' > /dev/null
echo "  ✓ session_count / session_summary / handoff_reason / restart_failed / context_warn_tokens"

echo "=== T11: handoff_reason rejects values outside the enum ==="
if "$WS" patch "$KEY" "$ISSUE" .handoff_reason '"not_a_real_reason"' 2>/dev/null; then
  echo "  ✗ FAIL: expected non-zero exit"
  exit 1
fi
echo "  ✓ enum violation halted"

echo "=== T12: handoff_reason accepts the canonical value ==="
"$WS" patch "$KEY" "$ISSUE" .handoff_reason '"context_ceiling"'
"$WS" read "$KEY" "$ISSUE" | jq -e '.handoff_reason == "context_ceiling"' > /dev/null
echo "  ✓ context_ceiling persisted"

echo "=== T13: MAKATO_CONTEXT_WARN_TOKENS env override at init ==="
KEY2="gap-003-smoke-test-ctx"
SANDBOX2="$REPO_ROOT/specs/${KEY2}"
rm -rf "$SANDBOX2"
mkdir -p "$SANDBOX2"
MAKATO_CONTEXT_WARN_TOKENS=180000 "$WS" init "$KEY2" macatocz/test feat/gap-003 26
"$WS" read "$KEY2" 26 | jq -e '.context_warn_tokens == 180000' > /dev/null
rm -rf "$SANDBOX2"
echo "  ✓ env override honored"

echo "=== T14: GAP-017 worktree fields seeded at init ==="
"$WS" read "$KEY" "$ISSUE" | jq -e '.worktree_path == null' > /dev/null
"$WS" read "$KEY" "$ISSUE" | jq -e '.worktree_retained == false' > /dev/null
"$WS" read "$KEY" "$ISSUE" | jq -e '.worktree_retain_reason == null' > /dev/null
echo "  ✓ worktree_path / worktree_retained / worktree_retain_reason"

echo "=== T15: worktree_retained rejects non-boolean values ==="
if "$WS" patch "$KEY" "$ISSUE" .worktree_retained '"yes"' 2>/dev/null; then
  echo "  ✗ FAIL: expected non-zero exit"
  exit 1
fi
echo "  ✓ schema rejects non-boolean"

echo "=== T16: append-lesson rejects invalid trigger (GAP-015 / #37 enum) ==="
if "$WS" append-lesson "$KEY" "$ISSUE" 0 not_a_trigger "anything" 2>/dev/null; then
  echo "  ✗ FAIL: expected non-zero exit"
  exit 1
fi
echo "  ✓ enum violation halts"

echo "=== T17: append-lesson rejects non-integer cycle ==="
if "$WS" append-lesson "$KEY" "$ISSUE" "abc" ci_failure "anything" 2>/dev/null; then
  echo "  ✗ FAIL: expected non-zero exit"
  exit 1
fi
echo "  ✓ non-integer cycle halts"

echo "=== T18: append-lesson truncates description at 200 chars (GAP-015 / #37 AC) ==="
LONG_DESC="$(printf 'x%.0s' {1..400})"
"$WS" append-lesson "$KEY" "$ISSUE" 1 halt "$LONG_DESC"
ACTUAL_LEN=$("$WS" read "$KEY" "$ISSUE" | jq -r '.lessons_learned[-1].description | length')
[[ "$ACTUAL_LEN" -le 200 ]] || { echo "  ✗ FAIL: description was $ACTUAL_LEN chars, expected ≤ 200"; exit 1; }
"$WS" read "$KEY" "$ISSUE" | jq -e '.lessons_learned[-1].description | endswith("…")' > /dev/null
echo "  ✓ description truncated to ≤ 200 chars with '…' suffix"

echo "=== T19: append-lesson accepts zero files_affected (variadic optional) ==="
"$WS" append-lesson "$KEY" "$ISSUE" 1 sensor "ruff F401 unused import"
"$WS" read "$KEY" "$ISSUE" | jq -e '.lessons_learned[-1].files_affected == []' > /dev/null
echo "  ✓ files_affected empty array when no positional file args"

echo "=== T20: append-lesson accepts merge_conflict trigger (resolve-pr-conflict path) ==="
"$WS" append-lesson "$KEY" "$ISSUE" 2 merge_conflict "irreconcilable conflict after rebase + merge -X ours" "a.py" "b.py"
"$WS" read "$KEY" "$ISSUE" | jq -e '.lessons_learned[-1].trigger == "merge_conflict"' > /dev/null
"$WS" read "$KEY" "$ISSUE" | jq -e '.lessons_learned[-1].files_affected == ["a.py","b.py"]' > /dev/null
echo "  ✓ merge_conflict trigger persisted"

echo "=== T21: patch preserves lessons_learned[] (GAP-015 / #37 AC5) ==="
BEFORE_LEN=$("$WS" read "$KEY" "$ISSUE" | jq '.lessons_learned | length')
"$WS" patch "$KEY" "$ISSUE" .current_phase '"pr"'
AFTER_LEN=$("$WS" read "$KEY" "$ISSUE" | jq '.lessons_learned | length')
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
"$WS" append-lesson "$KEY3" 27 0 halt "sibling repo lesson 1" "src/x.py"
"$WS" append-lesson "$KEY3" 27 1 review_comment "sibling repo lesson 2" "src/y.py"
"$WS" init "$KEY4" macatocz/other-repo feat/other 28
"$WS" append-lesson "$KEY4" 28 0 ci_failure "OTHER repo lesson — must be filtered out"

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
LESSONS_MD="$("$WS" summarise-lessons "$KEY" "$ISSUE")"
test -f "$LESSONS_MD" || { echo "  ✗ FAIL: $LESSONS_MD not written"; exit 1; }
grep -q "# Lessons learned" "$LESSONS_MD" || { echo "  ✗ FAIL: header missing"; exit 1; }
grep -q "macatocz/test" "$LESSONS_MD" || { echo "  ✗ FAIL: repo missing"; exit 1; }
grep -q "merge_conflict" "$LESSONS_MD" || { echo "  ✗ FAIL: most recent trigger missing"; exit 1; }
echo "  ✓ markdown summary contains header, repo, and lesson triggers"

echo "=== T25: summarise-lessons is idempotent on re-run (same-day overwrite) ==="
"$WS" summarise-lessons "$KEY" "$ISSUE" > /dev/null
"$WS" summarise-lessons "$KEY" "$ISSUE" > /dev/null
COUNT=$(find "$SANDBOX" -name "lessons-*.md" | wc -l | tr -d ' ')
[[ "$COUNT" == "1" ]] || { echo "  ✗ FAIL: expected 1 lessons-*.md file, got $COUNT"; exit 1; }
echo "  ✓ one lessons-YYYYMMDD.md after re-run"

echo "=== T26: GAP-016 merge_conflict_cycles seeded at init with default 0 ==="
"$WS" read "$KEY" "$ISSUE" | jq -e '.merge_conflict_cycles == 0' > /dev/null
echo "  ✓ merge_conflict_cycles default 0"

echo "=== T27: merge_conflict_cycles accepts non-negative integer patch ==="
"$WS" patch "$KEY" "$ISSUE" .merge_conflict_cycles '2'
"$WS" read "$KEY" "$ISSUE" | jq -e '.merge_conflict_cycles == 2' > /dev/null
echo "  ✓ patch persists merge_conflict_cycles = 2"

echo "=== T28: merge_conflict_cycles rejects negative values (schema minimum 0) ==="
if "$WS" patch "$KEY" "$ISSUE" .merge_conflict_cycles '-1' 2>/dev/null; then
  echo "  ✗ FAIL: expected non-zero exit"
  exit 1
fi
echo "  ✓ schema rejects negative integer"

echo "=== T28a: #288 ci_failure_cycles seeded at init with default 0 ==="
"$WS" read "$KEY" "$ISSUE" | jq -e '.ci_failure_cycles == 0' > /dev/null
echo "  ✓ ci_failure_cycles default 0"

echo "=== T28b: ci_failure_cycles accepts non-negative integer patch ==="
"$WS" patch "$KEY" "$ISSUE" .ci_failure_cycles '2'
"$WS" read "$KEY" "$ISSUE" | jq -e '.ci_failure_cycles == 2' > /dev/null
echo "  ✓ patch persists ci_failure_cycles = 2"

echo "=== T28c: ci_failure_cycles rejects negative values (schema minimum 0) ==="
if "$WS" patch "$KEY" "$ISSUE" .ci_failure_cycles '-1' 2>/dev/null; then
  echo "  ✗ FAIL: expected non-zero exit"
  exit 1
fi
echo "  ✓ schema rejects negative integer"

# -- T29..T34: append-halt subcommand (#118) ------------------------------

echo "=== T29: append-halt with valid code + object data appends one entry ==="
BEFORE_LEN=$("$WS" read "$KEY" "$ISSUE" | jq '.halt_audit | length')
"$WS" append-halt "$KEY" "$ISSUE" HALT-007 '{"reason":"test","budget":100000}'
AFTER_LEN=$("$WS" read "$KEY" "$ISSUE" | jq '.halt_audit | length')
if [[ "$AFTER_LEN" -ne $((BEFORE_LEN + 1)) ]]; then
  echo "  ✗ expected length $((BEFORE_LEN + 1)), got $AFTER_LEN" >&2
  exit 1
fi
echo "  ✓ append-halt appended one entry"

echo "=== T30: append-halt entry has canonical {code, ts, data} shape ==="
"$WS" read "$KEY" "$ISSUE" | jq -e '.halt_audit[-1] | (.code == "HALT-007") and (.ts | type == "string") and (.data | type == "object") and (.data.reason == "test") and (.data.budget == 100000)' > /dev/null
echo "  ✓ entry shape verified"

echo "=== T31: append-halt accepts HALT-007B (suffixed variant) ==="
"$WS" append-halt "$KEY" "$ISSUE" HALT-007B '{"session":2}'
"$WS" read "$KEY" "$ISSUE" | jq -e '.halt_audit[-1].code == "HALT-007B"' > /dev/null
echo "  ✓ HALT-007B accepted"

echo "=== T32: append-halt accepts HALT-STRUCTURAL ==="
"$WS" append-halt "$KEY" "$ISSUE" HALT-STRUCTURAL '{}'
"$WS" read "$KEY" "$ISSUE" | jq -e '.halt_audit[-1].code == "HALT-STRUCTURAL"' > /dev/null
echo "  ✓ HALT-STRUCTURAL accepted"

echo "=== T33: append-halt rejects malformed code (BAD-CODE) ==="
if "$WS" append-halt "$KEY" "$ISSUE" BAD-CODE '{}' 2>/dev/null; then
  echo "  ✗ malformed code was accepted (should have rejected)" >&2
  exit 1
fi
echo "  ✓ malformed code rejected"

echo "=== T34: append-halt rejects non-object data (string, array, garbage) ==="
if "$WS" append-halt "$KEY" "$ISSUE" HALT-007 '"a-string"' 2>/dev/null; then
  echo "  ✗ string data accepted (should have rejected)" >&2
  exit 1
fi
if "$WS" append-halt "$KEY" "$ISSUE" HALT-007 '[1,2]' 2>/dev/null; then
  echo "  ✗ array data accepted (should have rejected)" >&2
  exit 1
fi
if "$WS" append-halt "$KEY" "$ISSUE" HALT-007 'malformed' 2>/dev/null; then
  echo "  ✗ malformed json accepted (should have rejected)" >&2
  exit 1
fi
echo "  ✓ non-object data rejected"

# ================================================================
# #173 — per-issue state file layout (T35–T42)
#
# Each test seeds its own fresh sandbox so state from earlier tests
# above does not leak in. All new tests exercise the multi-issue
# story-shared-spec-folder scenario that #173 describes.
# ================================================================

echo "=== T35: two init calls with same KEY / different ISSUE do NOT clobber (#173 AC-1) ==="
KEY5="issue-173-multi-issue"
SANDBOX5="$REPO_ROOT/specs/${KEY5}"
rm -rf "$SANDBOX5"; mkdir -p "$SANDBOX5"
"$WS" init "$KEY5" macatocz/test feat/173-story 143
"$WS" init "$KEY5" macatocz/test feat/173-story 144
test -f "$SANDBOX5/workflow-state-143.json" || { echo "  ✗ FAIL: workflow-state-143.json missing"; exit 1; }
test -f "$SANDBOX5/workflow-state-144.json" || { echo "  ✗ FAIL: workflow-state-144.json missing"; exit 1; }
"$WS" read "$KEY5" 143 | jq -e '.issue_number == 143' > /dev/null || { echo "  ✗ FAIL: 143 issue_number wrong"; exit 1; }
"$WS" read "$KEY5" 144 | jq -e '.issue_number == 144' > /dev/null || { echo "  ✗ FAIL: 144 issue_number wrong"; exit 1; }
echo "  ✓ two per-issue files, both intact"

echo "=== T36: subcommand routing — patch on 143 does NOT mutate 144 (#173 AC-2) ==="
"$WS" patch "$KEY5" 143 .current_phase '"implement"'
"$WS" read "$KEY5" 143 | jq -e '.current_phase == "implement"' > /dev/null || { echo "  ✗ FAIL: 143 current_phase not set"; exit 1; }
"$WS" read "$KEY5" 144 | jq -e '.current_phase == null' > /dev/null || { echo "  ✗ FAIL: 144 current_phase leaked"; exit 1; }
echo "  ✓ patch routed to ISSUE=143 only"

echo "=== T37: append-lesson / append-halt / summarise-lessons route per-issue (#173 AC-2) ==="
"$WS" append-lesson "$KEY5" 143 0 ci_failure "issue 143 lesson"
"$WS" append-lesson "$KEY5" 144 0 halt "issue 144 lesson"
"$WS" append-halt "$KEY5" 143 HALT-007 '{"scope":"issue-143"}'
"$WS" append-halt "$KEY5" 144 HALT-008 '{"scope":"issue-144"}'
"$WS" read "$KEY5" 143 | jq -e '.lessons_learned[0].description == "issue 143 lesson"' > /dev/null || { echo "  ✗ FAIL: 143 lesson wrong"; exit 1; }
"$WS" read "$KEY5" 144 | jq -e '.lessons_learned[0].description == "issue 144 lesson"' > /dev/null || { echo "  ✗ FAIL: 144 lesson wrong"; exit 1; }
"$WS" read "$KEY5" 143 | jq -e '.halt_audit[0].code == "HALT-007"' > /dev/null || { echo "  ✗ FAIL: 143 halt wrong"; exit 1; }
"$WS" read "$KEY5" 144 | jq -e '.halt_audit[0].code == "HALT-008"' > /dev/null || { echo "  ✗ FAIL: 144 halt wrong"; exit 1; }

LM143=$("$WS" summarise-lessons "$KEY5" 143)
LM144=$("$WS" summarise-lessons "$KEY5" 144)
grep -q "issue 143 lesson" "$LM143" || { echo "  ✗ FAIL: 143 summary missing its lesson"; exit 1; }
grep -q "issue 144 lesson" "$LM144" || { echo "  ✗ FAIL: 144 summary missing its lesson"; exit 1; }
if grep -q "issue 143 lesson" "$LM144"; then echo "  ✗ FAIL: 143 lesson leaked into 144 summary"; exit 1; fi
if grep -q "issue 144 lesson" "$LM143"; then echo "  ✗ FAIL: 144 lesson leaked into 143 summary"; exit 1; fi
echo "  ✓ append-lesson / append-halt / summarise-lessons route by ISSUE"

echo "=== T38: recall-lessons aggregates lessons across per-issue files (#173 AC-3) ==="
RECALLED_173=$("$WS" recall-lessons macatocz/test 5)
# Filter to just the KEY5 lessons so unrelated primary-sandbox lessons don't fail the count.
COUNT_143=$(echo "$RECALLED_173" | jq '[.[] | select(.description == "issue 143 lesson")] | length')
COUNT_144=$(echo "$RECALLED_173" | jq '[.[] | select(.description == "issue 144 lesson")] | length')
[[ "$COUNT_143" == "1" ]] || { echo "  ✗ FAIL: expected exactly 1 '143 lesson' in recall, got $COUNT_143"; exit 1; }
[[ "$COUNT_144" == "1" ]] || { echo "  ✗ FAIL: expected exactly 1 '144 lesson' in recall, got $COUNT_144"; exit 1; }
echo "  ✓ recall-lessons picks up lessons from both per-issue files"

echo "=== T39: read-time migration promotes legacy workflow-state.json → workflow-state-<issue>.json (#173 AC-4) ==="
KEY6="issue-173-legacy-migration"
SANDBOX6="$REPO_ROOT/specs/${KEY6}"
rm -rf "$SANDBOX6"; mkdir -p "$SANDBOX6"

# Seed a legacy-shape file by init-ing then manually renaming to the legacy path.
"$WS" init "$KEY6" macatocz/test feat/173-legacy 200
mv "$SANDBOX6/workflow-state-200.json" "$SANDBOX6/workflow-state.json"
test -f "$SANDBOX6/workflow-state.json" || { echo "  ✗ FAIL: legacy seed failed"; exit 1; }
test ! -f "$SANDBOX6/workflow-state-200.json" || { echo "  ✗ FAIL: new-name file already exists before migration"; exit 1; }

# First read triggers migration. The ISSUE_NUMBER passed here MUST match the
# legacy file's own `.issue_number` — the promotion is content-driven.
"$WS" read "$KEY6" 200 | jq -e '.issue_number == 200' > /dev/null || { echo "  ✗ FAIL: migrated read did not return content"; exit 1; }
test -f "$SANDBOX6/workflow-state-200.json" || { echo "  ✗ FAIL: workflow-state-200.json not created by migration"; exit 1; }
test ! -f "$SANDBOX6/workflow-state.json" || { echo "  ✗ FAIL: legacy workflow-state.json still present after migration"; exit 1; }

# Second read is a no-op — migration must be idempotent.
"$WS" read "$KEY6" 200 | jq -e '.issue_number == 200' > /dev/null || { echo "  ✗ FAIL: second read failed"; exit 1; }
echo "  ✓ legacy file promoted atomically; second read is a no-op"

rm -rf "$SANDBOX6"

echo "=== T40: ISSUE_NUMBER validation — non-integer and zero are rejected (#173) ==="
if "$WS" read "$KEY5" "notanumber" 2>/dev/null; then
  echo "  ✗ FAIL: non-integer ISSUE_NUMBER accepted"
  exit 1
fi
if "$WS" read "$KEY5" "0" 2>/dev/null; then
  echo "  ✗ FAIL: zero ISSUE_NUMBER accepted"
  exit 1
fi
if "$WS" read "$KEY5" "-1" 2>/dev/null; then
  echo "  ✗ FAIL: negative ISSUE_NUMBER accepted"
  exit 1
fi
echo "  ✓ non-positive-integer ISSUE_NUMBER rejected across subcommands"

echo "=== T41: #170 worktree_path guard still fires on the per-issue file (#173 AC-8) ==="
# Refuse an unregistered path.
if "$WS" patch "$KEY5" 143 .worktree_path '"/tmp/definitely-not-a-worktree-'"$$"'"' 2>/dev/null; then
  echo "  ✗ FAIL: unregistered worktree path accepted (guard broke)"
  exit 1
fi
# Refuse the main-repo root explicitly (the #170 incident path).
if "$WS" patch "$KEY5" 143 .worktree_path "\"$REPO_ROOT\"" 2>/dev/null; then
  echo "  ✗ FAIL: main-repo root accepted as worktree_path (guard broke)"
  exit 1
fi
# Explicit null is always permitted.
"$WS" patch "$KEY5" 143 .worktree_path 'null'
"$WS" read "$KEY5" 143 | jq -e '.worktree_path == null' > /dev/null
# Test-scenario bypass still works for smoke tests.
MAKATO_WORKTREE_PATCH_ALLOW_UNREGISTERED=1 "$WS" patch "$KEY5" 143 .worktree_path '"/tmp/bypassed-path"'
"$WS" read "$KEY5" 143 | jq -e '.worktree_path == "/tmp/bypassed-path"' > /dev/null
echo "  ✓ .worktree_path guard preserves invariants under the per-issue layout"

echo "=== T42: recall-lessons ignores per-issue files whose .repo does not match (#173 AC-3) ==="
KEY7="issue-173-recall-repo-filter"
SANDBOX7="$REPO_ROOT/specs/${KEY7}"
rm -rf "$SANDBOX7"; mkdir -p "$SANDBOX7"
"$WS" init "$KEY7" macatocz/aaa feat/173-a 300
"$WS" init "$KEY7" macatocz/bbb feat/173-b 301
"$WS" append-lesson "$KEY7" 300 0 halt "recall-filter aaa lesson"
"$WS" append-lesson "$KEY7" 301 0 halt "recall-filter bbb lesson"

# Recall on aaa must return only the aaa lesson (not bbb).
AAA_RECALLED=$("$WS" recall-lessons macatocz/aaa 5)
AAA_COUNT=$(echo "$AAA_RECALLED" | jq '[.[] | select(.description == "recall-filter aaa lesson")] | length')
AAA_LEAK=$(echo "$AAA_RECALLED" | jq '[.[] | select(.description == "recall-filter bbb lesson")] | length')
[[ "$AAA_COUNT" == "1" ]] || { echo "  ✗ FAIL: expected 1 aaa lesson recalled, got $AAA_COUNT"; exit 1; }
[[ "$AAA_LEAK" == "0" ]] || { echo "  ✗ FAIL: bbb lesson leaked into aaa recall"; exit 1; }
echo "  ✓ recall-lessons per-repo filter honoured across per-issue files"

rm -rf "$SANDBOX5" "$SANDBOX7"

echo "=== T43: concurrent _migrate_legacy_state must not crash under set -euo pipefail (#173 review C1) ==="
# Two readers see the legacy file before either mv runs → the "loser" must
# fall through cleanly, not exit 1 from a missing-source mv. We simulate the
# race by seeding a legacy file and racing two `read` calls in parallel;
# both must exit 0 and one must observe the migrated per-issue file.
KEY_RACE="issue-173-mv-race"
SANDBOX_RACE="$REPO_ROOT/specs/${KEY_RACE}"
rm -rf "$SANDBOX_RACE"; mkdir -p "$SANDBOX_RACE"
"$WS" init "$KEY_RACE" macatocz/test feat/173-race 400
mv "$SANDBOX_RACE/workflow-state-400.json" "$SANDBOX_RACE/workflow-state.json"

# Fire two concurrent reads. Both must succeed (exit 0). The old code would
# have exit-1'd the loser via `mv` under set -euo pipefail.
"$WS" read "$KEY_RACE" 400 > "$SANDBOX_RACE/reader-a.out" 2> "$SANDBOX_RACE/reader-a.err" &
RACE_PID_A=$!
"$WS" read "$KEY_RACE" 400 > "$SANDBOX_RACE/reader-b.out" 2> "$SANDBOX_RACE/reader-b.err" &
RACE_PID_B=$!
wait "$RACE_PID_A" || { echo "  ✗ FAIL: reader A exited non-zero (mv race regression)"; cat "$SANDBOX_RACE/reader-a.err"; exit 1; }
wait "$RACE_PID_B" || { echo "  ✗ FAIL: reader B exited non-zero (mv race regression)"; cat "$SANDBOX_RACE/reader-b.err"; exit 1; }
test -f "$SANDBOX_RACE/workflow-state-400.json" || { echo "  ✗ FAIL: migrated file not present after race"; exit 1; }
test ! -f "$SANDBOX_RACE/workflow-state.json" || { echo "  ✗ FAIL: legacy file still present after race"; exit 1; }
# Both readers must have returned the same content (issue_number 400).
jq -e '.issue_number == 400' "$SANDBOX_RACE/reader-a.out" > /dev/null || { echo "  ✗ FAIL: reader A did not see issue 400"; exit 1; }
jq -e '.issue_number == 400' "$SANDBOX_RACE/reader-b.out" > /dev/null || { echo "  ✗ FAIL: reader B did not see issue 400"; exit 1; }
echo "  ✓ two concurrent readers both succeeded, race handled cleanly"
rm -rf "$SANDBOX_RACE"

echo "=== T44: #284 — spawned_pid schema contract (integer>=1 | null) ==="
KEY_284="issue-284-fields"
SANDBOX_284="$REPO_ROOT/specs/${KEY_284}"
rm -rf "$SANDBOX_284"; mkdir -p "$SANDBOX_284"
"$WS" init "$KEY_284" macatocz/test feat/284 284 >/dev/null 2>&1
# Accepts a positive integer.
"$WS" patch "$KEY_284" 284 '.spawned_pid' '12345' >/dev/null 2>&1 || { echo "  ✗ FAIL: positive integer rejected"; exit 1; }
[[ "$("$WS" read "$KEY_284" 284 | jq -r '.spawned_pid')" == "12345" ]] || { echo "  ✗ FAIL: spawned_pid not persisted"; exit 1; }
# Accepts null (cleared by check-pid on healthy resume).
"$WS" patch "$KEY_284" 284 '.spawned_pid' 'null' >/dev/null 2>&1 || { echo "  ✗ FAIL: null rejected"; exit 1; }
# Rejects a non-integer type.
if "$WS" patch "$KEY_284" 284 '.spawned_pid' '"text"' >/dev/null 2>&1; then
  echo "  ✗ FAIL: non-integer spawned_pid accepted"; exit 1
fi
# Rejects 0 (minimum: 1 — PIDs are >= 1).
if "$WS" patch "$KEY_284" 284 '.spawned_pid' '0' >/dev/null 2>&1; then
  echo "  ✗ FAIL: spawned_pid=0 accepted (minimum:1 not enforced)"; exit 1
fi
echo "  ✓ spawned_pid: integer>=1 and null accepted; string and 0 rejected"

echo "=== T45: #284 — resume_ack schema contract (string | null) ==="
# Accepts an ISO-8601 timestamp string.
"$WS" patch "$KEY_284" 284 '.resume_ack' '"2026-07-13T10:00:00.000Z"' >/dev/null 2>&1 || { echo "  ✗ FAIL: ISO string rejected"; exit 1; }
[[ "$("$WS" read "$KEY_284" 284 | jq -r '.resume_ack')" == "2026-07-13T10:00:00.000Z" ]] || { echo "  ✗ FAIL: resume_ack not persisted"; exit 1; }
# Accepts null (init default / between handoffs).
"$WS" patch "$KEY_284" 284 '.resume_ack' 'null' >/dev/null 2>&1 || { echo "  ✗ FAIL: null rejected"; exit 1; }
# Rejects a non-string type (integer).
if "$WS" patch "$KEY_284" 284 '.resume_ack' '123' >/dev/null 2>&1; then
  echo "  ✗ FAIL: non-string resume_ack accepted"; exit 1
fi
# NB: the schema declares "format": "date-time", but Python's jsonschema treats
# format as advisory unless a FormatChecker is wired in — which the validator
# here is not. So a malformed string like "not-a-date" IS accepted at the schema
# layer; the type contract (string|null) is what is actually enforced. The
# ISO-8601 shape is guaranteed by the writers (po-agent uses `date -u`,
# check-pid compares via _epoch_of_iso which tolerates unparseable input), not
# by schema validation. This assertion documents the accepted-string reality so
# a future reader does not mistake the format keyword for an enforced constraint.
"$WS" patch "$KEY_284" 284 '.resume_ack' '"not-a-date"' >/dev/null 2>&1 || { echo "  ✗ FAIL: string value unexpectedly rejected (format is advisory, not enforced)"; exit 1; }
echo "  ✓ resume_ack: ISO string and null accepted; integer rejected (format advisory, not enforced)"
rm -rf "$SANDBOX_284"

echo "=== T46: #317 — missing jsonschema emits loud degraded warning (not silent) ==="
KEY_317="issue-317-schema-warn"
SANDBOX_317="$REPO_ROOT/specs/${KEY_317}"
rm -rf "$SANDBOX_317"; mkdir -p "$SANDBOX_317"
"$WS" init "$KEY_317" macatocz/test feat/317 317 >/dev/null 2>&1

# Simulate missing jsonschema by prepending a stub that raises ImportError.
STUB_DIR="$(mktemp -d)"
cat > "$STUB_DIR/jsonschema.py" <<'PYSTUB'
raise ImportError("stubbed out for T46")
PYSTUB

# Capture stderr while patching; the patch must still succeed (fail-open).
WARN_OUT=$(PYTHONPATH="$STUB_DIR${PYTHONPATH:+:$PYTHONPATH}" "$WS" patch "$KEY_317" 317 .current_phase '"pr"' 2>&1 >/dev/null || true)
rm -rf "$STUB_DIR"

# The run must not have hard-failed (field should be written).
"$WS" read "$KEY_317" 317 | jq -e '.current_phase == "pr"' > /dev/null ||   { echo "  ✗ FAIL: fail-open violated — patch did not persist under missing jsonschema"; exit 1; }

# The warning must be present and contain 'degraded: schema-unvalidated'.
echo "$WARN_OUT" | grep -q "degraded: schema-unvalidated" ||   { echo "  ✗ FAIL: degraded warning not emitted (got: $WARN_OUT)"; exit 1; }

echo "$WARN_OUT" | grep -q "WARN" ||   { echo "  ✗ FAIL: WARN tag not in warning message (got: $WARN_OUT)"; exit 1; }

rm -rf "$SANDBOX_317"
echo "  ✓ missing jsonschema emits degraded warning; run still succeeds"

# ================================================================
# #347 — durable per-issue structural_halt_cycles counter (epic #319)
#
# Foundation story: a cross-run counter that increments exactly once
# per PO-agent run terminating on a STRUCTURAL HALT. The authoritative
# structural set is HALT-003, HALT-STRUCTURAL, HALT-010, and HALT-008
# with origin == outer_iteration. Everything else is a no-op.
#
# Covers the three issue #347 draft scenarios plus the init default,
# backward-compat (field absent), and shell-level validation.
# ================================================================

echo "=== T47: #347 — structural_halt_cycles seeded at init with default 0 ==="
KEY_347="issue-347-structural-halt"
SANDBOX_347="$REPO_ROOT/specs/${KEY_347}"
rm -rf "$SANDBOX_347"; mkdir -p "$SANDBOX_347"
"$WS" init "$KEY_347" macatocz/test feat/347 347 >/dev/null 2>&1
"$WS" read "$KEY_347" 347 | jq -e '.structural_halt_cycles == 0' > /dev/null || { echo "  ✗ FAIL: default not 0"; exit 1; }
echo "  ✓ structural_halt_cycles default 0"

echo "=== T48: #347 Scenario 1 — HALT-STRUCTURAL increments the counter ==="
# Seed to 1 to mirror the scenario's Given.
"$WS" patch "$KEY_347" 347 .structural_halt_cycles '1' >/dev/null
OUT=$("$WS" bump-structural-halt "$KEY_347" 347 HALT-STRUCTURAL)
[[ "$OUT" == "2" ]] || { echo "  ✗ FAIL: expected stdout 2, got '$OUT'"; exit 1; }
"$WS" read "$KEY_347" 347 | jq -e '.structural_halt_cycles == 2' > /dev/null || { echo "  ✗ FAIL: persisted value not 2"; exit 1; }
echo "  ✓ HALT-STRUCTURAL: 1 → 2, persisted and echoed"

echo "=== T49: #347 Scenario 1 — HALT-008 origin outer_iteration is structural ==="
OUT=$("$WS" bump-structural-halt "$KEY_347" 347 HALT-008 outer_iteration)
[[ "$OUT" == "3" ]] || { echo "  ✗ FAIL: expected 3, got '$OUT'"; exit 1; }
"$WS" read "$KEY_347" 347 | jq -e '.structural_halt_cycles == 3' > /dev/null || { echo "  ✗ FAIL: persisted value not 3"; exit 1; }
echo "  ✓ HALT-008/outer_iteration: 2 → 3 (structural)"

echo "=== T50: #347 — HALT-003 and HALT-010 are structural ==="
"$WS" patch "$KEY_347" 347 .structural_halt_cycles '0' >/dev/null
OUT=$("$WS" bump-structural-halt "$KEY_347" 347 HALT-003)
[[ "$OUT" == "1" ]] || { echo "  ✗ FAIL: HALT-003 expected 1, got '$OUT'"; exit 1; }
OUT=$("$WS" bump-structural-halt "$KEY_347" 347 HALT-010)
[[ "$OUT" == "2" ]] || { echo "  ✗ FAIL: HALT-010 expected 2, got '$OUT'"; exit 1; }
echo "  ✓ HALT-003 and HALT-010 each increment"

echo "=== T51: #347 Scenario 2 — non-structural HALTs leave the counter untouched ==="
# Given structural_halt_cycles = 1.
"$WS" patch "$KEY_347" 347 .structural_halt_cycles '1' >/dev/null
# HALT-007 (cost) — no-op.
OUT=$("$WS" bump-structural-halt "$KEY_347" 347 HALT-007)
[[ "$OUT" == "1" ]] || { echo "  ✗ FAIL: HALT-007 changed counter to '$OUT'"; exit 1; }
# HALT-007B (context handoff) — no-op.
OUT=$("$WS" bump-structural-halt "$KEY_347" 347 HALT-007B)
[[ "$OUT" == "1" ]] || { echo "  ✗ FAIL: HALT-007B changed counter to '$OUT'"; exit 1; }
# HALT-008 with origin merge_conflict — no-op.
OUT=$("$WS" bump-structural-halt "$KEY_347" 347 HALT-008 merge_conflict)
[[ "$OUT" == "1" ]] || { echo "  ✗ FAIL: HALT-008/merge_conflict changed counter to '$OUT'"; exit 1; }
# HALT-008 with origin ci_failure — no-op.
OUT=$("$WS" bump-structural-halt "$KEY_347" 347 HALT-008 ci_failure)
[[ "$OUT" == "1" ]] || { echo "  ✗ FAIL: HALT-008/ci_failure changed counter to '$OUT'"; exit 1; }
# HALT-008 with NO origin — not classified structural (origin unknown), no-op.
OUT=$("$WS" bump-structural-halt "$KEY_347" 347 HALT-008)
[[ "$OUT" == "1" ]] || { echo "  ✗ FAIL: HALT-008 (no origin) changed counter to '$OUT'"; exit 1; }
"$WS" read "$KEY_347" 347 | jq -e '.structural_halt_cycles == 1' > /dev/null || { echo "  ✗ FAIL: persisted value drifted from 1"; exit 1; }
echo "  ✓ HALT-007 / HALT-007B / HALT-008(merge_conflict|ci_failure|none) are all no-ops"

echo "=== T52: #347 Scenario 3 — context handoff (HALT-007B) does not reset the counter ==="
# Given structural_halt_cycles = 2; a HALT-007B classification must be a no-op
# so the resumed session reads the same value.
"$WS" patch "$KEY_347" 347 .structural_halt_cycles '2' >/dev/null
"$WS" bump-structural-halt "$KEY_347" 347 HALT-007B >/dev/null
# Simulate the handoff round-trip: session_baseline advances, handoff_reason set —
# none of which may touch structural_halt_cycles.
"$WS" patch "$KEY_347" 347 .handoff_reason '"context_ceiling"' >/dev/null
"$WS" read "$KEY_347" 347 | jq -e '.structural_halt_cycles == 2' > /dev/null || { echo "  ✗ FAIL: counter reset across handoff"; exit 1; }
echo "  ✓ counter survives HALT-007B handoff unchanged (== 2)"

echo "=== T53: #347 — backward compat: field absent defaults to 0 on increment ==="
# Delete the field entirely to mimic a pre-#347 in-flight state file, then a
# structural bump must treat the missing field as 0 and write 1.
"$WS" write "$KEY_347" 347 "$("$WS" read "$KEY_347" 347 | jq 'del(.structural_halt_cycles)')" >/dev/null
"$WS" read "$KEY_347" 347 | jq -e 'has("structural_halt_cycles") | not' > /dev/null || { echo "  ✗ FAIL: field not actually deleted"; exit 1; }
OUT=$("$WS" bump-structural-halt "$KEY_347" 347 HALT-STRUCTURAL)
[[ "$OUT" == "1" ]] || { echo "  ✗ FAIL: absent field did not default to 0 (got '$OUT')"; exit 1; }
"$WS" read "$KEY_347" 347 | jq -e '.structural_halt_cycles == 1' > /dev/null || { echo "  ✗ FAIL: field not backfilled to 1"; exit 1; }
echo "  ✓ absent field treated as 0 and backfilled on structural bump"

echo "=== T54: #347 — bump-structural-halt rejects a malformed HALT code ==="
if "$WS" bump-structural-halt "$KEY_347" 347 NOT-A-HALT 2>/dev/null; then
  echo "  ✗ FAIL: malformed code accepted"; exit 1
fi
# Non-structural no-op must NOT emit an orchestrate.jsonl increment line.
"$WS" bump-structural-halt "$KEY_347" 347 HALT-007 >/dev/null
if [[ -f "$SANDBOX_347/build.jsonl" ]]; then
  # No increment entry may ever carry a non-structural halt_code. Filter to
  # increment lines only, then assert none of them is HALT-007.
  BAD=$(jq -rc 'select(.step == "structural_halt_increment") | .data.halt_code' "$SANDBOX_347/build.jsonl" 2>/dev/null | grep -c '^HALT-007$' || true)
  [[ "$BAD" == "0" ]] || { echo "  ✗ FAIL: non-structural HALT-007 logged an increment"; exit 1; }
fi
echo "  ✓ malformed code rejected; non-structural code logs no increment"
rm -rf "$SANDBOX_347"

echo
echo "All 54 smoke tests passed."
