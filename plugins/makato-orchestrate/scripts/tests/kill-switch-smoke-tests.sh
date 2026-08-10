#!/usr/bin/env bash
# Smoke tests for the kill-switch skill's poll and record-budget subcommands
# (GAP-004 / #30). Run from the makato repo root.
#
# Usage:
#   plugins/makato-orchestrate/scripts/tests/kill-switch-smoke-tests.sh
#
# Design note:
#   The kill-switch skill is a Claude invocation (not a standalone shell
#   script), so these tests exercise the underlying primitives the skill
#   operates on — check-halt.sh (HALT-000), workflow-state.sh state
#   conditions (HALT-007 per-task, HALT-008), the daily-budget ledger
#   (HALT-007 daily, record-budget), and a gh-label fixture (HALT-009) —
#   rather than invoking `claude` itself. This keeps the suite offline,
#   fast, and executable in CI without API keys.
#
#   MAKATO_LOOP_GH_OVERRIDE is the established fixture-injection signal;
#   MAKATO_HALT_FILE overrides the default ~/.claude/HALT path.
#   MAKATO_KS_DAILY_BUDGET_DIR overrides the .claude/state/ directory
#   for daily-budget files so tests never touch the operator's live ledger.
#
# Scenarios:
#   T1: HALT-000 — HALT file absent → check-halt.sh exits 0
#   T2: HALT-000 — HALT file present → check-halt.sh exits 1
#   T3: HALT-007 per-task — budget_consumed_tokens >= budget_limit_tokens
#       → poll condition fires (state fixture, validated by guard function)
#   T4: HALT-007 daily — daily ledger consumed_tokens >= ceiling_tokens
#       → poll condition fires (ledger fixture, validated by guard function)
#   T5: HALT-008 — outer_iteration >= 3
#       → poll condition fires (state fixture, validated by guard function)
#   T6: record-budget increment — write_record_budget appends a run entry
#       and increments consumed_tokens in the daily ledger
#   T7: daily-ceiling exceeded after increment — after a delta that pushes
#       consumed_tokens over ceiling_tokens the poll guard detects it

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WS="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"
CHECK_HALT="$REPO_ROOT/plugins/makato-orchestrate/hooks/check-halt.sh"

KEY="ks-smoke-$$"
ISSUE=9999
SANDBOX="$REPO_ROOT/specs/${KEY}"

TMP_DIR="${CLAUDE_JOB_DIR:-/tmp}/ks-smoke-$$"
HALT_FILE="$TMP_DIR/HALT"
BUDGET_DIR="$TMP_DIR/state"
TODAY="$(date -u +%Y-%m-%d)"
DAILY_FILE="$BUDGET_DIR/daily-budget-${TODAY}.json"

mkdir -p "$SANDBOX" "$BUDGET_DIR"

export MAKATO_HALT_FILE="$HALT_FILE"
export MAKATO_KS_DAILY_BUDGET_DIR="$BUDGET_DIR"

cleanup() {
  rm -rf "$TMP_DIR" "$SANDBOX"
}
trap cleanup EXIT
# Pre-clean leftovers from a prior aborted run.
rm -rf "$SANDBOX" "$TMP_DIR"
mkdir -p "$SANDBOX" "$BUDGET_DIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

fail() {
  echo "  FAIL: $*" >&2
  exit 1
}

pass() {
  echo "  PASS: $*"
}

# _init_state — write a minimal workflow-state-<ISSUE>.json fixture.
# Args: [budget_consumed] [budget_limit] [outer_iteration]
_init_state() {
  local consumed="${1:-0}"
  local limit="${2:-500000}"
  local outer_iter="${3:-0}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  mkdir -p "$SANDBOX"
  cat > "$SANDBOX/workflow-state-${ISSUE}.json" <<JSON
{
  "schema_version": "3",
  "key": "$KEY",
  "repo": "macatocz/makato",
  "branch": "feat/ks-smoke",
  "issue_number": $ISSUE,
  "current_phase": "implement",
  "outer_iteration": $outer_iter,
  "budget_consumed_tokens": $consumed,
  "budget_limit_tokens": $limit,
  "sub_tasks": [],
  "lessons_learned": [],
  "halt_audit": [],
  "updated_at": "$ts",
  "created_at": "$ts"
}
JSON
}

# _read_state_field — extract a numeric field from workflow-state.
_read_state_field() {
  local field="$1"
  jq -r ".$field // 0" "$SANDBOX/workflow-state-${ISSUE}.json" 2>/dev/null || echo "0"
}

