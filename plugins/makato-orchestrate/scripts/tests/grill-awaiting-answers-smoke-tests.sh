#!/usr/bin/env bash
# Smoke tests for the loop side of autonomous build-grill-with-docs: an issue parked on ONE batched
# questions comment (card Blocked + specs/<slug>/awaiting-answers-<N>.json) must wait untouched until the
# human moves the card back to Ready / In progress, and must then be resumed. Run from the repo root:
#
#   plugins/makato-orchestrate/scripts/tests/grill-awaiting-answers-smoke-tests.sh
#
# Scenarios:
#   T1: _issue_awaiting_answers sees the marker in any spec folder, ignores other issues
#   T2: _reconcile_orphaned_in_progress leaves a parked card alone (control: reconciles without the marker)
#   T3: _reconcile_orphaned_stale leaves a parked, long-dead run alone (control: HALT-015 without the marker)
#   T4: the worktree reaper skips the worktree of a parked issue (control: not skipped without the marker)
#   T5: _resume_answered_questions — waiting stays parked; answered/expired resumes with the observed card
#       status; closed retires the marker; unreachable board leaves it parked; the resume budget escalates
#       once and a re-park refreshes it; AWAITING_RESUME_DISABLE=1 switches the pass off
#   T6: dispatch --resume passes the Tier-2 in-flight gate for a parked workflow-state (plain dispatch does not)
#   T7: run --once resumes a parked issue whose card the human moved back, with no Ready card on the board
#
# Fully offline: board/issue state come from the loop's existing override hooks, the questions helper is a
# stub (MAKATO_HUMAN_QUESTIONS), and cmd_dispatch is a recorder in T5 / DRY_DISPATCH in T6-T7.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LOOP="$REPO_ROOT/plugins/makato-orchestrate/scripts/loop.sh"

SANDBOX="${CLAUDE_JOB_DIR:-/tmp}/grill-awaiting-smoke-$$"
STATE_DIR="$SANDBOX/state"
SPECS="$SANDBOX/specs"
mkdir -p "$STATE_DIR" "$SPECS"
trap 'rm -rf "$SANDBOX"' EXIT

export MAKATO_LOOP_STATE_DIR="$STATE_DIR"
export MAKATO_HALT_FILE="$SANDBOX/HALT"
export SPECS_DIR="$SPECS"
export MAKATO_LOOP_TEST_HOOK=1

fail() { echo "  ✗ FAIL: $*" >&2; exit 1; }
pass() { echo "  ✓ $*"; }

