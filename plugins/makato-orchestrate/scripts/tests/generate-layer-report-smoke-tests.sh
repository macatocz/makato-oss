#!/usr/bin/env bash
# Smoke tests for scripts/generate-layer-report.sh — HALT-by-layer aggregation
# across issues (#593). Run from the makato repo root:
#
#   plugins/makato-orchestrate/scripts/tests/generate-layer-report-smoke-tests.sh
#
# Scenarios (issue #593 AC-2, AC-3):
#   T1: single HALT-006 event → bottleneck_layer:"task-spec", halt_events_found:1
#   T2: mixed HALTs across multiple issues → correct by_layer counts + bottleneck
#   T3: HALT-007B event included in counts (has a layer, environment)
#   T4: orchestrate.jsonl with no halt lines → halt_events_found:0, bottleneck:null
#   T5: missing orchestrate.jsonl for a requested issue → graceful skip
#   T6: unknown halt code → counted in "unknown" layer, no crash
#   T7: read-only — no orchestrate.jsonl written/mutated
#   T8: --run-id override names the report file deterministically
#
# Fully offline: fixtures are synthetic orchestrate.jsonl files under an
# injected MAKATO_REPORT_SPECS_DIR; output lands under MAKATO_LOOP_STATE_DIR.
# Mirrors generate-run-report-smoke-tests.sh conventions.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LR="$REPO_ROOT/plugins/makato-orchestrate/scripts/generate-layer-report.sh"

SANDBOX="${CLAUDE_JOB_DIR:-/tmp}/layer-report-smoke-$$"
SPECS="$SANDBOX/specs"
STATE="$SANDBOX/state"
mkdir -p "$SPECS" "$STATE"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

export MAKATO_REPORT_SPECS_DIR="$SPECS"
export MAKATO_LOOP_STATE_DIR="$STATE"

fail() { echo "  FAIL: $*" >&2; exit 1; }
pass() { echo "  OK $*"; }

# ---------------------------------------------------------------------------
# Helpers to write synthetic orchestrate.jsonl fixtures.
# ---------------------------------------------------------------------------
_write_halt_line() {
  local issue="$1" halt_code="$2" origin="${3:-}"
  local dir="$SPECS/${issue}-test-issue"
  mkdir -p "$dir"
  local origin_field=""
  if [[ -n "$origin" ]]; then
    origin_field=",\"origin\":\"${origin}\""
  fi
  echo "{\"ts\":\"2026-01-01T00:00:00.000Z\",\"skill\":\"po-agent\",\"issue\":${issue},\"step\":\"halt\",\"status\":\"error\",\"data\":{\"halt_code\":\"${halt_code}\"${origin_field}}}" \
    >> "$dir/orchestrate.jsonl"
}

_write_nonhalt_line() {
  local issue="$1"
  local dir="$SPECS/${issue}-test-issue"
  mkdir -p "$dir"
  echo "{\"ts\":\"2026-01-01T00:00:01.000Z\",\"skill\":\"po-agent\",\"issue\":${issue},\"step\":\"dispatch\",\"status\":\"ok\",\"data\":{}}" \
    >> "$dir/orchestrate.jsonl"
}

