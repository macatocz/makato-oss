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
#   T12: watchdog stamps active_workflow.stalled=true after STALL_WARN
#   T13: watchdog SIGTERMs the child after STALL_KILL and stamps last_watchdog_kill
#   T14: MAKATO_LOOP_STALL_DISABLE=1 disables the watchdog entirely
#   T15: run refuses to start when a live loop.pid exists (exit 3)
#   T16: run reclaims a stale pidfile silently (dead PID)
#   T17: startup_audit records script_path/pid/ppid/pidfile
#   T18: run --force reclaims a live pidfile by SIGTERM'ing the incumbent
#   T23: dispatch assigns the issue on the real-fork path; --dry-run does not (#33)
#   T24: MAKATO_LOOP_ASSIGN_ON_DISPATCH=0 disables the assign (#33)
#   T25: dispatch derives KEY/BRANCH from the issue body and threads the
#        full po-agent input bundle (ISSUE_NUMBER/KEY/REPO/BRANCH/REPO_ROOT);
#        falls back to specs/<slug>/stories.json; degrades to WARN when absent
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
cat >"${SANDBOX_SPECS[0]}/workflow-state-101.json" <<EOF
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
cat >"${SANDBOX_SPECS[1]}/workflow-state-101.json" <<EOF
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

# ---------------------------------------------------------------------------
# Watchdog scenarios (#164). We spawn a genuinely-hung child via
# MAKATO_LOOP_STALL_TEST_CMD="sleep <big>" and squeeze STALL_WARN/KILL to
# small values so the tests run in single-digit seconds instead of minutes.
# ---------------------------------------------------------------------------

echo "=== T12: watchdog WARNs after STALL_WARN ==="
rm -f "$STATE_DIR/loop-status.json"
# STALL_KILL big enough that we observe stalled=true first without racing
# the kill path.
(
  export MAKATO_LOOP_STALL_TEST_CMD="sleep 30"
  export MAKATO_LOOP_STALL_WARN=1
  export MAKATO_LOOP_STALL_KILL=15
  export MAKATO_LOOP_STALL_POLL=1
  export MAKATO_LOOP_STALL_TERM_GRACE=1
  # Run dispatch in background so we can poll status while the child sleeps.
  "$LOOP" dispatch 12001 >/dev/null 2>&1 &
  dispatch_pid=$!
  # Wait for WARN stamp (up to 6 s — generous for CI). Once stamped, we
  # SIGTERM the dispatch so the test doesn't hang on the sleep.
  observed_warn=0
  for _ in 1 2 3 4 5 6; do
    sleep 1
    if [[ -f "$STATE_DIR/loop-status.json" ]] && \
       jq -e '.active_workflow.stalled == true' "$STATE_DIR/loop-status.json" >/dev/null 2>&1; then
      observed_warn=1
      break
    fi
  done
  # Kill the dispatch (and its child) cleanly so the test suite doesn't wait.
  kill -TERM "$dispatch_pid" 2>/dev/null || true
  wait "$dispatch_pid" 2>/dev/null || true
  [[ $observed_warn -eq 1 ]] || fail "watchdog did not stamp active_workflow.stalled=true"
)
echo "  ✓ active_workflow.stalled=true observed"

# ---------------------------------------------------------------------------
echo "=== T13: watchdog SIGKILLs child after STALL_KILL and audits it ==="
rm -f "$STATE_DIR/loop-status.json"
# The dispatch call MUST return on its own once the watchdog reaps the
# child — so this test simply waits for cmd_dispatch to exit and asserts
# the last_watchdog_kill snapshot survives the active_workflow=null clear.
MAKATO_LOOP_STALL_TEST_CMD="sleep 30" \
MAKATO_LOOP_STALL_WARN=1 \
MAKATO_LOOP_STALL_KILL=2 \
MAKATO_LOOP_STALL_POLL=1 \
MAKATO_LOOP_STALL_TERM_GRACE=1 \
  "$LOOP" dispatch 13001 >/dev/null 2>&1 || true
jq -e '.last_watchdog_kill.issue == 13001' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "last_watchdog_kill.issue should be 13001"
jq -e '.last_watchdog_kill.killed_at != null' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "last_watchdog_kill.killed_at should be stamped"
jq -e '.active_workflow == null' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "active_workflow should be cleared post-dispatch"
echo "  ✓ last_watchdog_kill audit persisted; active_workflow cleared"