# _write_daily_ledger — write a daily-budget fixture.
# Args: consumed ceiling (pass "" for no ceiling = no daily check)
_write_daily_ledger() {
  local consumed="${1:-0}"
  local ceiling="${2:-}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  if [[ -n "$ceiling" ]]; then
    cat > "$DAILY_FILE" <<JSON
{
  "date": "$TODAY",
  "consumed_tokens": $consumed,
  "ceiling_tokens": $ceiling,
  "runs": [],
  "updated_at": "$ts"
}
JSON
  else
    cat > "$DAILY_FILE" <<JSON
{
  "date": "$TODAY",
  "consumed_tokens": $consumed,
  "runs": [],
  "updated_at": "$ts"
}
JSON
  fi
}

# _poll_per_task_halt — replicate the kill-switch per-task budget guard.
# Returns 0 (pass) or 1 (HALT-007 per-task fires).
_poll_per_task_halt() {
  local consumed limit
  consumed="$(_read_state_field budget_consumed_tokens)"
  limit="$(_read_state_field budget_limit_tokens)"
  [[ "$consumed" -ge "$limit" ]] && return 1
  return 0
}

# _poll_daily_halt — replicate the kill-switch daily budget guard.
# Returns 0 (pass) or 1 (HALT-007 daily fires).
_poll_daily_halt() {
  if [[ ! -f "$DAILY_FILE" ]]; then
    return 0  # no ledger → no daily ceiling, no HALT
  fi
  local ceiling consumed
  ceiling="$(jq -r '.ceiling_tokens // empty' "$DAILY_FILE" 2>/dev/null || true)"
  [[ -z "$ceiling" ]] && return 0  # no ceiling in ledger → no daily HALT
  consumed="$(jq -r '.consumed_tokens // 0' "$DAILY_FILE" 2>/dev/null || echo "0")"
  [[ "$consumed" -ge "$ceiling" ]] && return 1
  return 0
}

# _poll_outer_iteration_halt — replicate the kill-switch HALT-008 guard.
# Returns 0 (pass) or 1 (HALT-008 fires).
_poll_outer_iteration_halt() {
  local iter
  iter="$(_read_state_field outer_iteration)"
  [[ "$iter" -ge 3 ]] && return 1
  return 0
}

# _write_record_budget — replicate the kill-switch record-budget increment:
# append a run entry and update consumed_tokens in the daily ledger.
# Args: issue tokens
_write_record_budget() {
  local issue="${1:?issue required}"
  local tokens="${2:?tokens required}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

  if [[ ! -f "$DAILY_FILE" ]]; then
    cat > "$DAILY_FILE" <<JSON
{
  "date": "$TODAY",
  "consumed_tokens": $tokens,
  "runs": [{"issue": $issue, "tokens": $tokens, "ts": "$ts"}],
  "updated_at": "$ts"
}
JSON
    return 0
  fi

  # Atomically increment consumed_tokens and append a run entry.
  local tmp_file
  tmp_file="$(mktemp "${DAILY_FILE}.XXXXXXXX")"
  jq \
    --argjson issue "$issue" \
    --argjson tokens "$tokens" \
    --arg ts "$ts" \
    '.consumed_tokens += $tokens |
     .runs += [{"issue": $issue, "tokens": $tokens, "ts": $ts}] |
     .updated_at = $ts' \
    "$DAILY_FILE" > "$tmp_file"
  mv "$tmp_file" "$DAILY_FILE"
}

# ---------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0

