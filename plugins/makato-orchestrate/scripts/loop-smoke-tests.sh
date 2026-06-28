#!/usr/bin/env bash
# Smoke tests for scripts/loop.sh — the autonomous polling driver
# (GAP-007 / #33). Run from the makato repo root.
#
# Usage:
#   plugins/makato-orchestrate/scripts/loop-smoke-tests.sh
#
# Scenarios (per issue #33 AC):
#   T1: check-halt returns 0 when HALT file absent
#   T2: check-halt returns 1 when HALT file present
#   T3: dispatch <issue> --dry-run writes active_workflow and clears it
#   T4: dispatch refuses while another active_workflow is in flight
#   T5: in_flight_issues skips workflow-state.json with phase=done
#   T6: in_flight_issues includes workflow-state.json with phase=implement
#   T7: run --once --dry-run polls, writes status, exits cleanly without dispatch
#   T8: run --once exits cleanly when HALT file present (no dispatch)
#   T9: run --once dispatches the first untracked issue via MAKATO_LOOP_DRY_DISPATCH
#   T10: poll filters by Status — items at "Todo" / "In progress" are excluded
#   T11: poll filters out non-Issue content (DraftIssue, PullRequest)
#
# A fixture file is injected via MAKATO_LOOP_GH_OVERRIDE so `gh` is not
# invoked. Test isolation uses MAKATO_LOOP_STATE_DIR + ephemeral spec
# folders under specs/gap-007-loop-smoke*.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LOOP="$REPO_ROOT/plugins/makato-orchestrate/scripts/loop.sh"

SANDBOX_KEY="gap-007-loop-smoke"
SANDBOX_SPECS=(
  "$REPO_ROOT/specs/${SANDBOX_KEY}-done"
  "$REPO_ROOT/specs/${SANDBOX_KEY}-active"
)
STATE_DIR="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/state"
HALT_FILE="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/HALT"

mkdir -p "$STATE_DIR"

export MAKATO_LOOP_STATE_DIR="$STATE_DIR"
export MAKATO_HALT_FILE="$HALT_FILE"

cleanup() {
  rm -rf "${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$"
  rm -rf "${SANDBOX_SPECS[@]}"
}
trap cleanup EXIT

# Pre-clean leftovers
rm -rf "${SANDBOX_SPECS[@]}"

# Fixture mirroring `gh project item-list --format json` output. Two
# issues at Status=Ready, one at Status=Todo (excluded), one at
# Status=In progress (excluded), and one DraftIssue (excluded).
FIXTURE="$STATE_DIR/gh-fixture.json"
cat >"$FIXTURE" <<'EOF'
{
  "items": [
    {"content": {"type": "Issue", "number": 101, "title": "Issue 101",
                  "repository": "macatocz/makato", "url": "https://example/101"},
     "status": "Ready", "labels": ["enhancement"]},
    {"content": {"type": "Issue", "number": 102, "title": "Issue 102",
                  "repository": "macatocz/makato", "url": "https://example/102"},
     "status": "Ready", "labels": []},
    {"content": {"type": "Issue", "number": 103, "title": "Issue 103",
                  "repository": "macatocz/makato", "url": "https://example/103"},
     "status": "Todo", "labels": []},
    {"content": {"type": "Issue", "number": 104, "title": "Issue 104",
                  "repository": "macatocz/makato", "url": "https://example/104"},
     "status": "In progress", "labels": []},
    {"content": {"type": "DraftIssue", "title": "draft"},
     "status": "Ready", "labels": []}
  ]
}
EOF
export MAKATO_LOOP_GH_OVERRIDE="$FIXTURE"