# ---------------------------------------------------------------------------
echo "=== T14: MAKATO_LOOP_STALL_DISABLE=1 disables the watchdog ==="
rm -f "$STATE_DIR/loop-status.json"
rm -f "$STATE_DIR/dispatch-14001.log"
# With the watchdog disabled, the sleep must run to completion (short
# sleep so the test finishes quickly) with NO log file created and no
# stalled / killed_by_watchdog fields anywhere.
MAKATO_LOOP_STALL_DISABLE=1 \
MAKATO_LOOP_STALL_TEST_CMD="sleep 1" \
MAKATO_LOOP_STALL_WARN=1 \
MAKATO_LOOP_STALL_KILL=2 \
MAKATO_LOOP_STALL_POLL=1 \
  "$LOOP" dispatch 14001 >/dev/null 2>&1
if [[ -e "$STATE_DIR/dispatch-14001.log" ]]; then
  fail "dispatch log should not exist when watchdog disabled"
fi
if jq -e '.last_watchdog_kill != null' "$STATE_DIR/loop-status.json" >/dev/null 2>&1; then
  fail "last_watchdog_kill should not be stamped when watchdog disabled"
fi
jq -e '.active_workflow == null' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "active_workflow should still be cleared post-dispatch"
echo "  ✓ watchdog skipped, dispatch completes normally"

# ---------------------------------------------------------------------------
# Mutex scenarios (#172). Guard against two loop.sh instances writing
# to the same loop-status.json in parallel. Uses MAKATO_LOOP_PIDFILE
# to isolate from anything else on the box.
# ---------------------------------------------------------------------------

echo "=== T15: run refuses when a live pidfile exists (exit 3) ==="
rm -f "$STATE_DIR/loop-status.json"
PIDFILE_T15="$STATE_DIR/t15-loop.pid"
# Point pidfile at a real live process (this shell) so kill -0 succeeds.
echo "$$" >"$PIDFILE_T15"
rc=0
MAKATO_LOOP_PIDFILE="$PIDFILE_T15" \
  "$LOOP" run --status Ready --once --dry-run 2>/dev/null || rc=$?
if [[ $rc -ne 3 ]]; then
  fail "expected exit 3 when live pidfile exists; got $rc"
fi
# Pidfile must NOT be clobbered — the refusing instance never took ownership.
[[ "$(cat "$PIDFILE_T15")" == "$$" ]] \
  || fail "pidfile clobbered by refusing instance"
rm -f "$PIDFILE_T15"
echo "  ✓ refused with exit 3, pidfile preserved"

# ---------------------------------------------------------------------------
echo "=== T16: run reclaims a stale pidfile silently ==="
rm -f "$STATE_DIR/loop-status.json"
PIDFILE_T16="$STATE_DIR/t16-loop.pid"
# 999999 is virtually guaranteed to be a dead PID on any macOS/Linux box.
echo "999999" >"$PIDFILE_T16"
MAKATO_LOOP_PIDFILE="$PIDFILE_T16" \
  "$LOOP" run --status Ready --once --dry-run >/dev/null 2>&1
# After successful run, the EXIT trap should have removed the pidfile.
if [[ -e "$PIDFILE_T16" ]]; then
  fail "pidfile should be removed by EXIT trap after clean shutdown"
fi
echo "  ✓ stale pidfile reclaimed and cleaned up on exit"

# ---------------------------------------------------------------------------
echo "=== T17: startup_audit records script_path/pid/ppid/pidfile ==="
rm -f "$STATE_DIR/loop-status.json"
PIDFILE_T17="$STATE_DIR/t17-loop.pid"
MAKATO_LOOP_PIDFILE="$PIDFILE_T17" \
  "$LOOP" run --status Ready --once --dry-run >/dev/null 2>&1
jq -e '.startup_audit.script_path | test("loop.sh$")' \
  "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "startup_audit.script_path should end in loop.sh"
jq -e '.startup_audit.pid | type == "number"' \
  "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "startup_audit.pid should be a number"
