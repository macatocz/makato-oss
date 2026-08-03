#!/usr/bin/env bash
# Smoke tests for scripts/generate-quality-doc.sh — per-domain quality scorecard
# (#598). Run from the makato repo root:
#
#   plugins/makato-orchestrate/scripts/generate-quality-doc-smoke-tests.sh
#
# Scenarios:
#   T1: no issues in domain → scorecard written with empty table body, no error.
#   T2: single issue with tests_passing:42, gate-sensors findings:0, no halts
#       → row shows 42 / Yes / 0 / - / 0.
#   T3: single issue with gate-sensors findings:3 → sensor_clean = No.
#   T4: single issue with two halt_audit entries → HALTs = 2, Last HALT = code.
#   T5: re-run on existing <domain>-quality.md that already contains an Evolution
#       Log section → section preserved, scorecard rows updated without duplication.
#   T6: build.jsonl absent for one issue → that row shows - for all metrics,
#       script exits 0.
#
# Fully offline: fixtures live under a temp dir injected via
# MAKATO_QUALITY_SPECS_DIR. No network calls.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
QD="$REPO_ROOT/plugins/makato-orchestrate/scripts/generate-quality-doc.sh"

SANDBOX="${CLAUDE_JOB_DIR:-/tmp}/quality-doc-smoke-$$"
SPECS="$SANDBOX/specs"
mkdir -p "$SPECS"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

export MAKATO_QUALITY_SPECS_DIR="$SPECS"