park() { # <issue> [slug] — write the marker the grill helper leaves behind
  mkdir -p "$SPECS/${2:-$1-slug}"
  printf '{"issue":%s,"repo":"owner/name","round":1}\n' "$1" >"$SPECS/${2:-$1-slug}/awaiting-answers-$1.json"
}
unpark() { rm -f "$SPECS"/*/awaiting-answers-"$1".json; }

# ---------------------------------------------------------------------------
echo "=== T1: _issue_awaiting_answers ==="
park 801
"$LOOP" _test-issue-awaiting-answers 801 "$SPECS" || fail "T1: marker for #801 not seen"
"$LOOP" _test-issue-awaiting-answers 802 "$SPECS" && fail "T1: #802 has no marker but was reported parked"
SPECS_DIR="$SPECS" "$LOOP" _test-issue-awaiting-answers 801 || fail "T1: default specs dir ignored"
unpark 801
"$LOOP" _test-issue-awaiting-answers 801 "$SPECS" && fail "T1: marker gone but still reported parked"
pass "marker found per issue, in the given or default specs dir, gone when deleted"

# ---------------------------------------------------------------------------
echo "=== T2: in-progress reconciler skips a parked card ==="
BOARD="$SANDBOX/board.json"
STATES="$SANDBOX/issue-state.json"
RECON="$SANDBOX/recon.txt"
jq -n '{items:[{"content":{"type":"Issue","number":811,"title":"parked","repository":"owner/name","url":"https://x/811"},"status":"In progress","labels":[]}]}' >"$BOARD"
jq -n '{"811":"OPEN"}' >"$STATES"
run_inprogress() {
  : >"$RECON"
  MAKATO_LOOP_RECONCILE_GH_OVERRIDE="$BOARD" MAKATO_LOOP_RECONCILE_ISSUE_STATE_OVERRIDE="$STATES" \
    MAKATO_LOOP_RECONCILE_TEST_FILE="$RECON" MAKATO_LOOP_RECONCILE_SPECS_DIR="$SPECS" \
    "$LOOP" _test-reconcile-orphaned >/dev/null 2>&1 || fail "T2: reconciler returned non-zero"
}
run_inprogress
grep -q "reconcile #811" "$RECON" || fail "T2 control: unparked orphan #811 should be reconciled; got: $(cat "$RECON")"
park 811
run_inprogress
[[ ! -s "$RECON" ]] || fail "T2: parked #811 was reconciled: $(cat "$RECON")"
unpark 811
pass "without marker the orphan is reconciled; with marker it is left alone"

# ---------------------------------------------------------------------------
echo "=== T3: stale reconciler skips a parked run whose owner is long dead ==="
LABELS="$SANDBOX/labels.txt"
OLD="$(python3 -c "from datetime import datetime, timedelta, timezone
n = datetime.now(timezone.utc) - timedelta(hours=48)
print(n.strftime('%Y-%m-%dT%H:%M:%S.') + f'{n.microsecond // 1000:03d}Z')")"
mkdir -p "$SPECS/821-slug"
printf '{"issue_number":821,"current_phase":"refine","resume_point":"grill-awaiting-answers","worktree_path":"","updated_at":"%s"}\n' "$OLD" \
  >"$SPECS/821-slug/workflow-state-821.json"
jq -n '{"821":"OPEN"}' >"$STATES"
jq -n '{"821":[]}' >"$SANDBOX/labels.json"
run_stale() {
  : >"$RECON"; : >"$LABELS"
  MAKATO_ORPHAN_STALE_SECS=3600 MAKATO_LOOP_RECONCILE_SPECS_DIR="$SPECS" MAKATO_LOOP_RECONCILE_TEST_FILE="$RECON" \
    MAKATO_LOOP_RECONCILE_LABEL_TEST_FILE="$LABELS" MAKATO_LOOP_RECONCILE_ISSUE_STATE_OVERRIDE="$STATES" \
    MAKATO_LOOP_RECONCILE_LABELS_OVERRIDE="$SANDBOX/labels.json" \
    "$LOOP" _test-reconcile-stale >/dev/null 2>&1 || fail "T3: stale reconciler returned non-zero"
}
run_stale
grep -q "reconcile #821" "$RECON" || fail "T3 control: dead 48h-old run #821 should be reconciled; got: $(cat "$RECON")"
grep -q "label #821 needs-human-review" "$LABELS" || fail "T3 control: expected needs-human-review for #821"
rm -f "$SPECS/821-slug/orchestrate.jsonl"
park 821 821-slug
run_stale
[[ ! -s "$RECON" && ! -s "$LABELS" ]] || fail "T3: parked #821 was reconciled/labelled: $(cat "$RECON" "$LABELS")"
rm -rf "$SPECS/821-slug"
pass "without marker the dead run is escalated (HALT-015 path); with marker it is left alone"

# ---------------------------------------------------------------------------
echo "=== T4: reaper guard ==="
WT="$SANDBOX/worktrees/831"
mkdir -p "$WT" "$SPECS/831-slug"
WT_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$WT")"
printf '{"issue_number":831,"current_phase":"refine","worktree_path":"%s"}\n' "$WT" >"$SPECS/831-slug/workflow-state-831.json"
"$LOOP" _test-reap-awaiting "$WT_REAL" && fail "T4 control: no marker, worktree must not be treated as parked"
park 831 831-slug
"$LOOP" _test-reap-awaiting "$WT_REAL" || fail "T4: parked issue's worktree not recognised"
"$LOOP" _test-reap-awaiting "$SANDBOX/worktrees/other" && fail "T4: an unrelated worktree was treated as parked"
rm -rf "$SPECS/831-slug"
pass "worktree of a parked issue recognised (reaper skips it); others untouched"

# ---------------------------------------------------------------------------
echo "=== T5: _resume_answered_questions ==="
HELPER="$SANDBOX/human_questions_stub.py"
STUB="$SANDBOX/stub"
mkdir -p "$STUB"
cat >"$HELPER" <<'PY'
import os
import sys

args = sys.argv[1:]
issue = args[args.index("--issue") + 1]
stub = os.environ["GRILL_STUB_DIR"]
if args[0] == "status":
    path = os.path.join(stub, "status-%s.json" % issue)
    if not os.path.exists(path):
        sys.exit(3)  # GitHub unreachable
    print(open(path).read())
elif args[0] == "resolve":
    open(os.path.join(stub, "resolved.log"), "a").write(issue + "\n")
    print('{"state":"resolved"}')
PY
RECORD="$SANDBOX/record.txt"
set_status() { printf '%s\n' "$2" >"$STUB/status-$1.json"; }
tick() { # runs one resume pass; prints the issue it resumed (empty = none)
  GRILL_STUB_DIR="$STUB" MAKATO_HUMAN_QUESTIONS="$HELPER" MAKATO_LOOP_AWAITING_TEST_FILE="$RECORD" \
    "$LOOP" _test-resume-answered 2>/dev/null | sed -n 's/^resumed=//p'
}

: >"$RECORD"
[[ -z "$(tick)" ]] || fail "T5: no markers must not resume anything"
park 841; park 842
set_status 841 '{"state":"waiting","board_status":"Blocked"}'
set_status 842 '{"state":"waiting","board_status":"Blocked"}'
[[ -z "$(tick)" && ! -s "$RECORD" ]] || fail "T5: waiting issues were resumed: $(cat "$RECORD")"
pass "no marker / still waiting: nothing is dispatched"

set_status 841 '{"state":"answered","board_status":"In progress"}'
[[ "$(tick)" == "841" ]] || fail "T5: answered #841 not resumed"
grep -qx "dispatch 841 --resume repo=owner/name status=In progress" "$RECORD" \
  || fail "T5: wrong dispatch call: $(cat "$RECORD")"
pass "answered: dispatch <n> --resume with the repo from the marker and the observed card status"

: >"$RECORD"
set_status 841 '{"state":"waiting","board_status":"Blocked"}'
set_status 842 '{"state":"expired","board_status":"Blocked"}'
[[ "$(tick)" == "842" ]] || fail "T5: expired #842 not resumed"
grep -qx "dispatch 842 --resume repo=owner/name status=Blocked" "$RECORD" || fail "T5: wrong dispatch for expired: $(cat "$RECORD")"
pass "expired wait: resumed (the recommended options will be taken)"

: >"$RECORD"
rm -f "$STUB/status-842.json"
[[ -z "$(tick)" && ! -s "$RECORD" ]] || fail "T5: unreachable board must leave the issue parked"
set_status 842 '{"state":"unobservable","board_status":""}'
[[ -z "$(tick)" && ! -s "$RECORD" ]] || fail "T5: unobservable board must leave the issue parked"
pass "unreachable / unobservable board: left parked, nothing dispatched"

set_status 842 '{"state":"closed","board_status":"Done"}'
[[ -z "$(tick)" && ! -s "$RECORD" ]] || fail "T5: closed issue must not be resumed"
grep -qx "842" "$STUB/resolved.log" || fail "T5: closed issue's marker not retired through the helper"
pass "closed while waiting: marker retired, no dispatch"
unpark 842

# Resume budget: an issue resumed AWAITING_RESUME_MAX times without ever being seen waiting again escalates once.
: >"$RECORD"
rm -f "$STATE_DIR"/awaiting-resume-*.count
set_status 841 '{"state":"answered","board_status":"Ready"}'
export MAKATO_LOOP_AWAITING_RESUME_MAX=2
[[ "$(tick)" == "841" ]] && [[ "$(tick)" == "841" ]] || fail "T5: first two resumes should dispatch"
[[ -z "$(tick)" ]] || fail "T5: third pass must not dispatch (budget spent)"
[[ -z "$(tick)" ]] || fail "T5: fourth pass must not dispatch"
[[ "$(grep -c '^dispatch 841' "$RECORD")" == "2" ]] || fail "T5: expected exactly 2 dispatches: $(cat "$RECORD")"
[[ "$(grep -c '^escalate #841' "$RECORD")" == "1" ]] || fail "T5: expected exactly one escalation: $(cat "$RECORD")"
pass "resume budget: two resumes, then exactly one escalation, then silence"

: >"$RECORD"
set_status 841 '{"state":"waiting","board_status":"Blocked"}'
[[ -z "$(tick)" ]]
[[ ! -e "$STATE_DIR/awaiting-resume-841.count" ]] || fail "T5: seeing the issue waiting again must refresh its budget"
set_status 841 '{"state":"answered","board_status":"Ready"}'
[[ "$(tick)" == "841" ]] || fail "T5: refreshed budget should allow a resume"
unset MAKATO_LOOP_AWAITING_RESUME_MAX
pass "parked again (follow-up round): the resume budget starts over"

: >"$RECORD"
MAKATO_LOOP_AWAITING_RESUME_DISABLE=1 tick >/dev/null
[[ ! -s "$RECORD" ]] || fail "T5: AWAITING_RESUME_DISABLE=1 must switch the pass off"
unpark 841
rm -f "$STATE_DIR"/awaiting-resume-*.count
pass "MAKATO_LOOP_AWAITING_RESUME_DISABLE=1: pass is off"

# ---------------------------------------------------------------------------
echo "=== T6 / T7: dispatch --resume and a full run --once tick ==="
BODY="$SANDBOX/body.txt"
REAP="$SANDBOX/reap.json"
GLABELS="$SANDBOX/gate-labels.json"
printf '%s\n' '*Feature slug: `gate-test-key` — produced by to-issues v3.x.*' >"$BODY"
printf '{}' >"$REAP"
printf '{"labels":[],"title":"Issue 851"}' >"$GLABELS"
PWT="$SANDBOX/worktrees/851"
mkdir -p "$PWT" "$SPECS/851-slug"
( : ) & dead_pid=$!; wait "$dead_pid" || true
printf '%s\n' "$dead_pid" >"$PWT/.loop-owner.pid"
printf '{"issue_number":851,"current_phase":"refine","resume_point":"grill-awaiting-answers","worktree_path":"%s"}\n' "$PWT" \
  >"$SPECS/851-slug/workflow-state-851.json"
park 851 851-slug
dry_dispatch() { # <args...> — dispatch 851 through the real gates, DRY_DISPATCH stops before the harness
  rm -f "$STATE_DIR/loop-status.json"
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$BODY" MAKATO_LOOP_REAP_GH_OVERRIDE="$REAP" MAKATO_LOOP_GATE_LABELS_OVERRIDE="$GLABELS" \
    MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:feature" MAKATO_LOOP_CLAIM_ON_DISPATCH=0 MAKATO_LOOP_DRY_DISPATCH=1 \
    MAKATO_LOOP_ASSIGN_ON_DISPATCH=0 MAKATO_LOOP_DISPATCH_REPO="owner/name" "$LOOP" dispatch 851 "$@" 2>/dev/null
  jq -r '.gate_skips_total // 0' "$STATE_DIR/loop-status.json" 2>/dev/null || echo 0
}
[[ "$(dry_dispatch)" -eq 1 ]] || fail "T6: a plain dispatch of an in-flight (parked) issue must be skipped by Tier 2"
[[ "$(dry_dispatch --resume)" -eq 0 ]] || fail "T6: dispatch --resume must pass Tier 2 for a parked workflow-state"
pass "T6: plain dispatch skipped (in flight); --resume passes the gate"

# T7: the card is Blocked→In progress by the human; nothing is Ready, so only the resume pass can pick it up.
printf '%s\n' '{"state":"answered","board_status":"In progress"}' >"$STUB/status-851.json"
jq -n '{items:[{"content":{"type":"Issue","number":851,"title":"parked","repository":"owner/name","url":"https://x/851"},"status":"In progress","labels":[]}]}' >"$BOARD"
rm -f "$STATE_DIR/loop-status.json"
GRILL_STUB_DIR="$STUB" MAKATO_HUMAN_QUESTIONS="$HELPER" MAKATO_LOOP_GH_OVERRIDE="$BOARD" \
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$BODY" MAKATO_LOOP_REAP_GH_OVERRIDE="$REAP" MAKATO_LOOP_GATE_LABELS_OVERRIDE="$GLABELS" \
  MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:feature" MAKATO_LOOP_CLAIM_ON_DISPATCH=0 MAKATO_LOOP_DRY_DISPATCH=1 \
  MAKATO_LOOP_ASSIGN_ON_DISPATCH=0 MAKATO_LOOP_DISPATCH_REPO="owner/name" \
  MAKATO_LOOP_RECONCILE_ON_POLL=0 MAKATO_ORPHAN_DETECT_DISABLE=1 MAKATO_LOOP_REAP_ON_POLL=0 \
  MAKATO_LOOP_RECONCILE_BLOCKED_ON_POLL=0 \
  "$LOOP" run --status Ready --once >/dev/null 2>&1 || true
jq -e '.last_dispatch_issue == 851' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "T7: run --once did not resume parked #851: $(jq -c '{last_dispatch_issue, queue, gate_skips_total}' "$STATE_DIR/loop-status.json" 2>/dev/null)"
pass "T7: one tick with an empty Ready queue resumed the parked issue"

echo
echo "=== ALL GRILL-AWAITING-ANSWERS SMOKE TESTS PASSED (T1–T7) ==="