jq -e ".startup_audit.pidfile == \"$PIDFILE_T17\"" \
  "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "startup_audit.pidfile should match \$MAKATO_LOOP_PIDFILE"
jq -e '.startup_audit.status_name == "Ready"' \
  "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "startup_audit.status_name should be Ready"
jq -e '.startup_audit.dry_run == true' \
  "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "startup_audit.dry_run should be true"
echo "  ✓ startup_audit populated"

# ---------------------------------------------------------------------------
echo "=== T18: run --force reclaims a live pidfile ==="
rm -f "$STATE_DIR/loop-status.json"
PIDFILE_T18="$STATE_DIR/t18-loop.pid"
# Spawn a real, killable sleep and pin the pidfile at its PID.
sleep 60 &
sleep_pid=$!
echo "$sleep_pid" >"$PIDFILE_T18"
# --force must SIGTERM the sleep and take over.
MAKATO_LOOP_PIDFILE="$PIDFILE_T18" \
MAKATO_LOOP_FORCE_GRACE=2 \
  "$LOOP" run --status Ready --once --dry-run --force >/dev/null 2>&1
# The pre-existing sleep must be dead (or reaping soon).
if kill -0 "$sleep_pid" 2>/dev/null; then
  # Give the OS a beat to reap, then check once more.
  sleep 1
  if kill -0 "$sleep_pid" 2>/dev/null; then
    kill -KILL "$sleep_pid" 2>/dev/null || true
    fail "--force did not SIGTERM the incumbent PID $sleep_pid"
  fi
fi
wait "$sleep_pid" 2>/dev/null || true
# Pidfile removed on clean exit.
if [[ -e "$PIDFILE_T18" ]]; then
  fail "pidfile should be removed on exit after --force takeover"
fi
echo "  ✓ --force killed incumbent and took over"

# ---------------------------------------------------------------------------
# Sleep-wake guard scenarios (#171). After a macOS host sleep-wake,
# `sleep $interval` in bash can return early — a poorly-behaved caller
# then tight-loops through cmd_dispatch and forks N zombie subprocesses
# against the same issue in one wall-clock second. Two guards defend:
#   1. `_guarded_sleep` — wall-clock-guaranteed sleep loop that keeps
#      re-entering `sleep` until $(date +%s) has advanced far enough.
#   2. Idempotent-dispatch guard — refuses same-issue re-dispatch while
#      `active_workflow.issue` still names the target (age gated by
#      MAKATO_LOOP_MIN_DISPATCH_GAP), and refuses same-issue re-dispatch
#      within MAKATO_LOOP_LAST_DISPATCH_GAP seconds of `.last_dispatch_at`.
# ---------------------------------------------------------------------------

echo "=== T19: _guarded_sleep waits full wall-clock even when raw sleep returns early ==="
# MAKATO_LOOP_SLEEP_CMD is a test hook: it replaces the raw `sleep <step>`
# call inside _guarded_sleep with a shell command. Setting it to `sleep 0.1`
# simulates a sleep that returns almost-instantly (mimicking macOS wake
# behaviour). _guarded_sleep MUST still burn ≥ requested seconds of
# wall-clock via its outer while-date+%s loop.
t19_start=$(date +%s)
MAKATO_LOOP_TEST_HOOK=1 MAKATO_LOOP_SLEEP_CMD="sleep 0.1" MAKATO_LOOP_SLEEP_MAX_STEP=1 \
  "$LOOP" _test-guarded-sleep 2 >/dev/null 2>&1 \
  || fail "_test-guarded-sleep 2 exited non-zero"
t19_elapsed=$(( $(date +%s) - t19_start ))
if [[ $t19_elapsed -lt 2 ]]; then
  fail "_guarded_sleep 2 returned in ${t19_elapsed}s (expected ≥ 2s under early-return simulation)"
fi
echo "  ✓ _guarded_sleep 2 slept ${t19_elapsed}s despite instant sleep replacement"