fail() { echo "  FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# write_build_jsonl <folder> — write a build.jsonl with a known-good test entry.
write_build_jsonl_full() {
  local folder="$1" tests_passing="$2" sensor_findings="$3"
  cat >"$folder/build.jsonl" <<EOF
{"ts":"2026-08-01T10:00:00.000Z","skill":"build-implement-tdd","step":"task","status":"green","data":{"tests_passing":${tests_passing}}}
{"ts":"2026-08-01T10:05:00.000Z","skill":"build-sensors","step":"gate-sensors","status":"ok","data":{"findings":${sensor_findings}}}
EOF
}

write_workflow_state() {
  local folder="$1" issue="$2"
  shift 2
  # remaining args: halt entries as JSON objects separated by spaces (packed by caller)
  local halts_json="$1"
  jq -n \
    --argjson issue "$issue" \
    --argjson ha "$halts_json" \
    '{issue_number: $issue, current_phase: "done", github_pr_number: 99, halt_audit: $ha}' \
    >"$folder/workflow-state-${issue}.json"
}

write_plan_md() {
  local folder="$1" domain="$2"
  cat >"$folder/plan.md" <<EOF
# Test plan
domain: ${domain}

## Tasks
- task one
EOF
}

# ---------------------------------------------------------------------------
echo "=== T1: no issues in domain → empty table body, exit 0 ==="
mkdir -p "$SPECS/100-other-domain"
write_plan_md "$SPECS/100-other-domain" "other"
# No issues with domain:t1test
bash "$QD" --domain t1test 2>/dev/null || fail "T1: script should exit 0 with no matching issues"
MASTER="$SPECS/master/t1test-quality.md"
[[ -f "$MASTER" ]] || fail "T1: master file should be created at $MASTER"
# Table body is empty — no data rows beyond the header separator
body_rows="$(grep -E '^\| #' "$MASTER" || true)"
[[ -z "$body_rows" ]] || fail "T1: should be no data rows; found: $body_rows"
pass "empty domain → scorecard written with no data rows, exit 0"

# ---------------------------------------------------------------------------
echo "=== T2: tests_passing=42, findings=0, no halts → 42/Yes/0/-/0 ==="
mkdir -p "$SPECS/200-feat-alpha"
write_plan_md "$SPECS/200-feat-alpha" "t2test"
write_build_jsonl_full "$SPECS/200-feat-alpha" 42 0
write_workflow_state "$SPECS/200-feat-alpha" 200 "[]"
bash "$QD" --domain t2test 2>/dev/null || fail "T2: script should exit 0"
MASTER="$SPECS/master/t2test-quality.md"
[[ -f "$MASTER" ]] || fail "T2: master file not created"
row="$(grep '| #200' "$MASTER")" || fail "T2: row for #200 not found"
echo "$row" | grep -q "| 42 |" || fail "T2: tests_passing should be 42; row: $row"
echo "$row" | grep -q "| Yes |" || fail "T2: sensor_clean should be Yes; row: $row"
echo "$row" | grep -q "| 0 | - | 0 |" || fail "T2: HALTs=0, last=-, struct=0 expected; row: $row"
pass "single issue: 42 / Yes / 0 / - / 0"

# ---------------------------------------------------------------------------
echo "=== T3: gate-sensors findings=3 → sensor_clean = No ==="
mkdir -p "$SPECS/300-feat-beta"
write_plan_md "$SPECS/300-feat-beta" "t3test"
write_build_jsonl_full "$SPECS/300-feat-beta" 5 3
write_workflow_state "$SPECS/300-feat-beta" 300 "[]"
bash "$QD" --domain t3test 2>/dev/null || fail "T3: script should exit 0"
MASTER="$SPECS/master/t3test-quality.md"
row="$(grep '| #300' "$MASTER")" || fail "T3: row for #300 not found"
echo "$row" | grep -q "| No |" || fail "T3: sensor_clean should be No; row: $row"
pass "findings=3 → sensor_clean=No"

# ---------------------------------------------------------------------------
echo "=== T4: two halt_audit entries → HALTs=2, Last HALT = HALT-003 ==="
mkdir -p "$SPECS/400-feat-gamma"
write_plan_md "$SPECS/400-feat-gamma" "t4test"
write_build_jsonl_full "$SPECS/400-feat-gamma" 10 0
write_workflow_state "$SPECS/400-feat-gamma" 400 \
  '[{"code":"HALT-007","ts":"2026-08-01T11:00:00.000Z"},{"code":"HALT-003","ts":"2026-08-01T12:00:00.000Z"}]'
bash "$QD" --domain t4test 2>/dev/null || fail "T4: script should exit 0"
MASTER="$SPECS/master/t4test-quality.md"
row="$(grep '| #400' "$MASTER")" || fail "T4: row for #400 not found"
echo "$row" | grep -q "| 2 |" || fail "T4: HALTs should be 2; row: $row"
echo "$row" | grep -q "HALT-003" || fail "T4: Last HALT should be HALT-003; row: $row"
pass "two halt_audit entries → HALTs=2, Last HALT=HALT-003"

# ---------------------------------------------------------------------------
echo "=== T5: re-run preserves Evolution Log, updates scorecard without duplication ==="
mkdir -p "$SPECS/500-feat-delta"
write_plan_md "$SPECS/500-feat-delta" "t5test"
write_build_jsonl_full "$SPECS/500-feat-delta" 7 0
write_workflow_state "$SPECS/500-feat-delta" 500 "[]"
# First run
bash "$QD" --domain t5test 2>/dev/null || fail "T5: first run should exit 0"
MASTER="$SPECS/master/t5test-quality.md"
# Inject an Evolution Log section (as archive-spec.sh would)
cat >>"$MASTER" <<'EVLOG'

## Evolution Log

| Date | Story | Action |
|------|-------|--------|
| 2026-08-01 | 500-feat-delta | archived |
EVLOG
# Second run (re-run)
write_build_jsonl_full "$SPECS/500-feat-delta" 99 0
bash "$QD" --domain t5test 2>/dev/null || fail "T5: second run should exit 0"
# Evolution Log must still be present
grep -q "## Evolution Log" "$MASTER" || fail "T5: Evolution Log section was destroyed"
# Exactly one data row (no duplication)
data_rows="$(grep -cE '^\| #500' "$MASTER" || true)"
[[ "$data_rows" -eq 1 ]] || fail "T5: expected 1 data row, got $data_rows (duplication?)"
# Row reflects updated tests_passing=99
row="$(grep '| #500' "$MASTER")"
echo "$row" | grep -q "| 99 |" || fail "T5: scorecard should show updated tests_passing=99; row: $row"
pass "re-run updates scorecard, preserves Evolution Log, no row duplication"

# ---------------------------------------------------------------------------
echo "=== T6: build.jsonl absent → all metrics dash, exit 0 ==="
mkdir -p "$SPECS/600-feat-epsilon"
write_plan_md "$SPECS/600-feat-epsilon" "t6test"
# No build.jsonl, but workflow-state present
write_workflow_state "$SPECS/600-feat-epsilon" 600 "[]"
bash "$QD" --domain t6test 2>/dev/null || fail "T6: script should exit 0 when build.jsonl absent"
MASTER="$SPECS/master/t6test-quality.md"
[[ -f "$MASTER" ]] || fail "T6: master file not created"
row="$(grep '| #600' "$MASTER")" || fail "T6: row for #600 not found"
# All three build-derived cells should be dash
echo "$row" | grep -q "| - | - |" || fail "T6: missing build.jsonl should produce - cells; row: $row"
pass "absent build.jsonl → all metrics dash, exit 0"

# ---------------------------------------------------------------------------
echo "=== ALL TESTS PASSED (T1–T6 quality-doc scorecard, #598) ==="