# ---------------------------------------------------------------------------
echo "=== T1: single HALT-006 → bottleneck:task-spec, halt_events_found:1 ==="
rm -rf "$SPECS/10-test-issue" "$STATE"/*.json 2>/dev/null || true
mkdir -p "$SPECS/10-test-issue"
_write_halt_line 10 "HALT-006"
report_path="$("$LR" --issues "10" --run-id t1)" || fail "T1: script should exit 0"
[[ -f "$report_path" ]] || fail "T1: report file not written"
jq -e '.halt_events_found == 1' "$report_path" >/dev/null \
  || fail "T1: halt_events_found should be 1; got $(jq '.halt_events_found' "$report_path")"
jq -e '.bottleneck_layer == "task-spec"' "$report_path" >/dev/null \
  || fail "T1: bottleneck_layer should be task-spec; got $(jq '.bottleneck_layer' "$report_path")"
jq -e '.by_layer["task-spec"] == 1' "$report_path" >/dev/null \
  || fail "T1: by_layer.task-spec should be 1"
pass "single HALT-006 → bottleneck:task-spec, halt_events_found:1"

# ---------------------------------------------------------------------------
echo "=== T2: mixed HALTs across multiple issues → correct counts + bottleneck ==="
rm -rf "$SPECS/20-test-issue" "$SPECS/21-test-issue"
# Issue 20: HALT-003 (verification) x2
_write_halt_line 20 "HALT-003"
_write_halt_line 20 "HALT-003"
# Issue 21: HALT-007 (environment) x1, HALT-001 (verification) x1
_write_halt_line 21 "HALT-007"
_write_halt_line 21 "HALT-001"
# Total: verification=3, environment=1 → bottleneck: verification
report_path="$("$LR" --issues "20 21" --run-id t2)" || fail "T2: script should exit 0"
jq -e '.halt_events_found == 4' "$report_path" >/dev/null \
  || fail "T2: halt_events_found should be 4; got $(jq '.halt_events_found' "$report_path")"
jq -e '.by_layer.verification == 3' "$report_path" >/dev/null \
  || fail "T2: by_layer.verification should be 3; got $(jq '.by_layer.verification' "$report_path")"
jq -e '.by_layer.environment == 1' "$report_path" >/dev/null \
  || fail "T2: by_layer.environment should be 1; got $(jq '.by_layer.environment' "$report_path")"
jq -e '.bottleneck_layer == "verification"' "$report_path" >/dev/null \
  || fail "T2: bottleneck_layer should be verification; got $(jq '.bottleneck_layer' "$report_path")"
jq -e '.bottleneck_count == 3' "$report_path" >/dev/null \
  || fail "T2: bottleneck_count should be 3; got $(jq '.bottleneck_count' "$report_path")"
pass "mixed HALTs: verification=3, environment=1 → bottleneck:verification"

# ---------------------------------------------------------------------------
echo "=== T3: HALT-007B (auto origin, environment layer) is counted ==="
rm -rf "$SPECS/30-test-issue"
_write_halt_line 30 "HALT-007B"
report_path="$("$LR" 30 --run-id t3)" || fail "T3: script should exit 0"
jq -e '.halt_events_found == 1' "$report_path" >/dev/null \
  || fail "T3: halt_events_found should be 1"
jq -e '.by_layer.environment == 1' "$report_path" >/dev/null \
  || fail "T3: HALT-007B should count in environment layer; got $(jq '.by_layer.environment' "$report_path")"
jq -e '.bottleneck_layer == "environment"' "$report_path" >/dev/null \
  || fail "T3: bottleneck_layer should be environment; got $(jq '.bottleneck_layer' "$report_path")"
pass "HALT-007B counted in environment layer, bottleneck:environment"

# ---------------------------------------------------------------------------
echo "=== T4: no halt lines → halt_events_found:0, bottleneck_layer:null ==="
rm -rf "$SPECS/40-test-issue"
_write_nonhalt_line 40
report_path="$("$LR" 40 --run-id t4)" || fail "T4: script should exit 0"
jq -e '.halt_events_found == 0' "$report_path" >/dev/null \
  || fail "T4: halt_events_found should be 0; got $(jq '.halt_events_found' "$report_path")"
jq -e '.bottleneck_layer == null' "$report_path" >/dev/null \
  || fail "T4: bottleneck_layer should be null; got $(jq '.bottleneck_layer' "$report_path")"
pass "no halt lines → halt_events_found:0, bottleneck_layer:null"

# ---------------------------------------------------------------------------
echo "=== T5: missing orchestrate.jsonl → graceful skip, issues_scanned excludes it ==="
# Issue 99 has no folder at all.
report_path="$("$LR" --issues "99" --run-id t5 2>/dev/null)" || fail "T5: script should exit 0"
jq -e '.issues_scanned == 0' "$report_path" >/dev/null \
  || fail "T5: issues_scanned should be 0 (skipped); got $(jq '.issues_scanned' "$report_path")"
jq -e '.halt_events_found == 0' "$report_path" >/dev/null \
  || fail "T5: halt_events_found should be 0"
pass "missing orchestrate.jsonl → graceful skip, issues_scanned:0"

# ---------------------------------------------------------------------------
echo "=== T6: unknown halt code → counted in 'unknown' layer, no crash ==="
rm -rf "$SPECS/50-test-issue"
_write_halt_line 50 "HALT-BOGUS-999"
report_path="$("$LR" 50 --run-id t6)" || fail "T6: script should exit 0"
jq -e '.halt_events_found == 1' "$report_path" >/dev/null \
  || fail "T6: halt_events_found should be 1"
jq -e '.by_layer.unknown == 1' "$report_path" >/dev/null \
  || fail "T6: unknown code should land in by_layer.unknown; got $(jq '.by_layer.unknown' "$report_path")"
pass "unknown halt code → by_layer.unknown:1, no crash"

# ---------------------------------------------------------------------------
echo "=== T7: read-only — no orchestrate.jsonl written/mutated ==="
before="$(find "$SPECS" -type f -exec sha256sum {} \; | sort)"
"$LR" 10 20 21 30 40 50 --run-id t7 >/dev/null || fail "T7: script should exit 0"
after="$(find "$SPECS" -type f -exec sha256sum {} \; | sort)"
[[ "$before" == "$after" ]] \
  || fail "T7: SPECS_DIR files must be untouched (read-only contract)"
pass "read-only: no fixture orchestrate.jsonl mutated"

# ---------------------------------------------------------------------------
echo "=== T8: --run-id override names the report file deterministically ==="
report_path="$("$LR" 10 --run-id my-layer-run)" || fail "T8: script should exit 0"
[[ "$report_path" == *"/layer-report-my-layer-run.json" ]] \
  || fail "T8: report path should end with layer-report-my-layer-run.json; got $report_path"
[[ -f "$report_path" ]] || fail "T8: custom-named report file not found"
jq -e '.run_id == "my-layer-run"' "$report_path" >/dev/null \
  || fail "T8: report run_id should be my-layer-run"
pass "--run-id override names the report file + stamps run_id"

echo "=== ALL TESTS PASSED (T1-T8 generate-layer-report aggregation, #593) ==="