# ---------------------------------------------------------------------------
echo "=== T20: idempotent-dispatch guard refuses same-issue re-dispatch (in-flight) ==="
rm -f "$STATE_DIR/loop-status.json"
# Seed active_workflow with the same issue we're about to dispatch, with a
# fresh started_at (1s ago). The guard MUST refuse (exit 0, silent, no
# re-stamp of started_at) — this is the sleep-wake burst scenario where
# cmd_run re-enters within seconds against an already-in-flight issue.
fresh_started_at="$(python3 -c "import datetime; d=datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=1); print(d.strftime('%Y-%m-%dT%H:%M:%S.')+f'{d.microsecond//1000:03d}Z')")"
jq -n --arg ts "$fresh_started_at" \
  '{active_workflow: {issue: 200, started_at: $ts, stalled: false, stalled_since: null, killed_by_watchdog: false}}' \
  >"$STATE_DIR/loop-status.json"
rc=0
MAKATO_LOOP_MIN_DISPATCH_GAP=30 MAKATO_LOOP_DRY_DISPATCH=1 \
  "$LOOP" dispatch 200 2>/dev/null || rc=$?
if [[ $rc -ne 0 ]]; then
  fail "expected exit 0 when guard refuses same-issue re-dispatch; got $rc"
fi
observed_ts="$(jq -r '.active_workflow.started_at' "$STATE_DIR/loop-status.json")"
if [[ "$observed_ts" != "$fresh_started_at" ]]; then
  fail "active_workflow.started_at was clobbered ($observed_ts != $fresh_started_at) — guard did not fire"
fi
# .last_dispatch_issue must NOT be stamped (DRY_DISPATCH side-effect must be skipped)
if jq -e '.last_dispatch_issue != null' "$STATE_DIR/loop-status.json" >/dev/null 2>&1; then
  fail ".last_dispatch_issue was stamped despite guard refusing — dispatch body executed"
fi
echo "  ✓ same-issue re-dispatch refused; started_at preserved; body skipped"

# Sub-assertion 2 — predicate A RELEASE branch (#171 crashed-dispatch reclaim).
# When active_workflow.issue matches the target AND started_at is
# OLDER than MIN_DISPATCH_GAP_SECS, the guard MUST release — a prior
# dispatch that never cleared active_workflow (crashed or SIGKILL'd)
# must not permanently block re-dispatch. The reclaim is the design
# doc's explicit "no permanent-refuse state" guarantee.
rm -f "$STATE_DIR/loop-status.json"
# 60s ago; guard=30s → age > gap → RELEASE.
stale_active_started_at="$(python3 -c "import datetime; d=datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=60); print(d.strftime('%Y-%m-%dT%H:%M:%S.')+f'{d.microsecond//1000:03d}Z')")"
jq -n --arg ts "$stale_active_started_at" \
  '{active_workflow: {issue: 200, started_at: $ts, stalled: false, stalled_since: null, killed_by_watchdog: false}}' \
  >"$STATE_DIR/loop-status.json"
MAKATO_LOOP_MIN_DISPATCH_GAP=30 MAKATO_LOOP_LAST_DISPATCH_GAP=1 MAKATO_LOOP_DRY_DISPATCH=1 \
  "$LOOP" dispatch 200 >/dev/null 2>&1 \
  || fail "expected exit 0 when guard releases on stale active_workflow.started_at"
# .last_dispatch_issue must be stamped by the real dispatch path (not the guard-skip path)
if [[ "$(jq -r '.last_dispatch_issue' "$STATE_DIR/loop-status.json")" != "200" ]]; then
  fail "expected .last_dispatch_issue == 200 after crashed-dispatch reclaim; got $(jq -r '.last_dispatch_issue' "$STATE_DIR/loop-status.json")"
fi
echo "  ✓ stale started_at released the guard; dispatch fired (crashed-dispatch reclaim)"

# ---------------------------------------------------------------------------
echo "=== T21: last-dispatch guard fires on fresh timestamp, releases on stale ==="
rm -f "$STATE_DIR/loop-status.json"
# Sub-assertion 1 — GAP=1s, stamp 2s ago → stale → guard RELEASES → dispatch fires.
stale_ts_2s_ago="$(python3 -c "import datetime; d=datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=2); print(d.strftime('%Y-%m-%dT%H:%M:%S.')+f'{d.microsecond//1000:03d}Z')")"
jq -n --arg ts "$stale_ts_2s_ago" \
  '{last_dispatch_at: $ts, last_dispatch_issue: 999}' \
  >"$STATE_DIR/loop-status.json"
