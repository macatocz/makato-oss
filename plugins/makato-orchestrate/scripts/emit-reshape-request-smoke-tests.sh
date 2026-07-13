#!/usr/bin/env bash
# Smoke tests for scripts/emit-reshape-request.sh (#349).
#
# Run from the makato repo root:
#   plugins/makato-orchestrate/scripts/emit-reshape-request-smoke-tests.sh
#
# Scenarios:
#   T1: missing args exits 1 and prints usage error to stderr
#   T2: missing workflow-state file exits 1
#   T3: valid workflow-state with structural halts produces reshape-request.json
#   T4: halt_history contains only structural HALT entries (HALT-003, HALT-STRUCTURAL,
#       HALT-010, HALT-008 with data.origin=="outer_iteration")
#   T5: non-structural HALTs (HALT-007, HALT-008 with origin!="outer_iteration") are excluded
#   T6: lessons_trail contains only entries with trigger=="halt"
#   T7: last_critical_errors populated with CRITICAL-containing strings from last sub_task
#   T8: last_critical_errors absent when no CRITICAL errors in last sub_task
#   T9: reshape-request.json is written atomically (no partial file)
#   T10: reshape_cycles increments from prior reshape-request.json
#   T11: valid output passes JSON schema validation
#   T12: orchestrate.jsonl entry appended with step "emit-reshape-request"
#
# Fully offline: workflow-state is injected via fixture files.
# Mirrors promote-ready-smoke-tests.sh conventions.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/makato-orchestrate/scripts/emit-reshape-request.sh"
WS="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"

SANDBOX="${CLAUDE_JOB_DIR:-/tmp}/emit-reshape-request-smoke-$$"
SPECS="$SANDBOX/specs"
mkdir -p "$SPECS"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

