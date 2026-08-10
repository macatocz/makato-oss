#!/usr/bin/env bash
# Smoke tests for scripts/generate-run-report.sh — per-issue final-envelope
# aggregation into a run report (#448). Run from the makato repo root:
#
#   plugins/makato-orchestrate/scripts/tests/generate-run-report-smoke-tests.sh
#
# Scenarios (issue #448 AC):
#   T1: mixed batch — one merged issue (github_pr_number) + one halted issue
#       (halt_audit entry). Report contains both verdicts; merged entry carries
#       pr_number; halted entry carries halt_code and halt_origin.
#   T2: HALT origin propagation — halt_origin in the report matches
#       halt_audit[-1].origin in the fixture state file.
#   T3: empty issue list — script exits 0 and emits an empty issues:[] report.
#   T4: missing workflow-state for an issue — entry has verdict:"unknown",
#       script exits 0.
#   T5: last-of-many halt_audit — halt_code/origin come from the LAST entry.
#   T6: legacy halt entry (no origin field) — halt_origin is null, not a crash.
#   T7: read-only — no state file or orchestrate.jsonl is written/mutated.
#   T8: --run-id override names the report file deterministically.
#
# Fully offline: fixtures are synthetic workflow-state-<issue>.json files under
# an injected MAKATO_REPORT_SPECS_DIR; output lands under MAKATO_LOOP_STATE_DIR.
# `gh` is never invoked. Mirrors loop-smoke-tests.sh / promote-ready-smoke-tests.sh.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
RR="$REPO_ROOT/plugins/makato-orchestrate/scripts/generate-run-report.sh"

SANDBOX="${CLAUDE_JOB_DIR:-/tmp}/run-report-smoke-$$"
SPECS="$SANDBOX/specs"
STATE="$SANDBOX/state"
mkdir -p "$SPECS" "$STATE"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

export MAKATO_REPORT_SPECS_DIR="$SPECS"
export MAKATO_LOOP_STATE_DIR="$STATE"

fail() { echo "  ✗ FAIL: $*" >&2; exit 1; }
pass() { echo "  ✓ $*"; }

# --- fixtures --------------------------------------------------------------
# #10 merged: current_phase=done, github_pr_number=123, empty halt_audit.
mkdir -p "$SPECS/10-merged"
jq -n '{issue_number:10,current_phase:"done",github_pr_number:123,
        halt_audit:[],updated_at:"2026-07-17T10:00:00.000Z"}' \
  >"$SPECS/10-merged/workflow-state-10.json"

# #20 halted: no PR, one HALT-003 entry (human origin).
mkdir -p "$SPECS/20-halted"
jq -n '{issue_number:20,current_phase:"implement",github_pr_number:null,
        halt_audit:[{code:"HALT-003",ts:"2026-07-17T11:00:00.000Z",
                     origin:"human",data:{reason:"structural"}}]}' \
  >"$SPECS/20-halted/workflow-state-20.json"

# #30 halted with MANY audit entries (last is HALT-008/auto) — T5.
mkdir -p "$SPECS/30-multi"
jq -n '{issue_number:30,current_phase:"implement",github_pr_number:null,
        halt_audit:[
          {code:"HALT-007B",ts:"2026-07-17T09:00:00.000Z",origin:"auto",data:{}},
          {code:"HALT-008",ts:"2026-07-17T12:30:00.000Z",origin:"transient",data:{}}
        ]}' \
  >"$SPECS/30-multi/workflow-state-30.json"

# #40 legacy halt entry (no origin field) — T6.
mkdir -p "$SPECS/40-legacy"
jq -n '{issue_number:40,current_phase:"implement",github_pr_number:null,
        halt_audit:[{code:"HALT-999",ts:"2026-07-17T13:00:00.000Z",data:{}}]}' \
  >"$SPECS/40-legacy/workflow-state-40.json"

# ---------------------------------------------------------------------------
echo "=== T1: mixed batch — merged + halted verdicts present ==="
report_path="$("$RR" 10 20 --run-id t1)" || fail "T1: script should exit 0"
[[ -f "$report_path" ]] || fail "T1: report file not written at $report_path"
jq -e '.issue_count == 2' "$report_path" >/dev/null \
  || fail "T1: issue_count should be 2; got $(jq '.issue_count' "$report_path")"
# merged entry
jq -e '.issues[] | select(.issue == 10)
       | .verdict == "merged" and .pr_number == 123' "$report_path" >/dev/null \
  || fail "T1: issue 10 should be merged with pr_number 123; got $(jq -c '.issues[]|select(.issue==10)' "$report_path")"
# halted entry
jq -e '.issues[] | select(.issue == 20)
       | .verdict == "halted" and .halt_code == "HALT-003"
         and .halt_origin == "human"' "$report_path" >/dev/null \
  || fail "T1: issue 20 should be halted HALT-003/human; got $(jq -c '.issues[]|select(.issue==20)' "$report_path")"