MAKATO_LOOP_LAST_DISPATCH_GAP=1 MAKATO_LOOP_DRY_DISPATCH=1 \
  "$LOOP" dispatch 200 >/dev/null 2>&1 \
  || fail "expected exit 0 when guard releases on stale .last_dispatch_at"
if [[ "$(jq -r '.last_dispatch_issue' "$STATE_DIR/loop-status.json")" != "200" ]]; then
  fail "expected .last_dispatch_issue == 200 after stale-timestamp release; got $(jq -r '.last_dispatch_issue' "$STATE_DIR/loop-status.json")"
fi
echo "  ✓ stale timestamp released the guard; dispatch fired"

# Sub-assertion 2 — GAP=60s, same-issue stamp 2s ago → fresh → guard FIRES → dispatch refused.
rm -f "$STATE_DIR/loop-status.json"
stale_ts_2s_ago="$(python3 -c "import datetime; d=datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=2); print(d.strftime('%Y-%m-%dT%H:%M:%S.')+f'{d.microsecond//1000:03d}Z')")"
jq -n --arg ts "$stale_ts_2s_ago" \
  '{last_dispatch_at: $ts, last_dispatch_issue: 200}' \
  >"$STATE_DIR/loop-status.json"
# Snapshot the timestamp BEFORE the dispatch so we can prove the guard
# refused (last_dispatch_at must not have been re-stamped to a fresh
# "now").
observed_ts_before="$(jq -r '.last_dispatch_at' "$STATE_DIR/loop-status.json")"
MAKATO_LOOP_LAST_DISPATCH_GAP=60 MAKATO_LOOP_DRY_DISPATCH=1 \
  "$LOOP" dispatch 200 >/dev/null 2>&1 \
  || fail "expected exit 0 when guard refuses (silent no-op)"
observed_ts_after="$(jq -r '.last_dispatch_at' "$STATE_DIR/loop-status.json")"
if [[ "$observed_ts_before" != "$observed_ts_after" ]]; then
  fail "expected .last_dispatch_at unchanged when guard fires; before=$observed_ts_before after=$observed_ts_after"
fi
echo "  ✓ fresh same-issue timestamp fired the guard; dispatch refused; body skipped"

# ---------------------------------------------------------------------------
echo "=== T22: _test-* hooks refuse to run without MAKATO_LOOP_TEST_HOOK=1 ==="
# Operator running `loop.sh _test-guarded-sleep 3600` at the prompt
# would get a 1-hour sleep with no indication it is a test hook.
# The refusal path is the usability guard.
rc=0
"$LOOP" _test-guarded-sleep 1 2>/dev/null || rc=$?
if [[ $rc -ne 64 ]]; then
  fail "expected exit 64 when _test-* invoked without MAKATO_LOOP_TEST_HOOK=1; got $rc"
fi
# And with the opt-in, it must still work.
MAKATO_LOOP_TEST_HOOK=1 "$LOOP" _test-guarded-sleep 0 >/dev/null 2>&1 \
  || fail "expected exit 0 when _test-* invoked with MAKATO_LOOP_TEST_HOOK=1"
echo "  ✓ test hooks gated behind MAKATO_LOOP_TEST_HOOK=1"

# ---------------------------------------------------------------------------
echo "=== T23: dispatch assigns the issue on the real-fork path (#33) ==="
# The assign fires issues.assigned → project-board-sync.yml moves the board
# Ready → In progress. We route the assign through MAKATO_LOOP_ASSIGN_TEST_FILE
# so no `gh` call is made, and pair it with MAKATO_LOOP_DRY_DISPATCH=1 so the
# state machine runs the assign step (which is AFTER the --dry-run early-return
# but BEFORE the fork) without spawning a subprocess.
rm -f "$STATE_DIR/loop-status.json"
assign_log="$STATE_DIR/assign-audit.txt"
rm -f "$assign_log"
MAKATO_LOOP_DRY_DISPATCH=1 \
  MAKATO_LOOP_ASSIGN_TEST_FILE="$assign_log" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  "$LOOP" dispatch 12345 >/dev/null 2>&1 \
  || fail "dispatch should exit 0 on DRY_DISPATCH path"