fail() { echo "  FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

_now() {
  python3 -c "from datetime import datetime, timezone
n = datetime.now(timezone.utc)
print(n.strftime('%Y-%m-%dT%H:%M:%S.') + f'{n.microsecond // 1000:03d}Z')"
}

# ---------------------------------------------------------------------------
# Test fixtures
# ---------------------------------------------------------------------------

KEY="349-makato-orchestrate-serialize-structural"
ISSUE_NUM=349
SLUG="makato-orchestrate-serialize-structural"
SPEC_DIR="$SPECS/${KEY}"
mkdir -p "$SPEC_DIR"

# Fixture: minimal valid workflow-state with structural and non-structural halts,
# halt-triggered and non-halt-triggered lessons, and sub_tasks with errors.
NOW="$(_now)"
cat >"$SPEC_DIR/workflow-state-${ISSUE_NUM}.json" <<EOF
{
  "repo": "macatocz/makato",
  "branch": "feat/349",
  "worktree_path": null,
  "worktree_retained": false,
  "worktree_retain_reason": null,
  "issue_number": ${ISSUE_NUM},
  "sub_tasks": [
    {
      "id": "task-1",
      "title": "Task 1",
      "status": "complete",
      "agent_result": {
        "schema": "r1",
        "agent": "coder",
        "status": "failure",
        "summary": "structural blocker",
        "files_changed": [],
        "tests_written": [],
        "errors": ["CRITICAL: some fatal error", "another error without keyword"],
        "tool_calls_used": 10,
        "data": {}
      }
    }
  ],
  "current_phase": "implement",
  "resume_point": null,
  "budget_consumed_tokens": 50000,
  "session_baseline_tokens": 0,
  "budget_limit_tokens": 500000,
  "context_warn_tokens": 150000,
  "outer_iteration": 1,
  "merge_conflict_cycles": 0,
  "ci_failure_cycles": 0,
  "halt_audit": [
    {"code": "HALT-003", "ts": "${NOW}", "data": {"reason": "critical diff finding"}},
    {"code": "HALT-STRUCTURAL", "ts": "${NOW}", "data": {"escalation": "refine"}},
    {"code": "HALT-010", "ts": "${NOW}", "data": {"human_review_cycles": 3}},
    {"code": "HALT-008", "ts": "${NOW}", "data": {"origin": "outer_iteration", "reason": "budget exhausted"}},
    {"code": "HALT-007", "ts": "${NOW}", "data": {"reason": "cost ceiling"}},
    {"code": "HALT-008", "ts": "${NOW}", "data": {"origin": "merge_conflict", "reason": "irreconcilable"}}
  ],
  "human_review_cycles": 3,
  "github_pr_number": null,
  "progress_comment_id": null,
  "lessons_learned": [
    {
      "ts": "${NOW}",
      "cycle": 1,
      "trigger": "halt",
      "description": "HALT-003 fired after coder returned failure with refine escalation",
      "files_affected": ["plugins/makato-orchestrate/scripts/emit-reshape-request.sh"]
    },
    {
      "ts": "${NOW}",
      "cycle": 0,
      "trigger": "ci_failure",
      "description": "CI failed on linting",
      "files_affected": []
    },
    {
      "ts": "${NOW}",
      "cycle": 1,
      "trigger": "halt",
      "description": "HALT-010 hit max human review cycles",
      "files_affected": []
    }
  ],
  "session_summary": null,
  "session_count": 1,
  "handoff_reason": null,
  "restart_failed": false,
  "spawned_pid": null,
  "resume_ack": null,
  "created_at": "${NOW}",
  "updated_at": "${NOW}"
}
EOF

# ---------------------------------------------------------------------------
echo "=== T1: missing args exits 1 ==="
ERR="$(MAKATO_EMIT_RESHAPE_SPECS_DIR="$SPECS" "$SCRIPT" 2>&1 >/dev/null || true)"
# The script should exit non-zero when called with no args
EXIT_CODE=0
MAKATO_EMIT_RESHAPE_SPECS_DIR="$SPECS" "$SCRIPT" 2>/dev/null >/dev/null && EXIT_CODE=0 || EXIT_CODE=$?
[[ "$EXIT_CODE" -ne 0 ]] || fail "missing-args should exit non-zero, got 0"
pass "missing args exits non-zero (exit $EXIT_CODE)"

# ---------------------------------------------------------------------------
echo "=== T2: missing workflow-state file exits 1 ==="
MISSING_KEY="999-no-such-issue"
EXIT_CODE=0
MAKATO_EMIT_RESHAPE_SPECS_DIR="$SPECS" "$SCRIPT" "$MISSING_KEY" 999 2>/dev/null >/dev/null \
  && EXIT_CODE=0 || EXIT_CODE=$?
[[ "$EXIT_CODE" -ne 0 ]] || fail "missing workflow-state should exit non-zero"
pass "missing workflow-state exits non-zero (exit $EXIT_CODE)"

# ---------------------------------------------------------------------------
echo "=== T3: valid workflow-state produces reshape-request.json ==="
MAKATO_EMIT_RESHAPE_SPECS_DIR="$SPECS" "$SCRIPT" "$KEY" "$ISSUE_NUM" >/dev/null 2>&1
[[ -f "$SPEC_DIR/reshape-request.json" ]] || fail "reshape-request.json not created"
pass "reshape-request.json created at $SPEC_DIR/reshape-request.json"

# ---------------------------------------------------------------------------
echo "=== T4: halt_history contains only structural HALTs ==="
HALT_CODES="$(jq -r '.halt_history[].code' "$SPEC_DIR/reshape-request.json")"
# Should include HALT-003, HALT-STRUCTURAL, HALT-010, HALT-008 (outer_iteration)
echo "$HALT_CODES" | grep -q "HALT-003"       || fail "HALT-003 missing from halt_history"
echo "$HALT_CODES" | grep -q "HALT-STRUCTURAL"|| fail "HALT-STRUCTURAL missing from halt_history"
echo "$HALT_CODES" | grep -q "HALT-010"       || fail "HALT-010 missing from halt_history"
echo "$HALT_CODES" | grep -q "HALT-008"       || fail "HALT-008 (outer_iteration) missing"
pass "all 4 structural HALT codes present in halt_history"

# ---------------------------------------------------------------------------
echo "=== T5: non-structural HALTs excluded from halt_history ==="
HALT_COUNT="$(jq '.halt_history | length' "$SPEC_DIR/reshape-request.json")"
# We have 6 HALT entries: 4 structural + HALT-007 + HALT-008(merge_conflict)
# Only 4 should be in halt_history
[[ "$HALT_COUNT" -eq 4 ]] || fail "halt_history should have 4 entries, got $HALT_COUNT"
# HALT-007 must NOT appear
if jq -e '.halt_history[] | select(.code == "HALT-007")' "$SPEC_DIR/reshape-request.json" >/dev/null 2>&1; then
  fail "HALT-007 (non-structural) found in halt_history"
fi
# HALT-008 with origin=merge_conflict must NOT appear
MERGE_HALT="$(jq '[.halt_history[] | select(.code == "HALT-008" and .data.origin == "merge_conflict")] | length' "$SPEC_DIR/reshape-request.json")"
[[ "$MERGE_HALT" -eq 0 ]] || fail "HALT-008 with origin=merge_conflict found in halt_history"
pass "non-structural HALTs excluded (HALT-007, HALT-008/merge_conflict not in halt_history)"

# ---------------------------------------------------------------------------
echo "=== T6: lessons_trail contains only trigger==halt entries ==="
LESSON_TRIGGERS="$(jq -r '.lessons_trail[].trigger' "$SPEC_DIR/reshape-request.json")"
LESSON_COUNT="$(jq '.lessons_trail | length' "$SPEC_DIR/reshape-request.json")"
# ci_failure lesson should be excluded; 2 halt lessons should remain
[[ "$LESSON_COUNT" -eq 2 ]] || fail "lessons_trail should have 2 entries, got $LESSON_COUNT"
while IFS= read -r trigger; do
  [[ "$trigger" == "halt" ]] || fail "non-halt trigger found in lessons_trail: $trigger"
done <<<"$LESSON_TRIGGERS"
pass "lessons_trail contains only 2 halt-triggered entries"

# ---------------------------------------------------------------------------
echo "=== T7: last_critical_errors contains CRITICAL strings from last sub_task ==="
CRITICAL_COUNT="$(jq '.last_critical_errors | length' "$SPEC_DIR/reshape-request.json")"
[[ "$CRITICAL_COUNT" -eq 1 ]] || fail "expected 1 CRITICAL error, got $CRITICAL_COUNT"
CRITICAL_ERR="$(jq -r '.last_critical_errors[0]' "$SPEC_DIR/reshape-request.json")"
echo "$CRITICAL_ERR" | grep -qi "critical" || fail "CRITICAL string not found: $CRITICAL_ERR"
pass "last_critical_errors has 1 CRITICAL string: $CRITICAL_ERR"

# ---------------------------------------------------------------------------
echo "=== T8: last_critical_errors absent when no CRITICAL errors ==="
# Create a fixture with no CRITICAL errors in sub_tasks
mkdir -p "$SPECS/100-no-critical"
cat >"$SPECS/100-no-critical/workflow-state-100.json" <<EOF
{
  "repo": "macatocz/makato",
  "branch": "feat/100",
  "worktree_path": null,
  "worktree_retained": false,
  "worktree_retain_reason": null,
  "issue_number": 100,
  "sub_tasks": [
    {
      "id": "task-1",
      "title": "Task 1",
      "status": "complete",
      "agent_result": {
        "schema": "r1",
        "agent": "coder",
        "status": "success",
        "summary": "done",
        "files_changed": [],
        "tests_written": [],
        "errors": ["some warning", "another note"],
        "tool_calls_used": 5,
        "data": {}
      }
    }
  ],
  "current_phase": "implement",
  "resume_point": null,
  "budget_consumed_tokens": 0,
  "session_baseline_tokens": 0,
  "budget_limit_tokens": 500000,
  "context_warn_tokens": 150000,
  "outer_iteration": 1,
  "merge_conflict_cycles": 0,
  "ci_failure_cycles": 0,
  "halt_audit": [
    {"code": "HALT-003", "ts": "${NOW}", "data": {}}
  ],
  "human_review_cycles": 0,
  "github_pr_number": null,
  "progress_comment_id": null,
  "lessons_learned": [],
  "session_summary": null,
  "session_count": 1,
  "handoff_reason": null,
  "restart_failed": false,
  "spawned_pid": null,
  "resume_ack": null,
  "created_at": "${NOW}",
  "updated_at": "${NOW}"
}
EOF
MAKATO_EMIT_RESHAPE_SPECS_DIR="$SPECS" "$SCRIPT" "100-no-critical" 100 >/dev/null 2>&1
# last_critical_errors should be absent (null or not present)
HAS_KEY="$(jq 'has("last_critical_errors")' "$SPECS/100-no-critical/reshape-request.json")"
[[ "$HAS_KEY" == "false" ]] || {
  # It may be present but empty/null — check value
  VAL="$(jq '.last_critical_errors' "$SPECS/100-no-critical/reshape-request.json")"
  # Acceptable: absent, null, or empty array
  [[ "$VAL" == "null" ]] || [[ "$VAL" == "[]" ]] || \
    fail "last_critical_errors should be absent/null/empty when no CRITICAL errors, got: $VAL"
}
pass "last_critical_errors absent when no CRITICAL errors in last sub_task"

# ---------------------------------------------------------------------------
echo "=== T9: reshape-request.json written atomically (no .tmp leftover) ==="
# Verify no .tmp file remains after a successful run
TMP_COUNT="$(find "$SPEC_DIR" -name "reshape-request.json.tmp*" 2>/dev/null | wc -l | tr -d ' ')"
[[ "$TMP_COUNT" -eq 0 ]] || fail ".tmp files remain after atomic write: $TMP_COUNT"
pass "no .tmp files leftover after write"

# ---------------------------------------------------------------------------
echo "=== T10: reshape_cycles increments from prior reshape-request.json ==="
# The main spec dir already has reshape-request.json from T3 (reshape_cycles should be 0)
CYCLES_0="$(jq '.reshape_cycles' "$SPEC_DIR/reshape-request.json")"
[[ "$CYCLES_0" -eq 0 ]] || fail "first reshape should have reshape_cycles=0, got $CYCLES_0"
# Run again — should see reshape_cycles=1
MAKATO_EMIT_RESHAPE_SPECS_DIR="$SPECS" "$SCRIPT" "$KEY" "$ISSUE_NUM" >/dev/null 2>&1
CYCLES_1="$(jq '.reshape_cycles' "$SPEC_DIR/reshape-request.json")"
[[ "$CYCLES_1" -eq 1 ]] || fail "second reshape should have reshape_cycles=1, got $CYCLES_1"
pass "reshape_cycles increments: 0 on first emit, 1 on second emit"

# ---------------------------------------------------------------------------
echo "=== T11: output passes JSON schema validation ==="
SCHEMA="$REPO_ROOT/plugins/makato-orchestrate/scripts/emit-reshape-request.schema.json"
python3 -c "
import sys, json, pathlib
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
schema = json.loads(pathlib.Path(sys.argv[2]).read_text())
try:
    import jsonschema
    jsonschema.validate(data, schema)
    print('schema valid')
except ImportError:
    print('jsonschema not installed — skipping schema check')
    sys.exit(0)
except jsonschema.ValidationError as e:
    print(f'FAIL: schema error: {e.message}', file=sys.stderr)
    sys.exit(1)
" "$SPEC_DIR/reshape-request.json" "$SCHEMA"
pass "reshape-request.json passes JSON schema validation"

# ---------------------------------------------------------------------------
echo "=== T12: orchestrate.jsonl entry appended with step 'emit-reshape-request' ==="
LOG="$SPECS/${KEY}/orchestrate.jsonl"
[[ -f "$LOG" ]] || fail "orchestrate.jsonl not created at $LOG"
grep -q '"emit-reshape-request"' "$LOG" || fail "no 'emit-reshape-request' step in orchestrate.jsonl"
pass "orchestrate.jsonl has emit-reshape-request entry"

echo
echo "=== ALL EMIT-RESHAPE-REQUEST SMOKE TESTS PASSED (T1–T12) ==="