fail() {
  echo "  ✗ FAIL: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
echo "=== T1: check-halt 0 when HALT absent ==="
rm -f "$HALT_FILE"
"$LOOP" check-halt
echo "  ✓ exit 0 with no HALT file"

# ---------------------------------------------------------------------------
echo "=== T2: check-halt 1 when HALT present ==="
touch "$HALT_FILE"
if "$LOOP" check-halt 2>/dev/null; then
  fail "expected non-zero exit when HALT file exists"
fi
echo "  ✓ exit 1 with HALT file"
rm -f "$HALT_FILE"

# ---------------------------------------------------------------------------
echo "=== T3: dispatch --dry-run mutates and clears active_workflow ==="
rm -f "$STATE_DIR/loop-status.json"
"$LOOP" dispatch 999 --dry-run >/dev/null
jq -e '.active_workflow == null' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "active_workflow not cleared after --dry-run"
echo "  ✓ active_workflow null after --dry-run"

# ---------------------------------------------------------------------------
echo "=== T4: dispatch refuses while active_workflow set ==="
jq -n '{active_workflow: {issue: 42, started_at: "2026-06-28T00:00:00.000Z"}}' \
  >"$STATE_DIR/loop-status.json"
rc=0
"$LOOP" dispatch 999 --dry-run 2>/dev/null || rc=$?
if [[ $rc -ne 2 ]]; then
  fail "expected exit 2 when active_workflow=42 != 999; got $rc"
fi
echo "  ✓ refused with exit 2"
rm -f "$STATE_DIR/loop-status.json"

# ---------------------------------------------------------------------------
echo "=== T5: in_flight skips workflow-state with phase=done ==="
mkdir -p "${SANDBOX_SPECS[0]}"
cat >"${SANDBOX_SPECS[0]}/workflow-state.json" <<EOF
{"issue_number": 101, "current_phase": "done"}
EOF
"$LOOP" run --status Ready --once --dry-run >/dev/null 2>&1 || true
jq -e '.queue == [101, 102]' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "queue snapshot mismatch (expected [101,102])"
echo "  ✓ done-phase spec not treated as in-flight"

# ---------------------------------------------------------------------------
echo "=== T6: in_flight includes workflow-state with phase=implement ==="
rm -rf "${SANDBOX_SPECS[0]}" "${SANDBOX_SPECS[1]}"
mkdir -p "${SANDBOX_SPECS[1]}"
cat >"${SANDBOX_SPECS[1]}/workflow-state.json" <<EOF
{"issue_number": 101, "current_phase": "implement"}
EOF
next="$("$LOOP" next "Ready" || echo "")"
if [[ "$next" != "102" ]]; then
  fail "expected next=102 (101 is in-flight); got '$next'"
fi
echo "  ✓ implement-phase spec treated as in-flight; next=102"
rm -rf "${SANDBOX_SPECS[1]}"

# ---------------------------------------------------------------------------
echo "=== T7: run --once --dry-run writes status, no real dispatch ==="
rm -f "$STATE_DIR/loop-status.json"
rm -rf "${SANDBOX_SPECS[@]}"
"$LOOP" run --status Ready --once --dry-run >/dev/null 2>&1
jq -e '.status_name == "Ready"' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "status_name not recorded"
jq -e '.dry_run == true' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "dry_run flag not recorded"
jq -e '.queue_depth == 2' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "queue_depth wrong (expected 2; Todo/In progress/DraftIssue filtered out)"
jq -e '.last_poll != null' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "last_poll not stamped"
echo "  ✓ status fields populated"

# ---------------------------------------------------------------------------
echo "=== T8: run --once exits cleanly when HALT present ==="
touch "$HALT_FILE"
rm -f "$STATE_DIR/loop-status.json"
"$LOOP" run --status Ready --once 2>/dev/null
jq -e '.last_halt_at != null' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "last_halt_at not recorded"
jq -e '.active_workflow // "absent" == "absent"' "$STATE_DIR/loop-status.json" \
  >/dev/null || fail "active_workflow should not be set when HALT present"
echo "  ✓ HALT respected, no dispatch"
rm -f "$HALT_FILE"

# ---------------------------------------------------------------------------
echo "=== T9: run --once dispatches via MAKATO_LOOP_DRY_DISPATCH ==="
rm -f "$STATE_DIR/loop-status.json"
rm -rf "${SANDBOX_SPECS[@]}"
MAKATO_LOOP_DRY_DISPATCH=1 "$LOOP" run --status Ready --once >/dev/null 2>&1
jq -e '.last_dispatch_issue == 101' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "last_dispatch_issue should be 101 (first untracked at Status=Ready)"
jq -e '.active_workflow == null' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "active_workflow should be cleared post-dispatch"
echo "  ✓ first untracked issue dispatched, status cleared"

# ---------------------------------------------------------------------------
echo "=== T10: poll filters by Status name ==="
queue_ready="$("$LOOP" poll Ready)"
queue_todo="$("$LOOP" poll Todo)"
[[ "$(jq 'length' <<<"$queue_ready")" == "2" ]] \
  || fail "poll Ready expected 2 items, got $(jq 'length' <<<"$queue_ready")"
[[ "$(jq 'length' <<<"$queue_todo")" == "1" ]] \
  || fail "poll Todo expected 1 item, got $(jq 'length' <<<"$queue_todo")"
[[ "$(jq -r '.[0].issue' <<<"$queue_todo")" == "103" ]] \
  || fail "poll Todo should return #103"
echo "  ✓ Status filter honored (Ready=2, Todo=1)"

# ---------------------------------------------------------------------------
echo "=== T11: poll filters non-Issue content out ==="
queue="$("$LOOP" poll Ready)"
# DraftIssue at Status=Ready exists in fixture but must NOT appear.
if jq -e '[.[] | select(.issue == null)] | length > 0' <<<"$queue" >/dev/null; then
  fail "DraftIssue leaked into the queue"
fi
echo "  ✓ DraftIssue excluded (Issue-only)"

echo
echo "=== ALL TESTS PASSED ==="