[[ -f "$assign_log" ]] || fail "assign audit file not written — assign step skipped"
grep -q "assign #12345 assignee=@me repo=macatocz/makato" "$assign_log" \
  || fail "assign audit missing expected line; got: $(cat "$assign_log" 2>/dev/null)"
echo "  ✓ issue assigned on dispatch (assignee=@me, repo threaded through)"

# Sub-assertion — --dry-run (inspection mode) must NOT assign.
rm -f "$STATE_DIR/loop-status.json" "$assign_log"
MAKATO_LOOP_ASSIGN_TEST_FILE="$assign_log" \
  "$LOOP" dispatch 12345 --dry-run >/dev/null 2>&1 \
  || fail "dispatch --dry-run should exit 0"
[[ ! -f "$assign_log" ]] \
  || fail "--dry-run assigned the issue (inspection mode must not mutate GitHub)"
echo "  ✓ --dry-run does not assign (inspection-only)"

# ---------------------------------------------------------------------------
echo "=== T24: MAKATO_LOOP_ASSIGN_ON_DISPATCH=0 disables assign (#33) ==="
rm -f "$STATE_DIR/loop-status.json" "$assign_log"
MAKATO_LOOP_DRY_DISPATCH=1 \
  MAKATO_LOOP_ASSIGN_ON_DISPATCH=0 \
  MAKATO_LOOP_ASSIGN_TEST_FILE="$assign_log" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  "$LOOP" dispatch 12345 >/dev/null 2>&1 \
  || fail "dispatch should exit 0 with assign disabled"
[[ ! -f "$assign_log" ]] \
  || fail "assign fired even though MAKATO_LOOP_ASSIGN_ON_DISPATCH=0"
echo "  ✓ assign opt-out honored"

# ---------------------------------------------------------------------------
echo "=== T25: dispatch derives KEY/BRANCH and threads the po-agent bundle (#33) ==="
# The dispatch prompt must carry all four required po-agent inputs
# (ISSUE_NUMBER/KEY/REPO/BRANCH/REPO_ROOT), else the po-agent fails input
# validation immediately (the #144 crash). KEY is derived from the issue
# body's to-issues provenance; we inject the body via
# MAKATO_LOOP_ISSUE_BODY_OVERRIDE so no `gh issue view` call is made, and
# assert on the --dry-run echo (which mirrors the real dispatch prompt).
rm -f "$STATE_DIR/loop-status.json"
issue_body_file="$STATE_DIR/t25-issue-body.txt"
cat >"$issue_body_file" <<'ISSUEBODY'
> *This issue was generated by the `to-issues` skill from `specs/test-feature/stories.json`. Edit story-level details in stories.json and re-run.*

## Summary
Test story for T25.

*Feature slug: `test-feature` — produced by to-issues v3.x.*
ISSUEBODY

dry_run_output="$(
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$issue_body_file" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
    "$LOOP" dispatch 500 --dry-run 2>&1 >/dev/null
)" || fail "T25: dispatch --dry-run should exit 0; got: $dry_run_output"

grep -q "KEY=test-feature" <<<"$dry_run_output" \
  || fail "T25: KEY not threaded into dispatch prompt; got: $dry_run_output"
grep -q "REPO=macatocz/makato" <<<"$dry_run_output" \
  || fail "T25: REPO not threaded; got: $dry_run_output"
grep -q "BRANCH=feat/500-test-feature" <<<"$dry_run_output" \
  || fail "T25: BRANCH not threaded; got: $dry_run_output"
grep -q "REPO_ROOT=" <<<"$dry_run_output" \
  || fail "T25: REPO_ROOT not present; got: $dry_run_output"
echo "  ✓ KEY/REPO/BRANCH/REPO_ROOT all threaded into the dispatch prompt"

# Sub-assertion — fallback source: body with only the specs/<slug>/stories.json line.
rm -f "$STATE_DIR/loop-status.json"
fallback_body_file="$STATE_DIR/t25-fallback-body.txt"
printf '%s\n' '> generated from `specs/fallback-slug/stories.json` blah' >"$fallback_body_file"
dry_run_fallback="$(
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$fallback_body_file" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
    "$LOOP" dispatch 501 --dry-run 2>&1 >/dev/null
)" || fail "T25: fallback dispatch --dry-run should exit 0; got: $dry_run_fallback"
grep -q "KEY=fallback-slug" <<<"$dry_run_fallback" \
  || fail "T25: fallback (stories.json) KEY derivation failed; got: $dry_run_fallback"