pass "mixed batch: merged(#10,PR123) + halted(#20,HALT-003/human)"

# ---------------------------------------------------------------------------
echo "=== T2: HALT origin propagation matches fixture halt_audit[-1].origin ==="
report_path="$("$RR" 20 --run-id t2)" || fail "T2: script should exit 0"
fixture_origin="$(jq -r '.halt_audit[-1].origin' "$SPECS/20-halted/workflow-state-20.json")"
report_origin="$(jq -r '.issues[] | select(.issue == 20) | .halt_origin' "$report_path")"
[[ "$report_origin" == "$fixture_origin" ]] \
  || fail "T2: halt_origin should be '$fixture_origin'; got '$report_origin'"
pass "halt_origin propagated from halt_audit[-1] ($report_origin)"

# ---------------------------------------------------------------------------
echo "=== T3: empty issue list → exit 0, issues:[] ==="
report_path="$("$RR" --run-id t3)" || fail "T3: script should exit 0 on empty list"
jq -e '.issue_count == 0 and (.issues | length) == 0' "$report_path" >/dev/null \
  || fail "T3: empty run should have issue_count 0 and issues []"
pass "empty issue list emits an empty report, exit 0"

# ---------------------------------------------------------------------------
echo "=== T4: missing workflow-state → verdict:unknown, exit 0 ==="
report_path="$("$RR" 99 --run-id t4)" || fail "T4: script should exit 0 for a missing issue"
jq -e '.issues[] | select(.issue == 99)
       | .verdict == "unknown" and .pr_number == null
         and .halt_code == null' "$report_path" >/dev/null \
  || fail "T4: issue 99 should be verdict:unknown; got $(jq -c '.issues[]|select(.issue==99)' "$report_path")"
pass "missing workflow-state → unknown verdict, no error"

# ---------------------------------------------------------------------------
echo "=== T5: multi-entry halt_audit → code/origin from the LAST entry ==="
report_path="$("$RR" 30 --run-id t5)" || fail "T5: script should exit 0"
jq -e '.issues[] | select(.issue == 30)
       | .verdict == "halted" and .halt_code == "HALT-008"
         and .halt_origin == "transient"' "$report_path" >/dev/null \
  || fail "T5: issue 30 should carry the LAST audit entry (HALT-008/transient); got $(jq -c '.issues[]|select(.issue==30)' "$report_path")"
pass "multi-entry halt_audit uses the last entry (HALT-008/transient)"

# ---------------------------------------------------------------------------
echo "=== T6: legacy halt entry (no origin) → halt_origin null, no crash ==="
report_path="$("$RR" 40 --run-id t6)" || fail "T6: script should exit 0 on a legacy entry"
jq -e '.issues[] | select(.issue == 40)
       | .verdict == "halted" and .halt_code == "HALT-999"
         and .halt_origin == null' "$report_path" >/dev/null \
  || fail "T6: issue 40 should be halted with halt_origin null; got $(jq -c '.issues[]|select(.issue==40)' "$report_path")"
pass "legacy halt entry → halt_origin null, verdict still halted"

# ---------------------------------------------------------------------------
echo "=== T7: read-only — no state-file or orchestrate.jsonl mutation ==="
# Snapshot every fixture + any orchestrate.jsonl before, run, diff after.
before="$(find "$SPECS" -type f -exec sha256sum {} \; | sort)"
"$RR" 10 20 30 40 99 --run-id t7 >/dev/null || fail "T7: script should exit 0"
after="$(find "$SPECS" -type f -exec sha256sum {} \; | sort)"
[[ "$before" == "$after" ]] \
  || fail "T7: SPECS_DIR files must be untouched (read-only contract); diff detected"
[[ -z "$(find "$SPECS" -name 'orchestrate.jsonl' 2>/dev/null)" ]] \
  || fail "T7: report generation must not create orchestrate.jsonl"
pass "read-only: no fixture state file mutated, no orchestrate.jsonl written"

# ---------------------------------------------------------------------------
echo "=== T8: --run-id override names the report file deterministically ==="
report_path="$("$RR" 10 --run-id my-custom-run)" || fail "T8: script should exit 0"
[[ "$report_path" == *"/run-report-my-custom-run.json" ]] \
  || fail "T8: report path should end with run-report-my-custom-run.json; got $report_path"
[[ -f "$report_path" ]] || fail "T8: custom-named report file not found"
jq -e '.run_id == "my-custom-run"' "$report_path" >/dev/null \
  || fail "T8: report run_id should be my-custom-run"
pass "--run-id override names the report file + stamps run_id"

echo "=== ALL TESTS PASSED (T1–T8 run-report aggregation, #448) ==="