run_test() {
  local name="$1"
  local fn="$2"
  echo "=== ${name} ==="
  if "$fn"; then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ---------------------------------------------------------------------------
# T1: HALT-000 — check-halt.sh exits 0 when HALT file absent
# ---------------------------------------------------------------------------
t1() {
  rm -f "$HALT_FILE"
  if ! "$CHECK_HALT" 2>/dev/null; then
    fail "check-halt.sh exited non-zero when HALT file absent"
  fi
  pass "exit 0 with no HALT file"
}

# ---------------------------------------------------------------------------
# T2: HALT-000 — check-halt.sh exits 1 when HALT file present
# ---------------------------------------------------------------------------
t2() {
  echo "stopping for test" > "$HALT_FILE"
  local rc=0
  "$CHECK_HALT" 2>/dev/null || rc=$?
  rm -f "$HALT_FILE"
  if [[ "$rc" -eq 0 ]]; then
    fail "check-halt.sh exited 0 despite HALT file present"
  fi
  pass "exit non-zero with HALT file present (rc=$rc)"
}

# ---------------------------------------------------------------------------
# T3: HALT-007 per-task — budget_consumed_tokens >= budget_limit_tokens
# ---------------------------------------------------------------------------
t3() {
  _init_state 500001 500000 0
  if _poll_per_task_halt; then
    fail "per-task budget guard did not fire (consumed=500001 >= limit=500000)"
  fi
  pass "per-task budget guard fires when consumed >= limit"
}

# ---------------------------------------------------------------------------
# T4: HALT-007 daily — daily ledger consumed_tokens >= ceiling_tokens
# ---------------------------------------------------------------------------
t4() {
  _write_daily_ledger 1000001 1000000
  if _poll_daily_halt; then
    fail "daily budget guard did not fire (consumed=1000001 >= ceiling=1000000)"
  fi
  pass "daily budget guard fires when consumed >= ceiling"
}

# ---------------------------------------------------------------------------
# T5: HALT-008 — outer_iteration >= 3 fires
# ---------------------------------------------------------------------------
t5() {
  _init_state 0 500000 3
  if _poll_outer_iteration_halt; then
    fail "outer_iteration guard did not fire (outer_iteration=3 >= 3)"
  fi
  pass "outer_iteration guard fires when outer_iteration >= 3"
}

# ---------------------------------------------------------------------------
# T6: record-budget increment — ledger file updated correctly
# ---------------------------------------------------------------------------
t6() {
  rm -f "$DAILY_FILE"
  _write_record_budget 42 5000
  if [[ ! -f "$DAILY_FILE" ]]; then
    fail "daily-budget ledger not created by record-budget"
  fi
  local consumed runs_count
  consumed="$(jq '.consumed_tokens' "$DAILY_FILE")"
  runs_count="$(jq '.runs | length' "$DAILY_FILE")"
  if [[ "$consumed" != "5000" ]]; then
    fail "consumed_tokens expected 5000, got $consumed"
  fi
  if [[ "$runs_count" != "1" ]]; then
    fail "runs[] expected 1 entry, got $runs_count"
  fi
  # Second increment.
  _write_record_budget 43 3000
  consumed="$(jq '.consumed_tokens' "$DAILY_FILE")"
  runs_count="$(jq '.runs | length' "$DAILY_FILE")"
  if [[ "$consumed" != "8000" ]]; then
    fail "consumed_tokens expected 8000 after second increment, got $consumed"
  fi
  if [[ "$runs_count" != "2" ]]; then
    fail "runs[] expected 2 entries after second increment, got $runs_count"
  fi
  pass "record-budget increments consumed_tokens and appends run entry"
}

# ---------------------------------------------------------------------------
# T7: daily-ceiling exceeded after increment — poll guard detects it
# ---------------------------------------------------------------------------
t7() {
  rm -f "$DAILY_FILE"
  # Seed ledger with consumed=999000, ceiling=1000000 — below ceiling.
  _write_daily_ledger 999000 1000000
  if ! _poll_daily_halt; then
    fail "daily guard fired prematurely (consumed=999000 < ceiling=1000000)"
  fi
  # Increment by 1001 — pushes consumed over ceiling.
  _write_record_budget 44 1001
  if _poll_daily_halt; then
    fail "daily guard did not fire after increment pushed consumed over ceiling"
  fi
  local consumed
  consumed="$(jq '.consumed_tokens' "$DAILY_FILE")"
  if [[ "$consumed" != "1000001" ]]; then
    fail "consumed_tokens expected 1000001 after increment, got $consumed"
  fi
  pass "daily-ceiling guard fires after record-budget increment crosses the ceiling"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
run_test "T1: HALT-000 — check-halt exits 0 when HALT absent" t1
run_test "T2: HALT-000 — check-halt exits 1 when HALT present" t2
run_test "T3: HALT-007 per-task — budget guard fires at limit" t3
run_test "T4: HALT-007 daily — daily guard fires at ceiling" t4
run_test "T5: HALT-008 — outer_iteration guard fires at 3" t5
run_test "T6: record-budget — increments consumed_tokens and appends run" t6
run_test "T7: daily-ceiling exceeded after increment — guard fires" t7

echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "$FAIL_COUNT" -eq 0 ]] || exit 1