echo "  ✓ KEY falls back to the specs/<slug>/stories.json provenance line"

# Sub-assertion — derivation failure degrades to a WARN, dispatch still exits 0.
rm -f "$STATE_DIR/loop-status.json"
empty_body_file="$STATE_DIR/t25-empty-body.txt"
printf '' >"$empty_body_file"
dry_run_warn="$(
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$empty_body_file" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
    "$LOOP" dispatch 502 --dry-run 2>&1 >/dev/null
)" || fail "T25: degraded dispatch --dry-run should still exit 0; got: $dry_run_warn"
grep -qi "could not derive KEY" <<<"$dry_run_warn" \
  || fail "T25: expected WARN when body has no provenance; got: $dry_run_warn"
grep -q "KEY= " <<<"$dry_run_warn" \
  || fail "T25: expected empty KEY in the degraded dispatch prompt; got: $dry_run_warn"
echo "  ✓ KEY derivation failure emits WARN and dispatches with empty KEY (po-agent fails input validation)"

echo
echo "=== T26: type:change issues route to makato-change:orchestrate, others to po-agent ==="
# Use MAKATO_LOOP_ISSUE_TYPE_OVERRIDE to bypass gh network call (keeps test offline).
# Use the same body-override fixture from T25 (primary footer path) for KEY derivation.

change_route="$(
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$issue_body_file" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:change" \
    "$LOOP" dispatch 501 --dry-run 2>&1 >/dev/null
)" || fail "T26: type:change dispatch --dry-run should exit 0; got: $change_route"
grep -q "makato-change:orchestrate" <<<"$change_route" \
  || fail "T26: type:change should route to makato-change:orchestrate; got: $change_route"
echo "  ✓ type:change routes to makato-change:orchestrate --autonomous"

poagent_route="$(
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$issue_body_file" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:feature" \
    "$LOOP" dispatch 502 --dry-run 2>&1 >/dev/null
)" || fail "T26: type:feature dispatch --dry-run should exit 0; got: $poagent_route"
grep -q "po-agent" <<<"$poagent_route" \
  || fail "T26: type:feature should route to po-agent; got: $poagent_route"
echo "  ✓ type:feature (and other types) route to po-agent"

no_type_route="$(
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$issue_body_file" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="" \
    "$LOOP" dispatch 503 --dry-run 2>&1 >/dev/null
)" || fail "T26: no-type dispatch --dry-run should exit 0; got: $no_type_route"
grep -q "po-agent" <<<"$no_type_route" \
  || fail "T26: missing type: label should fall back to po-agent; got: $no_type_route"
echo "  ✓ missing type: label falls back to po-agent"

# ---------------------------------------------------------------------------
echo
echo "=== T27: KEY falls back to <issue>-<title-slug> when no to-issues provenance (#232) ==="
# A hand-filed / auto-filed issue carries neither the to-issues footer nor a
# specs/<slug>/stories.json line. _derive_key_for_issue must then derive
# <issue-number>-<normalized-title> (the seed-issue SLUG convention) instead of
# returning empty. Title is injected via MAKATO_LOOP_ISSUE_TITLE_OVERRIDE so no
# `gh issue view` call is made (offline, mirrors the body override).
rm -f "$STATE_DIR/loop-status.json"
noprov_body_file="$STATE_DIR/t27-noprov-body.txt"
cat >"$noprov_body_file" <<'ISSUEBODY'
## Problem
A hand-filed issue with no to-issues provenance whatsoever.

## Proposed fix
Derive the KEY from the issue title.
ISSUEBODY

dry_run_t27="$(
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$noprov_body_file" \
  MAKATO_LOOP_ISSUE_TITLE_OVERRIDE="Fix: loop dispatch fails on empty KEY" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
    "$LOOP" dispatch 503 --dry-run 2>&1 >/dev/null
)" || fail "T27: no-provenance dispatch --dry-run should exit 0; got: $dry_run_t27"
grep -q "KEY=503-fix-loop-dispatch-fails-on-empty" <<<"$dry_run_t27" \
  || fail "T27: KEY not derived from title; got: $dry_run_t27"
grep -q "BRANCH=feat/503-503-fix-loop-dispatch-fails-on-empty" <<<"$dry_run_t27" \
  || fail "T27: BRANCH not derived from title-based KEY; got: $dry_run_t27"
echo "  ✓ no-provenance issue derives KEY=<issue>-<title-slug>"

# Sub-assertion — regression: a provenance body still wins over the title.
rm -f "$STATE_DIR/loop-status.json"
dry_run_t27_regr="$(
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$issue_body_file" \
  MAKATO_LOOP_ISSUE_TITLE_OVERRIDE="This Title Must Be Ignored" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
    "$LOOP" dispatch 504 --dry-run 2>&1 >/dev/null
)" || fail "T27: provenance dispatch --dry-run should exit 0; got: $dry_run_t27_regr"
grep -q "KEY=test-feature" <<<"$dry_run_t27_regr" \
  || fail "T27: provenance footer must win over title; got: $dry_run_t27_regr"
echo "  ✓ to-issues provenance still wins over the title fallback (regression)"

# Sub-assertion — punctuation/uppercase/long titles normalize (collapse, strip, ≤40).
rm -f "$STATE_DIR/loop-status.json"
dry_run_t27_norm="$(
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$noprov_body_file" \
  MAKATO_LOOP_ISSUE_TITLE_OVERRIDE="  [makato-build]  Weird!! Title -- with   JUNK  " \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
    "$LOOP" dispatch 505 --dry-run 2>&1 >/dev/null
)" || fail "T27: normalize dispatch --dry-run should exit 0; got: $dry_run_t27_norm"
grep -q "KEY=505-makato-build-weird-title-with-junk" <<<"$dry_run_t27_norm" \
  || fail "T27: title normalization wrong; got: $dry_run_t27_norm"
echo "  ✓ title normalization collapses runs, strips punctuation, lowercases"

# ---------------------------------------------------------------------------
echo
echo "=== T28: pre-poll promotion moves labelled-ready issues to board Ready (#231) ==="
# _promote_labelled_ready lists open status:ready-for-dev issues and promotes
# those that are off-Ready and not excluded. Fed an offline fixture via
# MAKATO_LOOP_PROMOTE_OVERRIDE and run under MAKATO_LOOP_PROMOTE_DRYRUN=1 so it
# logs intended promotions instead of calling `gh project item-edit`.
rm -f "$STATE_DIR/loop-status.json"
promote_fixture="$STATE_DIR/t28-promote.json"
cat >"$promote_fixture" <<'PROMOTEJSON'
[
  {"number": 601, "labels": [{"name": "status:ready-for-dev"}, {"name": "bug"}]},
  {"number": 602, "labels": [{"name": "status:ready-for-dev"}, {"name": "status:blocked"}]},
  {"number": 603, "labels": [{"name": "status:ready-for-dev"}, {"name": "triage"}]},
  {"number": 604, "labels": [{"name": "status:ready-for-dev"}, {"name": "experimental"}]},
  {"number": 605, "labels": [{"name": "status:ready-for-dev"}, {"name": "autonomous:halt"}]}
]
PROMOTEJSON

promote_out="$(
  MAKATO_LOOP_PROMOTE_OVERRIDE="$promote_fixture" \
  MAKATO_LOOP_PROMOTE_DRYRUN=1 \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
    "$LOOP" promote-ready 2>&1
)" || fail "T28: promote-ready should exit 0; got: $promote_out"
grep -q "would promote #601" <<<"$promote_out" \
  || fail "T28: plain ready issue #601 should be promoted; got: $promote_out"
for skip in 602 603 604 605; do
  grep -q "would promote #${skip}" <<<"$promote_out" \
    && fail "T28: excluded issue #${skip} must NOT be promoted; got: $promote_out"
done
echo "  ✓ only the non-excluded ready issue is promoted; blocked/triage/experimental/halt skipped"

echo
echo "=== ALL TESTS PASSED ==="
