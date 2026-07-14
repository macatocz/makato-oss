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
#   T22: spec-folder resolution accepts all three naming shapes (#233)
#   T23: _test-* hooks refuse to run without MAKATO_LOOP_TEST_HOOK=1
#   T24: dispatch assigns the issue on the real-fork path; --dry-run does not (#33)
#   T25: MAKATO_LOOP_ASSIGN_ON_DISPATCH=0 disables the assign (#33)
#   T26: dispatch derives KEY/BRANCH from the issue body and threads the
#        full po-agent input bundle (ISSUE_NUMBER/KEY/REPO/BRANCH/REPO_ROOT);
#        falls back to specs/<slug>/stories.json; degrades to WARN when absent
#   T27: type:change issues route to makato-change:orchestrate, others to po-agent
#   T30: synchronous board claim CAS prevents cross-worktree double-dispatch —
#        proceeds when card still Ready, skips when already claimed off-Ready,
#        warn-proceeds on unreadable Status, honors CLAIM_ON_DISPATCH=0 (#259)
#   T31–T38: merged-worktree reaper (#265) — remove landed+clean, skip
#        tracked-dirty/locked/not-landed/retained/main; ancestry-of-base reaps
#        a renamed-head branch with no PR; untracked scratch does not pin;
#        nested parent and nested child both skipped; disable + throttle
#   T39–T42: board-poll rate-limit resilience (#289) — retry rides out a
#        transient blip; exhaustion returns non-zero + empty stdout; cmd_poll
#        propagates failure as rc 75; run --once stamps a transient-error state
#        (poll_healthy=false, last_poll_error) instead of a false "queue empty"
#   T44–T48: stale-crash reaper (#320) — dead-pid reap, live-pid skip, age gate,
#        unpushed-commits gate, REAP_STALE_FORCE=1 override
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
# #289 — board-poll rate-limit / transient-failure resilience. The poll must
# retry with backoff and distinguish "poll failed" from "queue empty" so a
# 429'd loop never masquerades as idle. Fully offline via MAKATO_LOOP_POLL_TEST_CMD
# (replaces the real `gh` call) + MAKATO_LOOP_SLEEP_CMD=true (skip backoff waits).
# ---------------------------------------------------------------------------
echo "=== T39: _gh_project_item_list retries then succeeds (transient blip) ==="
# Fail attempts 1-2, succeed on attempt 3. With POLL_RETRIES default 3 the
# wrapper must ride out the blip and return the payload with rc 0.
t39_cmd='if [ "$MAKATO_LOOP_POLL_ATTEMPT" -lt 3 ]; then exit 22; else echo "{\"items\":[{\"content\":{\"type\":\"Issue\",\"number\":777}}]}"; fi'
t39_out="$(MAKATO_LOOP_TEST_HOOK=1 MAKATO_LOOP_SLEEP_CMD=true MAKATO_LOOP_POLL_TEST_CMD="$t39_cmd" \
  "$LOOP" _test-gh-item-list github.com 4 macatocz 2>/dev/null)" \
  || fail "T39: wrapper should return 0 when a later retry succeeds"
jq -e '.items[0].content.number == 777' <<<"$t39_out" >/dev/null \
  || fail "T39: wrapper must emit the successful attempt's payload; got: $t39_out"
echo "  ✓ retried past 2 failures and returned the payload"

echo "=== T40: _gh_project_item_list exhausts retries → non-zero, empty stdout ==="
t40_rc=0
t40_out="$(MAKATO_LOOP_TEST_HOOK=1 MAKATO_LOOP_SLEEP_CMD=true MAKATO_LOOP_POLL_TEST_CMD='exit 22' \
  "$LOOP" _test-gh-item-list github.com 4 macatocz 2>/dev/null)" || t40_rc=$?
[[ $t40_rc -ne 0 ]] || fail "T40: wrapper must return non-zero when every attempt fails"
[[ -z "$t40_out" ]] || fail "T40: wrapper must emit NOTHING on stdout on exhaustion (no fake empty payload); got: $t40_out"
echo "  ✓ exhaustion returns non-zero with empty stdout (no empty-queue masking)"

echo "=== T41: cmd_poll propagates poll failure as rc 75 (not empty queue) ==="
T41_CFG="$STATE_DIR/t41-config.json"
jq -n '{github_project:{owner:"macatocz",number:4,host:"github.com"}}' >"$T41_CFG"
t41_rc=0
# Unset MAKATO_LOOP_GH_OVERRIDE (exported globally above) so cmd_poll takes the
# real gh path — routed here through MAKATO_LOOP_POLL_TEST_CMD — instead of the
# offline fixture, which would succeed and mask the failure branch under test.
t41_out="$(MAKATO_LOOP_GH_OVERRIDE='' MAKATO_LOOP_CONFIG="$T41_CFG" MAKATO_LOOP_SLEEP_CMD=true \
  MAKATO_LOOP_POLL_TEST_CMD='exit 22' \
  "$LOOP" poll Ready 2>/dev/null)" || t41_rc=$?
[[ $t41_rc -eq 75 ]] || fail "T41: cmd_poll must exit 75 (EX_TEMPFAIL) on poll failure; got rc=$t41_rc"
[[ -z "$t41_out" ]] || fail "T41: cmd_poll must not print a fabricated empty array on failure; got: $t41_out"
echo "  ✓ failed poll surfaces rc 75, does not print an empty queue"

echo "=== T42: run --once on failed poll stamps transient-error state, no idle-dispatch ==="
T42_STATE="$STATE_DIR/t42"; mkdir -p "$T42_STATE"
T42_CFG="$STATE_DIR/t42-config.json"
jq -n '{github_project:{owner:"macatocz",number:4,host:"github.com"}}' >"$T42_CFG"
rm -f "$HALT_FILE"
# MAKATO_LOOP_GH_OVERRIDE unset here too — the run's poll must hit the failing
# MAKATO_LOOP_POLL_TEST_CMD, not the offline fixture.
t42_out="$(MAKATO_LOOP_GH_OVERRIDE='' MAKATO_LOOP_STATE_DIR="$T42_STATE" MAKATO_LOOP_CONFIG="$T42_CFG" \
  MAKATO_HALT_FILE="$HALT_FILE" MAKATO_LOOP_SLEEP_CMD=true \
  MAKATO_LOOP_POLL_TEST_CMD='exit 22' MAKATO_LOOP_REAP_ON_POLL=0 \
  MAKATO_LOOP_POLL_ERROR_BACKOFF=0 \
  "$LOOP" run --once --status Ready 2>&1)" \
  || fail "T42: run --once should exit 0 even when the poll fails; out: $t42_out"
grep -q "board poll FAILED" <<<"$t42_out" \
  || fail "T42: a failed poll must log 'board poll FAILED'; got: $t42_out"
grep -q "queue empty" <<<"$t42_out" \
  && fail "T42: a failed poll must NOT log 'queue empty' (that is the #289 bug); got: $t42_out"
jq -e '.poll_healthy == false' "$T42_STATE/loop-status.json" >/dev/null \
  || fail "T42: loop-status.json must record poll_healthy=false after a failed poll"
jq -e '.last_poll_error != null' "$T42_STATE/loop-status.json" >/dev/null \
  || fail "T42: loop-status.json must stamp last_poll_error after a failed poll"
echo "  ✓ transient-error state recorded; no false 'queue empty' idle"


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
echo "=== T22: spec-folder resolution accepts all three naming shapes (#233) ==="
# Verifies the two-step resolver extracted from po-agent.md Step 1:
#   1. prefix-match specs/<KEY>-*/
#   2. exact-match fallback specs/<KEY>/
# Each of the three naming conventions used by makato-plan/build/change must
# resolve without HALT-006.
t22_tmpdir="$(mktemp -d)"
mkdir -p \
  "$t22_tmpdir/specs/test-bare-slug" \
  "$t22_tmpdir/specs/42-test-foo" \
  "$t22_tmpdir/specs/ISSUE-42"

resolve_spec_folder() {
  local key="$1"
  local specs_dir="$2"
  # Step 1: prefix-match
  local match
  match="$(ls -d "$specs_dir/${key}"-*/ 2>/dev/null | head -1)"
  [[ -n "$match" ]] && { echo "$match"; return 0; }
  # Step 2: exact-match fallback
  [[ -d "$specs_dir/${key}/" ]] && { echo "$specs_dir/${key}/"; return 0; }
  return 1
}

# Assertion 1 — bare slug (makato-plan:decompose style): exact-match fallback.
r1="$(resolve_spec_folder "test-bare-slug" "$t22_tmpdir/specs")"
[[ -n "$r1" ]] || fail "T22: bare slug 'test-bare-slug' did not resolve"
[[ "$r1" == *"test-bare-slug"* ]] \
  || fail "T22: bare slug resolved to wrong path: $r1"
echo "  ✓ bare slug (makato-plan style) resolves via exact-match fallback"

# Assertion 2 — <N>-<slug> (seed-issue / to-issues style): prefix-match.
r2="$(resolve_spec_folder "42" "$t22_tmpdir/specs")"
[[ -n "$r2" ]] || fail "T22: issue-number prefix '42' did not resolve"
[[ "$r2" == *"42-test-foo"* ]] \
  || fail "T22: prefix-match resolved to wrong path: $r2"
echo "  ✓ <N>-<slug> (seed-issue / to-issues style) resolves via prefix-match"

# Assertion 3 — ISSUE-42 (makato-change style): exact-match fallback.
r3="$(resolve_spec_folder "ISSUE-42" "$t22_tmpdir/specs")"
[[ -n "$r3" ]] || fail "T22: ISSUE key 'ISSUE-42' did not resolve"
[[ "$r3" == *"ISSUE-42"* ]] \
  || fail "T22: ISSUE key resolved to wrong path: $r3"
echo "  ✓ ISSUE-<N> (makato-change style) resolves via exact-match fallback"

# Assertion 4 — nonexistent key returns 1.
rc=0
resolve_spec_folder "nonexistent" "$t22_tmpdir/specs" >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] \
  || fail "T22: expected non-zero exit for nonexistent key; got $rc"
echo "  ✓ nonexistent key returns non-zero (no false match)"

rm -rf "$t22_tmpdir"
echo "  ✓ T22 complete: all three spec-folder naming shapes resolve correctly"

# ---------------------------------------------------------------------------
echo "=== T23: _test-* hooks refuse to run without MAKATO_LOOP_TEST_HOOK=1 ==="
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
echo "=== T24: dispatch assigns the issue on the real-fork path (#33) ==="
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
echo "=== T25: MAKATO_LOOP_ASSIGN_ON_DISPATCH=0 disables assign (#33) ==="
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
echo "=== T26: dispatch derives KEY/BRANCH and threads the po-agent bundle (#33) ==="
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
)" || fail "T26: dispatch --dry-run should exit 0; got: $dry_run_output"

grep -q "KEY=test-feature" <<<"$dry_run_output" \
  || fail "T26: KEY not threaded into dispatch prompt; got: $dry_run_output"
grep -q "REPO=macatocz/makato" <<<"$dry_run_output" \
  || fail "T26: REPO not threaded; got: $dry_run_output"
grep -q "BRANCH=feat/500-test-feature" <<<"$dry_run_output" \
  || fail "T26: BRANCH not threaded; got: $dry_run_output"
grep -q "REPO_ROOT=" <<<"$dry_run_output" \
  || fail "T26: REPO_ROOT not present; got: $dry_run_output"
echo "  ✓ KEY/REPO/BRANCH/REPO_ROOT all threaded into the dispatch prompt"

# Sub-assertion — fallback source: body with only the specs/<slug>/stories.json line.
rm -f "$STATE_DIR/loop-status.json"
fallback_body_file="$STATE_DIR/t25-fallback-body.txt"
printf '%s\n' '> generated from `specs/fallback-slug/stories.json` blah' >"$fallback_body_file"
dry_run_fallback="$(
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$fallback_body_file" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
    "$LOOP" dispatch 501 --dry-run 2>&1 >/dev/null
)" || fail "T26: fallback dispatch --dry-run should exit 0; got: $dry_run_fallback"
grep -q "KEY=fallback-slug" <<<"$dry_run_fallback" \
  || fail "T26: fallback (stories.json) KEY derivation failed; got: $dry_run_fallback"
echo "  ✓ KEY falls back to the specs/<slug>/stories.json provenance line"

# Sub-assertion — derivation failure degrades to a WARN, dispatch still exits 0.
rm -f "$STATE_DIR/loop-status.json"
empty_body_file="$STATE_DIR/t25-empty-body.txt"
printf '' >"$empty_body_file"
dry_run_warn="$(
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$empty_body_file" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
    "$LOOP" dispatch 502 --dry-run 2>&1 >/dev/null
)" || fail "T26: degraded dispatch --dry-run should still exit 0; got: $dry_run_warn"
grep -qi "could not derive KEY" <<<"$dry_run_warn" \
  || fail "T26: expected WARN when body has no provenance; got: $dry_run_warn"
grep -q "KEY= " <<<"$dry_run_warn" \
  || fail "T26: expected empty KEY in the degraded dispatch prompt; got: $dry_run_warn"
echo "  ✓ KEY derivation failure emits WARN and dispatches with empty KEY (po-agent fails input validation)"

echo
echo "=== T27: type:change issues route to makato-change:orchestrate, others to po-agent ==="
# Use MAKATO_LOOP_ISSUE_TYPE_OVERRIDE to bypass gh network call (keeps test offline).
# Use the same body-override fixture from T26 (primary footer path) for KEY derivation.

change_route="$(
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$issue_body_file" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:change" \
    "$LOOP" dispatch 501 --dry-run 2>&1 >/dev/null
)" || fail "T27: type:change dispatch --dry-run should exit 0; got: $change_route"
grep -q "makato-change:orchestrate" <<<"$change_route" \
  || fail "T27: type:change should route to makato-change:orchestrate; got: $change_route"
echo "  ✓ type:change routes to makato-change:orchestrate --autonomous"

poagent_route="$(
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$issue_body_file" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:feature" \
    "$LOOP" dispatch 502 --dry-run 2>&1 >/dev/null
)" || fail "T27: type:feature dispatch --dry-run should exit 0; got: $poagent_route"
grep -q "po-agent" <<<"$poagent_route" \
  || fail "T27: type:feature should route to po-agent; got: $poagent_route"
echo "  ✓ type:feature (and other types) route to po-agent"

no_type_route="$(
  MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$issue_body_file" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="" \
    "$LOOP" dispatch 503 --dry-run 2>&1 >/dev/null
)" || fail "T27: no-type dispatch --dry-run should exit 0; got: $no_type_route"
grep -q "po-agent" <<<"$no_type_route" \
  || fail "T27: missing type: label should fall back to po-agent; got: $no_type_route"
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
  {"number": 605, "labels": [{"name": "status:ready-for-dev"}, {"name": "autonomous:halt"}]},
  {"number": 606, "labels": [{"name": "status:ready-for-dev"}, {"name": "needs-human-review"}]}
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
for skip in 602 603 604 605 606; do
  grep -q "would promote #${skip}" <<<"$promote_out" \
    && fail "T28: excluded issue #${skip} must NOT be promoted; got: $promote_out"
done
echo "  ✓ only the non-excluded ready issue is promoted; blocked/triage/experimental/halt/needs-human-review skipped"

echo
echo "=== ALL TESTS PASSED ==="

echo "=== T29: spec-folder resolution accepts all three naming shapes (#233) ==="
t29_tmp="$(mktemp -d)"
mkdir -p "$t29_tmp/specs/test-bare-slug"
mkdir -p "$t29_tmp/specs/42-test-foo"
mkdir -p "$t29_tmp/specs/ISSUE-42"

resolve_spec_folder() {
  local key="$1" specs_dir="$2" match
  match="$(ls -d "${specs_dir}/${key}"-*/ 2>/dev/null | head -1)"
  [[ -n "$match" ]] && { echo "$match"; return 0; }
  [[ -d "${specs_dir}/${key}/" ]] && { echo "${specs_dir}/${key}/"; return 0; }
  return 1
}

r1="$(resolve_spec_folder "test-bare-slug" "$t29_tmp/specs")" \
  && [[ "$r1" == *"test-bare-slug"* ]] \
  || fail "T29: bare-slug folder not resolved; got: $r1"
echo "  ✓ bare slug specs/test-bare-slug/ resolved via exact-match fallback"

r2="$(resolve_spec_folder "42" "$t29_tmp/specs")" \
  && [[ "$r2" == *"42-test-foo"* ]] \
  || fail "T29: prefix-match N-slug folder not resolved; got: $r2"
echo "  ✓ canonical specs/42-test-foo/ resolved via prefix-match"

r3="$(resolve_spec_folder "ISSUE-42" "$t29_tmp/specs")" \
  && [[ "$r3" == *"ISSUE-42"* ]] \
  || fail "T29: issue-key folder not resolved; got: $r3"
echo "  ✓ issue-key specs/ISSUE-42/ resolved via exact-match fallback"

resolve_spec_folder "nonexistent" "$t29_tmp/specs" 2>/dev/null \
  && fail "T29: nonexistent key should return 1" || true
echo "  ✓ nonexistent key correctly returns no match"

rm -rf "$t29_tmp"

# ---------------------------------------------------------------------------
echo
echo "=== T30: synchronous board claim CAS prevents cross-worktree double-dispatch (#259) ==="
# _claim_board_card re-polls the target issue's board Status and only proceeds
# (returns 0) when it is still the dispatch Status; if a second worktree-local
# loop session already claimed the card (Status moved off Ready), it returns 1
# and cmd_dispatch skips the issue without spawning. Exercised offline via
# MAKATO_LOOP_CLAIM_TEST_FILE + MAKATO_LOOP_CLAIM_STATUS_OVERRIDE so no `gh`
# call is made. Threaded through the public `dispatch` subcommand end-to-end.
claim_file="$STATE_DIR/t30-claim.txt"
assign_file="$STATE_DIR/t30-assign.txt"

# Sub-assertion 1 — card still Ready → CLAIM, dispatch proceeds (and assigns).
rm -f "$STATE_DIR/loop-status.json"
: >"$claim_file"; : >"$assign_file"
MAKATO_LOOP_DRY_DISPATCH=1 \
MAKATO_LOOP_CLAIM_TEST_FILE="$claim_file" \
MAKATO_LOOP_CLAIM_STATUS_OVERRIDE="Ready" \
MAKATO_LOOP_ASSIGN_TEST_FILE="$assign_file" \
MAKATO_LOOP_GATE_DISABLE=1 \
MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  "$LOOP" dispatch 101 >/dev/null 2>&1 || fail "T30: dispatch should exit 0 on a successful claim"
grep -q "claim #101 status=Ready → claimed" "$claim_file" \
  || fail "T30: card still Ready should CLAIM; got: $(cat "$claim_file")"
grep -q "assign #101" "$assign_file" \
  || fail "T30: a claimed dispatch must still assign; got: $(cat "$assign_file")"
jq -e '.active_workflow == null' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "T30: active_workflow must be cleared after a claimed dispatch"
echo "  ✓ card still Ready → claimed, dispatch proceeds and assigns"

# Sub-assertion 2 — card already In progress (a second session claimed it
# first) → SKIP: no spawn, no assign, active_workflow cleared, clean exit 0.
rm -f "$STATE_DIR/loop-status.json"
: >"$claim_file"; : >"$assign_file"
rc=0
MAKATO_LOOP_DRY_DISPATCH=1 \
MAKATO_LOOP_CLAIM_TEST_FILE="$claim_file" \
MAKATO_LOOP_CLAIM_STATUS_OVERRIDE="In progress" \
MAKATO_LOOP_ASSIGN_TEST_FILE="$assign_file" \
MAKATO_LOOP_GATE_DISABLE=1 \
MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  "$LOOP" dispatch 101 >/dev/null 2>&1 || rc=$?
[[ $rc -eq 0 ]] || fail "T30: a lost CAS must be a clean skip (exit 0), got $rc"
grep -q "claim #101 status=In progress → skip" "$claim_file" \
  || fail "T30: card off-Ready should SKIP; got: $(cat "$claim_file")"
[[ ! -s "$assign_file" ]] \
  || fail "T30: a skipped dispatch must NOT assign; got: $(cat "$assign_file")"
jq -e '.active_workflow == null' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "T30: active_workflow must be cleared after a skipped claim"
echo "  ✓ card claimed by another session → skip, no spawn, no assign, active_workflow cleared"

# Sub-assertion 3 — claim cannot read Status (gh outage / empty) → WARN and
# PROCEED (best-effort fallback: degrade to pre-#259 assign-only, never block).
rm -f "$STATE_DIR/loop-status.json"
: >"$claim_file"; : >"$assign_file"
MAKATO_LOOP_DRY_DISPATCH=1 \
MAKATO_LOOP_CLAIM_TEST_FILE="$claim_file" \
MAKATO_LOOP_CLAIM_STATUS_OVERRIDE="" \
MAKATO_LOOP_ASSIGN_TEST_FILE="$assign_file" \
MAKATO_LOOP_GATE_DISABLE=1 \
MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  "$LOOP" dispatch 101 >/dev/null 2>&1 || fail "T30: an unreadable Status must not block dispatch"
grep -q "claim #101 status=<unknown> → warn-proceed" "$claim_file" \
  || fail "T30: unreadable Status should warn-proceed; got: $(cat "$claim_file")"
grep -q "assign #101" "$assign_file" \
  || fail "T30: a warn-proceed dispatch must still assign; got: $(cat "$assign_file")"
echo "  ✓ unreadable Status → WARN + proceed (best-effort fallback, dispatch not blocked)"

# Sub-assertion 4 — MAKATO_LOOP_CLAIM_ON_DISPATCH=0 disables the claim entirely
# (no claim decision recorded; dispatch falls back to the async assign path).
rm -f "$STATE_DIR/loop-status.json"
: >"$claim_file"; : >"$assign_file"
MAKATO_LOOP_DRY_DISPATCH=1 \
MAKATO_LOOP_CLAIM_ON_DISPATCH=0 \
MAKATO_LOOP_CLAIM_TEST_FILE="$claim_file" \
MAKATO_LOOP_CLAIM_STATUS_OVERRIDE="In progress" \
MAKATO_LOOP_ASSIGN_TEST_FILE="$assign_file" \
MAKATO_LOOP_GATE_DISABLE=1 \
MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  "$LOOP" dispatch 101 >/dev/null 2>&1 || fail "T30: claim-disabled dispatch should exit 0"
[[ ! -s "$claim_file" ]] \
  || fail "T30: CLAIM_ON_DISPATCH=0 must record no claim decision; got: $(cat "$claim_file")"
grep -q "assign #101" "$assign_file" \
  || fail "T30: claim-disabled dispatch must still assign (async fallback)"
echo "  ✓ MAKATO_LOOP_CLAIM_ON_DISPATCH=0 disables the claim; async assign path used"

# ---------------------------------------------------------------------------
# T31–T38: merged-worktree reaper (#265)
#
# The reaper walks `git worktree list --porcelain` for REPO_ROOT and removes
# worktrees whose work has LANDED on the base branch (merged PR OR HEAD is an
# ancestor of the base ref), skipping main / tracked-dirty / locked / retained
# / detached / nested. These tests build a DISPOSABLE temp git repo (never the
# real makato checkout) with real worktrees and drive the standalone
# `remove-worktrees` subcommand from inside it (so loop.sh's REPO_ROOT resolves
# to the temp repo). Merged-PR lookups are stubbed offline via
# MAKATO_LOOP_REAP_GH_OVERRIDE; ancestry uses the temp repo's real `main` via
# MAKATO_LOOP_REAP_BASE_REF; the throttle is bypassed with
# MAKATO_LOOP_REAP_INTERVAL=0.
# ---------------------------------------------------------------------------
echo
echo "=== T31: reaper removes a merged, clean worktree; skips others ==="
REAP_ROOT="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/reap-repo"
REAP_STATE="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/reap-state"
mkdir -p "$REAP_ROOT" "$REAP_STATE"
(
  cd "$REAP_ROOT"
  git init -q -b main
  git config user.email t@t.t; git config user.name t
  git commit -q --allow-empty -m init
  # Each worktree gets its OWN commit on top of main, so none is an ancestor of
  # main — this isolates the merged-PR signal (guard 8a) from ancestry (8b),
  # which T36 exercises separately.
  for b in merged-clean dirty locked open-pr; do
    git worktree add -q -b "feat/$b" "$REAP_ROOT/.claude/worktrees/$b" 2>/dev/null
    git -C "$REAP_ROOT/.claude/worktrees/$b" commit -q --allow-empty -m "$b work"
  done
  echo "uncommitted" >"$REAP_ROOT/.claude/worktrees/dirty/tracked.txt"
  git -C "$REAP_ROOT/.claude/worktrees/dirty" add tracked.txt   # staged tracked change
  git worktree lock "$REAP_ROOT/.claude/worktrees/locked" 2>/dev/null
)
# Merged-PR fixture: merged-clean/dirty/locked have merged PRs; open-pr does not.
REAP_GH="$REAP_STATE/reap-gh.json"
cat >"$REAP_GH" <<'REAPJSON'
{
  "feat/merged-clean": "701",
  "feat/dirty": "702",
  "feat/locked": "703"
}
REAPJSON

# Dry-run first: assert the decision set without mutating anything.
reap_dry="$(
  cd "$REAP_ROOT" &&
  MAKATO_LOOP_STATE_DIR="$REAP_STATE" \
  MAKATO_LOOP_REAP_INTERVAL=0 \
  MAKATO_LOOP_REAP_DRYRUN=1 \
  MAKATO_LOOP_REAP_GH_OVERRIDE="$REAP_GH" \
  MAKATO_LOOP_REAP_BASE_REF="main" \
  MAKATO_LOOP_REAP_REPO="macatocz/makato" \
    "$LOOP" remove-worktrees 2>&1
)" || fail "T31: remove-worktrees (dry-run) should exit 0; got: $reap_dry"
grep -q "would remove .*/merged-clean (merged PR #701" <<<"$reap_dry" \
  || fail "T31: merged+clean should be a removal candidate; got: $reap_dry"
grep -q "reap skip .*/dirty (dirty working tree — tracked" <<<"$reap_dry" \
  || fail "T31: tracked-dirty worktree must be skipped; got: $reap_dry"
grep -q "reap skip .*/locked (locked" <<<"$reap_dry" \
  || fail "T31: locked worktree must be skipped; got: $reap_dry"
grep -q "reap skip .*/open-pr (branch feat/open-pr not landed" <<<"$reap_dry" \
  || fail "T31: not-landed worktree must be skipped; got: $reap_dry"
grep -q "would remove $REAP_ROOT " <<<"$reap_dry" \
  && fail "T31: main checkout must never be a removal candidate; got: $reap_dry"
echo "  ✓ dry-run: merged+clean → remove; tracked-dirty/locked/not-landed/main → skip"

echo
echo "=== T32: reaper actually removes the merged worktree (live) ==="
reap_live="$(
  cd "$REAP_ROOT" &&
  MAKATO_LOOP_STATE_DIR="$REAP_STATE" \
  MAKATO_LOOP_REAP_INTERVAL=0 \
  MAKATO_LOOP_REAP_GH_OVERRIDE="$REAP_GH" \
  MAKATO_LOOP_REAP_BASE_REF="main" \
  MAKATO_LOOP_REAP_REPO="macatocz/makato" \
    "$LOOP" remove-worktrees 2>&1
)" || fail "T32: remove-worktrees (live) should exit 0; got: $reap_live"
# merged-clean must be gone from the worktree registry; the others must remain.
reap_list="$(cd "$REAP_ROOT" && git worktree list --porcelain)"
grep -q "/merged-clean$" <<<"$reap_list" \
  && fail "T32: merged-clean should have been removed; still registered"
grep -q "/dirty$" <<<"$reap_list" \
  || fail "T32: tracked-dirty worktree must survive; got removed"
grep -q "/locked$" <<<"$reap_list" \
  || fail "T32: locked worktree must survive; got removed"
grep -q "/open-pr$" <<<"$reap_list" \
  || fail "T32: not-landed worktree must survive; got removed"
# Status audit: last_reap stamped, count == 1, reaped[0].landed mentions PR 701.
jq -e '.last_reap != null' "$REAP_STATE/loop-status.json" >/dev/null \
  || fail "T32: last_reap must be stamped"
jq -e '.last_reap_count == 1' "$REAP_STATE/loop-status.json" >/dev/null \
  || fail "T32: last_reap_count should be 1; got $(jq -r .last_reap_count "$REAP_STATE/loop-status.json")"
jq -e '.reaped[0].landed | test("701")' "$REAP_STATE/loop-status.json" >/dev/null \
  || fail "T32: reaped[0].landed should mention PR 701; got $(jq -c .reaped "$REAP_STATE/loop-status.json")"
echo "  ✓ merged-clean removed; tracked-dirty/locked/not-landed survive; status audit correct"
# Unlock so the EXIT trap can tear the sandbox worktrees down cleanly.
(cd "$REAP_ROOT" && git worktree unlock "$REAP_ROOT/.claude/worktrees/locked" 2>/dev/null || true)

echo
echo "=== T33: retained worktree (workflow-state) is skipped ==="
REAP2_ROOT="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/reap2-repo"
REAP2_STATE="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/reap2-state"
mkdir -p "$REAP2_ROOT" "$REAP2_STATE"
(
  cd "$REAP2_ROOT"
  git init -q -b main
  git config user.email t@t.t; git config user.name t
  git commit -q --allow-empty -m init
  git worktree add -q -b feat/retained "$REAP2_ROOT/.claude/worktrees/retained-wt" 2>/dev/null
  git -C "$REAP2_ROOT/.claude/worktrees/retained-wt" commit -q --allow-empty -m "retained work"
)
# Real realpath of the worktree, as the reaper canonicalises before comparing.
RETAINED_RP="$(cd "$REAP2_ROOT/.claude/worktrees/retained-wt" && pwd -P)"
mkdir -p "$REAP2_ROOT/specs/test-key"
jq -n --arg p "$RETAINED_RP" \
  '{issue_number:46, current_phase:"implement", worktree_path:$p, worktree_retained:true, worktree_retain_reason:"HALT-008"}' \
  >"$REAP2_ROOT/specs/test-key/workflow-state-46.json"
REAP2_GH="$REAP2_STATE/reap2-gh.json"
echo '{"feat/retained":"801"}' >"$REAP2_GH"
reap2_out="$(
  cd "$REAP2_ROOT" &&
  MAKATO_LOOP_STATE_DIR="$REAP2_STATE" \
  MAKATO_LOOP_REAP_INTERVAL=0 \
  MAKATO_LOOP_REAP_DRYRUN=1 \
  MAKATO_LOOP_REAP_GH_OVERRIDE="$REAP2_GH" \
  MAKATO_LOOP_REAP_BASE_REF="main" \
  MAKATO_LOOP_REAP_REPO="macatocz/makato" \
    "$LOOP" remove-worktrees 2>&1
)" || fail "T33: remove-worktrees should exit 0; got: $reap2_out"
grep -q "reap skip .*retained-wt (worktree_retained=true" <<<"$reap2_out" \
  || fail "T33: retained worktree must be skipped; got: $reap2_out"
grep -q "would remove .*retained-wt" <<<"$reap2_out" \
  && fail "T33: retained worktree must NOT be a removal candidate; got: $reap2_out"
echo "  ✓ worktree_retained=true (via workflow-state) vetoes reap even for a merged PR"

echo
echo "=== T34: MAKATO_LOOP_REAP_ON_POLL=0 disables the reaper entirely ==="
reap_off="$(
  cd "$REAP2_ROOT" &&
  MAKATO_LOOP_STATE_DIR="$REAP2_STATE" \
  MAKATO_LOOP_REAP_ON_POLL=0 \
  MAKATO_LOOP_REAP_INTERVAL=0 \
  MAKATO_LOOP_REAP_GH_OVERRIDE="$REAP2_GH" \
  MAKATO_LOOP_REAP_REPO="macatocz/makato" \
    "$LOOP" remove-worktrees 2>&1
)" || fail "T34: remove-worktrees should exit 0 when disabled; got: $reap_off"
[[ -z "$(grep -E 'reap (skip|would remove|removing)' <<<"$reap_off")" ]] \
  || fail "T34: REAP_ON_POLL=0 must produce no reap activity; got: $reap_off"
echo "  ✓ REAP_ON_POLL=0 short-circuits the whole pass (no candidates walked)"

echo
echo "=== T35: throttle — a second call within REAP_INTERVAL is a no-op ==="
REAP3_STATE="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/reap3-state"
mkdir -p "$REAP3_STATE"
# First pass with a large interval stamps last_reap.
(
  cd "$REAP2_ROOT" &&
  MAKATO_LOOP_STATE_DIR="$REAP3_STATE" \
  MAKATO_LOOP_REAP_INTERVAL=3600 \
  MAKATO_LOOP_REAP_DRYRUN=1 \
  MAKATO_LOOP_REAP_GH_OVERRIDE="$REAP2_GH" \
  MAKATO_LOOP_REAP_BASE_REF="main" \
  MAKATO_LOOP_REAP_REPO="macatocz/makato" \
    "$LOOP" remove-worktrees >/dev/null 2>&1
) || fail "T35: first reap pass should exit 0"
jq -e '.last_reap != null' "$REAP3_STATE/loop-status.json" >/dev/null \
  || fail "T35: first pass must stamp last_reap"
# Second pass immediately after: throttle should short-circuit → no reap lines.
reap_throttled="$(
  cd "$REAP2_ROOT" &&
  MAKATO_LOOP_STATE_DIR="$REAP3_STATE" \
  MAKATO_LOOP_REAP_INTERVAL=3600 \
  MAKATO_LOOP_REAP_DRYRUN=1 \
  MAKATO_LOOP_REAP_GH_OVERRIDE="$REAP2_GH" \
  MAKATO_LOOP_REAP_BASE_REF="main" \
  MAKATO_LOOP_REAP_REPO="macatocz/makato" \
    "$LOOP" remove-worktrees 2>&1
)" || fail "T35: throttled reap pass should exit 0"
[[ -z "$(grep -E 'reap (skip|would remove|removing)' <<<"$reap_throttled")" ]] \
  || fail "T35: throttle must short-circuit within the interval; got: $reap_throttled"
echo "  ✓ second call within REAP_INTERVAL no-ops (throttle honoured)"

echo
echo "=== T36: ancestry — a landed branch with NO merged PR (renamed head) is reaped ==="
# The worktree's HEAD is an ancestor of main (its work was merged, e.g. via a
# PR whose head branch was renamed so the gh --head lookup misses it). With an
# EMPTY merged-PR fixture, only guard 8b (ancestor of base) can authorise it.
REAP4_ROOT="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/reap4-repo"
REAP4_STATE="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/reap4-state"
mkdir -p "$REAP4_ROOT" "$REAP4_STATE"
(
  cd "$REAP4_ROOT"
  git init -q -b main
  git config user.email t@t.t; git config user.name t
  git commit -q --allow-empty -m init
  # landed-wt: branch off main with no extra commits → HEAD == main tip's
  # ancestor set. Advance main past it so the branch tip is a STRICT ancestor.
  git worktree add -q -b feat/landed "$REAP4_ROOT/.claude/worktrees/landed-wt" 2>/dev/null
  git commit -q --allow-empty -m "main moves on"   # main now ahead of feat/landed
  # fresh-wt: sits exactly on the (new) main tip with no commits of its own —
  # HEAD == base tip, which must NOT be treated as landed (guard 8b equality
  # exclusion), and no merged PR → must survive.
  git worktree add -q -b feat/fresh "$REAP4_ROOT/.claude/worktrees/fresh-wt" main 2>/dev/null
)
REAP4_GH="$REAP4_STATE/reap4-gh.json"
echo '{}' >"$REAP4_GH"   # no merged PRs at all
reap4_out="$(
  cd "$REAP4_ROOT" &&
  MAKATO_LOOP_STATE_DIR="$REAP4_STATE" \
  MAKATO_LOOP_REAP_INTERVAL=0 \
  MAKATO_LOOP_REAP_DRYRUN=1 \
  MAKATO_LOOP_REAP_GH_OVERRIDE="$REAP4_GH" \
  MAKATO_LOOP_REAP_BASE_REF="main" \
  MAKATO_LOOP_REAP_REPO="macatocz/makato" \
    "$LOOP" remove-worktrees 2>&1
)" || fail "T36: remove-worktrees should exit 0; got: $reap4_out"
grep -q "would remove .*landed-wt (ancestor of main" <<<"$reap4_out" \
  || fail "T36: ancestor-of-main branch (no PR) must be reaped via guard 8b; got: $reap4_out"
grep -q "reap skip .*fresh-wt (branch feat/fresh not landed" <<<"$reap4_out" \
  || fail "T36: fresh worktree sitting on base tip must survive (no work landed); got: $reap4_out"
echo "  ✓ ancestor-of-base branch reaped even without a merged PR; fresh-on-tip survives"

echo
echo "=== T37: untracked-only scratch does NOT pin a landed worktree ==="
# A landed (merged-PR) worktree carrying only UNTRACKED files (build artefacts,
# generated HTML) must still be reaped — untracked scratch is not work.
REAP5_ROOT="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/reap5-repo"
REAP5_STATE="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/reap5-state"
mkdir -p "$REAP5_ROOT" "$REAP5_STATE"
(
  cd "$REAP5_ROOT"
  git init -q -b main
  git config user.email t@t.t; git config user.name t
  git commit -q --allow-empty -m init
  git worktree add -q -b feat/scratch "$REAP5_ROOT/.claude/worktrees/scratch-wt" 2>/dev/null
  git -C "$REAP5_ROOT/.claude/worktrees/scratch-wt" commit -q --allow-empty -m "scratch work"
  echo "generated" >"$REAP5_ROOT/.claude/worktrees/scratch-wt/artifact.html"   # UNTRACKED only
)
REAP5_GH="$REAP5_STATE/reap5-gh.json"
echo '{"feat/scratch":"901"}' >"$REAP5_GH"
reap5_out="$(
  cd "$REAP5_ROOT" &&
  MAKATO_LOOP_STATE_DIR="$REAP5_STATE" \
  MAKATO_LOOP_REAP_INTERVAL=0 \
  MAKATO_LOOP_REAP_DRYRUN=1 \
  MAKATO_LOOP_REAP_GH_OVERRIDE="$REAP5_GH" \
  MAKATO_LOOP_REAP_BASE_REF="main" \
  MAKATO_LOOP_REAP_REPO="macatocz/makato" \
    "$LOOP" remove-worktrees 2>&1
)" || fail "T37: remove-worktrees should exit 0; got: $reap5_out"
grep -q "would remove .*scratch-wt" <<<"$reap5_out" \
  || fail "T37: untracked-only scratch must not pin a landed worktree; got: $reap5_out"
echo "  ✓ untracked-only working tree is reaped (only tracked changes pin)"

echo
echo "=== T38: a worktree nested inside another worktree is skipped ==="
# A worktree registered inside ANOTHER worktree's .claude/worktrees/ must be
# skipped (removing it there corrupts the parent). The parent's OWN
# .claude/worktrees/ living under the main checkout is NOT nesting.
REAP6_ROOT="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/reap6-repo"
REAP6_STATE="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/reap6-state"
mkdir -p "$REAP6_ROOT" "$REAP6_STATE"
(
  cd "$REAP6_ROOT"
  git init -q -b main
  git config user.email t@t.t; git config user.name t
  git commit -q --allow-empty -m init
  # parent-wt directly under the main checkout (normal layout).
  git worktree add -q -b feat/parent "$REAP6_ROOT/.claude/worktrees/parent-wt" 2>/dev/null
  git -C "$REAP6_ROOT/.claude/worktrees/parent-wt" commit -q --allow-empty -m "parent work"
  # child-wt registered INSIDE parent-wt's own .claude/worktrees/ (true nesting).
  git -C "$REAP6_ROOT/.claude/worktrees/parent-wt" worktree add -q -b feat/child \
    "$REAP6_ROOT/.claude/worktrees/parent-wt/.claude/worktrees/child-wt" 2>/dev/null
  git -C "$REAP6_ROOT/.claude/worktrees/parent-wt/.claude/worktrees/child-wt" \
    commit -q --allow-empty -m "child work"
)
REAP6_GH="$REAP6_STATE/reap6-gh.json"
echo '{"feat/parent":"911","feat/child":"912"}' >"$REAP6_GH"
reap6_out="$(
  cd "$REAP6_ROOT" &&
  MAKATO_LOOP_STATE_DIR="$REAP6_STATE" \
  MAKATO_LOOP_REAP_INTERVAL=0 \
  MAKATO_LOOP_REAP_DRYRUN=1 \
  MAKATO_LOOP_REAP_GH_OVERRIDE="$REAP6_GH" \
  MAKATO_LOOP_REAP_BASE_REF="main" \
  MAKATO_LOOP_REAP_REPO="macatocz/makato" \
    "$LOOP" remove-worktrees 2>&1
)" || fail "T38: remove-worktrees should exit 0; got: $reap6_out"
grep -q "reap skip .*/parent-wt (parent of nested worktree" <<<"$reap6_out" \
  || fail "T38: parent of a nested worktree must be skipped; got: $reap6_out"
grep -q "reap skip .*/child-wt (nested inside worktree .*parent-wt" <<<"$reap6_out" \
  || fail "T38: child nested inside another worktree must be skipped; got: $reap6_out"
grep -q "would remove .*child-wt" <<<"$reap6_out" \
  && fail "T38: nested child must NOT be a removal candidate; got: $reap6_out"
echo "  ✓ both the nesting parent and the nested child are skipped"


echo
echo "=== T43: watchdog ownership guard prevents orphaned-writer state resurrection (#312) ==="
# Regression for the T30 loop-smoke flake. An orphaned _watchdog_poll (its
# parent cmd_dispatch was TERM'd mid-`wait`, reparenting the poll to init)
# used to keep calling _patch_status against a loop-status.json that a LATER
# dispatch had already cleared to active_workflow=null. jq's null-path
# autovivification (`.active_workflow.killed_by_watchdog = true` on a null
# node → {active_workflow:{killed_by_watchdog:true}}) resurrected the key,
# so T30's `jq -e '.active_workflow == null'` intermittently failed on CI
# while passing locally (platform-timing-dependent). The fix gates every
# watchdog active_workflow write behind a CAS on active_workflow.issue
# (_wd_owns_active). This test drives that predicate DETERMINISTICALLY via
# the _test-wd-guarded-write hook — no process timing, so the regression
# test is not itself flaky (the exact anti-pattern under repair).
T43_STATE="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/t39-state"
mkdir -p "$T43_STATE"

# Case A — foreign slot (a later dispatch cleared it to null): the guard must
# BLOCK the write; active_workflow stays null (no resurrection).
printf '%s\n' '{"active_workflow":null}' >"$T43_STATE/loop-status.json"
t43_out="$(MAKATO_LOOP_STATE_DIR="$T43_STATE" MAKATO_LOOP_TEST_HOOK=1 \
  "$LOOP" _test-wd-guarded-write 39001 2>/dev/null)"
[[ "$t43_out" == "skipped (foreign)" ]] \
  || fail "T43A: guard should skip a foreign-slot write; got: '$t43_out'"
jq -e '.active_workflow == null' "$T43_STATE/loop-status.json" >/dev/null \
  || fail "T43A: orphaned watchdog resurrected active_workflow; slot: $(cat "$T43_STATE/loop-status.json")"
echo "  ✓ orphaned watchdog (foreign/null slot) did not resurrect active_workflow"

# Case B — the slot is still owned by this issue: the guard is a no-op and the
# legitimate watchdog write proceeds (no regression to the stall/kill audit).
printf '%s\n' '{"active_workflow":{"issue":39002}}' >"$T43_STATE/loop-status.json"
t43_out="$(MAKATO_LOOP_STATE_DIR="$T43_STATE" MAKATO_LOOP_TEST_HOOK=1 \
  "$LOOP" _test-wd-guarded-write 39002 2>/dev/null)"
[[ "$t43_out" == "wrote (owns)" ]] \
  || fail "T43B: guard should permit an owned write; got: '$t43_out'"
jq -e '.active_workflow.killed_by_watchdog == true' "$T43_STATE/loop-status.json" >/dev/null \
  || fail "T43B: owned write did not land; slot: $(cat "$T43_STATE/loop-status.json")"
echo "  ✓ ownership guard permits writes when the slot is still owned"

echo
echo "=== T44: stale-crash reap — dead owner pid + age=0 (bypass) → reaped ==="
# REAP_STALE_AGE=0 bypasses the age gate so we can exercise the pid-dead
# path without waiting 24h.  Worktree has no merged PR and its branch is
# NOT an ancestor of main (it has its own commit on top).
REAP7_ROOT="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/reap7-repo"
REAP7_STATE="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/reap7-state"
mkdir -p "$REAP7_ROOT" "$REAP7_STATE"
(
  cd "$REAP7_ROOT"
  git init -q -b main
  git config user.email t@t.t; git config user.name t
  git commit -q --allow-empty -m init
  git worktree add -q -b feat/crashed "$REAP7_ROOT/.claude/worktrees/crashed-wt" 2>/dev/null
  git -C "$REAP7_ROOT/.claude/worktrees/crashed-wt" commit -q --allow-empty -m "wip"
  # Simulate a dead owner pid (999999999 is virtually guaranteed dead on any OS).
  echo "999999999" >"$REAP7_ROOT/.claude/worktrees/crashed-wt/.loop-owner.pid"
)
# Live-pid worktree: owner pid = $$ (this shell is alive).
(
  cd "$REAP7_ROOT"
  git worktree add -q -b feat/live "$REAP7_ROOT/.claude/worktrees/live-wt" 2>/dev/null
  git -C "$REAP7_ROOT/.claude/worktrees/live-wt" commit -q --allow-empty -m "wip live"
  echo "$$" >"$REAP7_ROOT/.claude/worktrees/live-wt/.loop-owner.pid"
)
REAP7_GH="$REAP7_STATE/reap7-gh.json"
echo '{}' >"$REAP7_GH"  # no merged PRs
reap7_dry="$(
  cd "$REAP7_ROOT" &&
  MAKATO_LOOP_STATE_DIR="$REAP7_STATE" \
  MAKATO_LOOP_REAP_INTERVAL=0 \
  MAKATO_LOOP_REAP_DRYRUN=1 \
  MAKATO_LOOP_REAP_GH_OVERRIDE="$REAP7_GH" \
  MAKATO_LOOP_REAP_BASE_REF="main" \
  MAKATO_LOOP_REAP_REPO="macatocz/makato" \
  MAKATO_LOOP_REAP_STALE_AGE=0 \
    "$LOOP" remove-worktrees 2>&1
)" || fail "T44: remove-worktrees dry-run should exit 0; got: $reap7_dry"
grep -q "would remove .*/crashed-wt (stale-crashed worktree" <<<"$reap7_dry" \
  || fail "T44: crashed-wt (dead pid) must be a removal candidate; got: $reap7_dry"
grep -q "reap skip .*/live-wt (branch feat/live not landed; owner pid alive" <<<"$reap7_dry" \
  || fail "T44: live-wt (live pid) must be skipped; got: $reap7_dry"
echo "  \xe2\x9c\x93 dead-pid worktree reaped; live-pid worktree survives"

echo
echo "=== T45: stale-crash reap — age gate blocks young worktree ==="
# Same dead-pid setup but REAP_STALE_AGE=86400 (default): worktree is
# seconds old so it must be skipped.
reap7_age_dry="$(
  cd "$REAP7_ROOT" &&
  MAKATO_LOOP_STATE_DIR="$REAP7_STATE" \
  MAKATO_LOOP_REAP_INTERVAL=0 \
  MAKATO_LOOP_REAP_DRYRUN=1 \
  MAKATO_LOOP_REAP_GH_OVERRIDE="$REAP7_GH" \
  MAKATO_LOOP_REAP_BASE_REF="main" \
  MAKATO_LOOP_REAP_REPO="macatocz/makato" \
  MAKATO_LOOP_REAP_STALE_AGE=86400 \
    "$LOOP" remove-worktrees 2>&1
)" || fail "T45: remove-worktrees dry-run should exit 0 (age gate); got: $reap7_age_dry"
grep -q "reap skip .*/crashed-wt (branch feat/crashed not landed; worktree too young" <<<"$reap7_age_dry" \
  || fail "T45: young worktree must be skipped by age gate; got: $reap7_age_dry"
echo "  \xe2\x9c\x93 age gate blocks reaping of a recently-created dead-pid worktree"

echo
echo "=== T46: stale-crash reap — unpushed commits block without FORCE ==="
# Set upstream of feat/crashed to main so the unpushed-commits check fires.
(
  cd "$REAP7_ROOT"
  git -C "$REAP7_ROOT/.claude/worktrees/crashed-wt" branch --set-upstream-to=main feat/crashed 2>/dev/null || true
)
reap7_unpushed_dry="$(
  cd "$REAP7_ROOT" &&
  MAKATO_LOOP_STATE_DIR="$REAP7_STATE" \
  MAKATO_LOOP_REAP_INTERVAL=0 \
  MAKATO_LOOP_REAP_DRYRUN=1 \
  MAKATO_LOOP_REAP_GH_OVERRIDE="$REAP7_GH" \
  MAKATO_LOOP_REAP_BASE_REF="main" \
  MAKATO_LOOP_REAP_REPO="macatocz/makato" \
  MAKATO_LOOP_REAP_STALE_AGE=0 \
    "$LOOP" remove-worktrees 2>&1
)" || fail "T46: remove-worktrees dry-run should exit 0 (unpushed); got: $reap7_unpushed_dry"
grep -q "reap skip .*/crashed-wt (branch feat/crashed not landed; unpushed commits" <<<"$reap7_unpushed_dry" \
  || fail "T46: worktree with unpushed commits must be skipped without FORCE; got: $reap7_unpushed_dry"
echo "  \xe2\x9c\x93 unpushed commits block stale reap without REAP_STALE_FORCE=1"

echo
echo "=== T47: stale-crash reap — REAP_STALE_FORCE=1 overrides unpushed block ==="
reap7_force_dry="$(
  cd "$REAP7_ROOT" &&
  MAKATO_LOOP_STATE_DIR="$REAP7_STATE" \
  MAKATO_LOOP_REAP_INTERVAL=0 \
  MAKATO_LOOP_REAP_DRYRUN=1 \
  MAKATO_LOOP_REAP_GH_OVERRIDE="$REAP7_GH" \
  MAKATO_LOOP_REAP_BASE_REF="main" \
  MAKATO_LOOP_REAP_REPO="macatocz/makato" \
  MAKATO_LOOP_REAP_STALE_AGE=0 \
  MAKATO_LOOP_REAP_STALE_FORCE=1 \
    "$LOOP" remove-worktrees 2>&1
)" || fail "T47: remove-worktrees dry-run should exit 0 (force); got: $reap7_force_dry"
grep -q "would remove .*/crashed-wt (stale-crashed worktree" <<<"$reap7_force_dry" \
  || fail "T47: REAP_STALE_FORCE=1 must allow reap despite unpushed commits; got: $reap7_force_dry"
echo "  \xe2\x9c\x93 REAP_STALE_FORCE=1 overrides unpushed-commits block"

echo
echo "=== T48: stale-crash live removal — crashed-wt gone, live-wt survives ==="
# Remove the upstream so the unpushed-commits check is bypassed.
(
  cd "$REAP7_ROOT"
  git -C "$REAP7_ROOT/.claude/worktrees/crashed-wt" branch --unset-upstream 2>/dev/null || true
)
reap7_live="$(
  cd "$REAP7_ROOT" &&
  MAKATO_LOOP_STATE_DIR="$REAP7_STATE" \
  MAKATO_LOOP_REAP_INTERVAL=0 \
  MAKATO_LOOP_REAP_GH_OVERRIDE="$REAP7_GH" \
  MAKATO_LOOP_REAP_BASE_REF="main" \
  MAKATO_LOOP_REAP_REPO="macatocz/makato" \
  MAKATO_LOOP_REAP_STALE_AGE=0 \
    "$LOOP" remove-worktrees 2>&1
)" || fail "T48: remove-worktrees (live) should exit 0; got: $reap7_live"
reap7_list="$(cd "$REAP7_ROOT" && git worktree list --porcelain)"
grep -q "/crashed-wt$" <<<"$reap7_list" \
  && fail "T48: crashed-wt must have been removed; still registered"
grep -q "/live-wt$" <<<"$reap7_list" \
  || fail "T48: live-wt must survive (owner pid alive); got removed"
jq -e '.last_reap_count >= 1' "$REAP7_STATE/loop-status.json" >/dev/null \
  || fail "T48: last_reap_count should be >= 1; got $(jq -r .last_reap_count "$REAP7_STATE/loop-status.json")"
echo "  \xe2\x9c\x93 crashed-wt removed; live-wt survives; audit count correct"
echo

echo
echo "=== T49: gate tier-1 merged-PR skip ==="
rm -f "$STATE_DIR/loop-status.json"
T49_REAP="$STATE_DIR/t49-reap-$$.json"
T49_LABELS="$STATE_DIR/t49-labels-$$.json"
T49_BODY="$STATE_DIR/t49-body-$$.txt"
# Issue 101 + body → key=gate-test-key → branch=feat/101-gate-test-key
printf '%s\n' '*Feature slug: `gate-test-key` — produced by to-issues v3.x.*' >"$T49_BODY"
printf '{"feat/101-gate-test-key": "999"}' >"$T49_REAP"
printf '{"labels":[],"title":"Issue 101"}' >"$T49_LABELS"
MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$T49_BODY" \
  MAKATO_LOOP_REAP_GH_OVERRIDE="$T49_REAP" \
  MAKATO_LOOP_GATE_LABELS_OVERRIDE="$T49_LABELS" \
  MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:feature" \
  MAKATO_LOOP_CLAIM_ON_DISPATCH=0 \
  MAKATO_LOOP_DRY_DISPATCH=1 \
  MAKATO_LOOP_ASSIGN_ON_DISPATCH=0 \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  "$LOOP" dispatch 101 2>/dev/null
t49_skips="$(jq -r '.gate_skips_total // 0' "$STATE_DIR/loop-status.json" 2>/dev/null || echo 0)"
[[ "$t49_skips" -eq 1 ]] \
  || fail "T49: expected gate_skips_total=1 after merged-PR skip; got $t49_skips"
jq -e '.active_workflow == null' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "T49: active_workflow should be null after gate skip"
echo "  ✓ tier-1 merged-PR: gate skip increments counter, clears active_workflow"
rm -f "$T49_REAP" "$T49_LABELS" "$T49_BODY"

# ---------------------------------------------------------------------------
echo "=== T50: GATE_DISABLE=1 bypasses gate — merged-PR proceeds ==="
rm -f "$STATE_DIR/loop-status.json"
T50_REAP="$STATE_DIR/t50-reap-$$.json"
T50_BODY="$STATE_DIR/t50-body-$$.txt"
printf '%s\n' '*Feature slug: `gate-test-key` — produced by to-issues v3.x.*' >"$T50_BODY"
printf '{"feat/101-gate-test-key": "999"}' >"$T50_REAP"
MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$T50_BODY" \
  MAKATO_LOOP_REAP_GH_OVERRIDE="$T50_REAP" \
  MAKATO_LOOP_GATE_DISABLE=1 \
  MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:feature" \
  MAKATO_LOOP_CLAIM_ON_DISPATCH=0 \
  MAKATO_LOOP_DRY_DISPATCH=1 \
  MAKATO_LOOP_ASSIGN_ON_DISPATCH=0 \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  "$LOOP" dispatch 101 2>/dev/null
t50_skips="$(jq -r '.gate_skips_total // 0' "$STATE_DIR/loop-status.json" 2>/dev/null || echo 0)"
[[ "$t50_skips" -eq 0 ]] \
  || fail "T50: GATE_DISABLE=1: gate_skips_total should be 0; got $t50_skips"
jq -e '.last_dispatch_issue == 101' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "T50: GATE_DISABLE=1 should allow dispatch (last_dispatch_issue=101)"
echo "  ✓ GATE_DISABLE=1: merged-PR fixture, dispatch proceeds, counter unchanged"
rm -f "$T50_REAP" "$T50_BODY"

# ---------------------------------------------------------------------------
echo "=== T51: exclusion-label veto ==="
rm -f "$STATE_DIR/loop-status.json"
T51_REAP="$STATE_DIR/t51-reap-$$.json"
T51_LABELS="$STATE_DIR/t51-labels-$$.json"
T51_BODY="$STATE_DIR/t51-body-$$.txt"
printf '%s\n' '*Feature slug: `gate-test-key` — produced by to-issues v3.x.*' >"$T51_BODY"
printf '{}' >"$T51_REAP"
printf '{"labels":[{"name":"status:blocked"}],"title":"Issue 101"}' >"$T51_LABELS"
MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$T51_BODY" \
  MAKATO_LOOP_REAP_GH_OVERRIDE="$T51_REAP" \
  MAKATO_LOOP_GATE_LABELS_OVERRIDE="$T51_LABELS" \
  MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:feature" \
  MAKATO_LOOP_CLAIM_ON_DISPATCH=0 \
  MAKATO_LOOP_DRY_DISPATCH=1 \
  MAKATO_LOOP_ASSIGN_ON_DISPATCH=0 \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  "$LOOP" dispatch 101 2>/dev/null
t51_skips="$(jq -r '.gate_skips_total // 0' "$STATE_DIR/loop-status.json" 2>/dev/null || echo 0)"
[[ "$t51_skips" -eq 1 ]] \
  || fail "T51: exclusion label: gate_skips_total should be 1; got $t51_skips"
jq -e '.active_workflow == null' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "T51: active_workflow should be null after exclusion-label veto"
echo "  ✓ exclusion-label 'status:blocked': veto skip, counter +1, no dispatch"
rm -f "$T51_LABELS" "$T51_REAP" "$T51_BODY"

# ---------------------------------------------------------------------------
echo "=== T52: in-flight workflow-state skip (tier 2) ==="
rm -f "$STATE_DIR/loop-status.json"
T52_REAP="$STATE_DIR/t52-reap-$$.json"
T52_LABELS="$STATE_DIR/t52-labels-$$.json"
T52_BODY="$STATE_DIR/t52-body-$$.txt"
T52_SPEC="$REPO_ROOT/specs/gap-007-loop-smoke-gate-t52-$$"
mkdir -p "$T52_SPEC"
printf '{"issue_number": 101, "current_phase": "implement"}' \
  >"$T52_SPEC/workflow-state-101.json"
printf '%s\n' '*Feature slug: `gate-test-key` — produced by to-issues v3.x.*' >"$T52_BODY"
printf '{}' >"$T52_REAP"
printf '{"labels":[],"title":"Issue 101"}' >"$T52_LABELS"
MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$T52_BODY" \
  MAKATO_LOOP_REAP_GH_OVERRIDE="$T52_REAP" \
  MAKATO_LOOP_GATE_LABELS_OVERRIDE="$T52_LABELS" \
  MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:feature" \
  MAKATO_LOOP_CLAIM_ON_DISPATCH=0 \
  MAKATO_LOOP_DRY_DISPATCH=1 \
  MAKATO_LOOP_ASSIGN_ON_DISPATCH=0 \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  "$LOOP" dispatch 101 2>/dev/null
t52_skips="$(jq -r '.gate_skips_total // 0' "$STATE_DIR/loop-status.json" 2>/dev/null || echo 0)"
[[ "$t52_skips" -eq 1 ]] \
  || fail "T52: in-flight: gate_skips_total should be 1; got $t52_skips"
jq -e '.active_workflow == null' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "T52: active_workflow should be null after in-flight skip"
rm -rf "$T52_SPEC"
echo "  ✓ in-flight workflow-state: tier-2 skip, counter +1, no dispatch"
rm -f "$T52_REAP" "$T52_LABELS" "$T52_BODY"

# ---------------------------------------------------------------------------
echo "=== T53: read failure degrades gracefully (best-effort proceed) ==="
rm -f "$STATE_DIR/loop-status.json"
T53_BODY="$STATE_DIR/t53-body-$$.txt"
printf '%s\n' '*Feature slug: `gate-test-key` — produced by to-issues v3.x.*' >"$T53_BODY"
MAKATO_LOOP_ISSUE_BODY_OVERRIDE="$T53_BODY" \
  MAKATO_LOOP_REAP_GH_OVERRIDE="/tmp/t53-nonexistent-reap-fixture-$$.json" \
  MAKATO_LOOP_GATE_LABELS_OVERRIDE="/tmp/t53-nonexistent-labels-fixture-$$.json" \
  MAKATO_LOOP_ISSUE_TYPE_OVERRIDE="type:feature" \
  MAKATO_LOOP_CLAIM_ON_DISPATCH=0 \
  MAKATO_LOOP_DRY_DISPATCH=1 \
  MAKATO_LOOP_ASSIGN_ON_DISPATCH=0 \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  "$LOOP" dispatch 101 2>/dev/null
t53_skips="$(jq -r '.gate_skips_total // 0' "$STATE_DIR/loop-status.json" 2>/dev/null || echo 0)"
[[ "$t53_skips" -eq 0 ]] \
  || fail "T53: read failure: gate_skips_total should be 0 (degraded proceed); got $t53_skips"
jq -e '.last_dispatch_issue == 101' "$STATE_DIR/loop-status.json" >/dev/null \
  || fail "T53: read failure: dispatch should proceed (last_dispatch_issue=101)"
echo "  ✓ read failure: WARN + proceed, counter unchanged, dispatch not blocked"
rm -f "$T53_BODY"



# ---------------------------------------------------------------------------
echo "=== T54: unprepared issue (no ready label, no exclusion) → in candidates ==="
T54_FIXTURE="$STATE_DIR/t54-autoseed-$$.json"
cat >"$T54_FIXTURE" <<'EOF'
[
  {"number": 201, "labels": [{"name": "type:feature"}, {"name": "plan-tier:light"}], "author": {"login": "user1"}},
  {"number": 202, "labels": [{"name": "status:ready-for-dev"}], "author": {"login": "user2"}}
]
EOF
t54_out="$(MAKATO_LOOP_TEST_HOOK=1 \
  MAKATO_LOOP_AUTOSEED_OVERRIDE="$T54_FIXTURE" \
  "$LOOP" _test-auto-seed-candidates 2>/dev/null)"
echo "$t54_out" | jq -e '[.[] | select(.number == 201)] | length == 1' >/dev/null \
  || fail "T54: issue 201 (unprepared) should appear in candidates; got: $t54_out"
echo "$t54_out" | jq -e '[.[] | select(.number == 202)] | length == 0' >/dev/null \
  || fail "T54: issue 202 (ready) should NOT appear in candidates; got: $t54_out"
echo "$t54_out" | jq -e '[.[] | select(.number == 201)] | .[0].plan_tier == "light"' >/dev/null \
  || fail "T54: issue 201 should have plan_tier=light; got: $t54_out"
rm -f "$T54_FIXTURE"
echo "  ✓ unprepared issue appears in candidates with plan-tier classified; ready issue excluded"

# ---------------------------------------------------------------------------
echo "=== T55: ready issue (status:ready-for-dev) → NOT in candidates ==="
T55_FIXTURE="$STATE_DIR/t55-autoseed-$$.json"
cat >"$T55_FIXTURE" <<'EOF'
[
  {"number": 203, "labels": [{"name": "status:ready-for-dev"}, {"name": "plan-tier:full"}], "author": {"login": "user3"}}
]
EOF
t55_out="$(MAKATO_LOOP_TEST_HOOK=1 \
  MAKATO_LOOP_AUTOSEED_OVERRIDE="$T55_FIXTURE" \
  "$LOOP" _test-auto-seed-candidates 2>/dev/null)"
echo "$t55_out" | jq -e '. | length == 0' >/dev/null \
  || fail "T55: ready issue should produce empty candidates; got: $t55_out"
rm -f "$T55_FIXTURE"
echo "  ✓ status:ready-for-dev issue filtered out (empty candidates)"

# ---------------------------------------------------------------------------
echo "=== T56: exclusion-label veto (status:blocked) → excluded from candidates ==="
T56_FIXTURE="$STATE_DIR/t56-autoseed-$$.json"
cat >"$T56_FIXTURE" <<'EOF'
[
  {"number": 204, "labels": [{"name": "type:feature"}, {"name": "status:blocked"}], "author": {"login": "user4"}},
  {"number": 205, "labels": [{"name": "type:feature"}, {"name": "plan-tier:light"}], "author": {"login": "user5"}}
]
EOF
t56_out="$(MAKATO_LOOP_TEST_HOOK=1 \
  MAKATO_LOOP_AUTOSEED_OVERRIDE="$T56_FIXTURE" \
  "$LOOP" _test-auto-seed-candidates 2>/dev/null)"
echo "$t56_out" | jq -e '[.[] | select(.number == 204)] | length == 0' >/dev/null \
  || fail "T56: issue 204 (status:blocked) should be excluded; got: $t56_out"
echo "$t56_out" | jq -e '[.[] | select(.number == 205)] | length == 1' >/dev/null \
  || fail "T56: issue 205 (clean) should remain; got: $t56_out"
rm -f "$T56_FIXTURE"
echo "  ✓ exclusion-label 'status:blocked' vetoes issue 204; issue 205 passes"

# ---------------------------------------------------------------------------
echo "=== T57: dependencies label → excluded from candidates ==="
T57_FIXTURE="$STATE_DIR/t57-autoseed-$$.json"
cat >"$T57_FIXTURE" <<'EOF'
[
  {"number": 206, "labels": [{"name": "dependencies"}, {"name": "type:chore"}], "author": {"login": "dependabot[bot]"}},
  {"number": 207, "labels": [{"name": "type:feature"}], "author": {"login": "user6"}}
]
EOF
t57_out="$(MAKATO_LOOP_TEST_HOOK=1 \
  MAKATO_LOOP_AUTOSEED_OVERRIDE="$T57_FIXTURE" \
  "$LOOP" _test-auto-seed-candidates 2>/dev/null)"
echo "$t57_out" | jq -e '[.[] | select(.number == 206)] | length == 0' >/dev/null \
  || fail "T57: issue 206 (dependencies label) should be excluded; got: $t57_out"
echo "$t57_out" | jq -e '[.[] | select(.number == 207)] | length == 1' >/dev/null \
  || fail "T57: issue 207 (clean) should remain; got: $t57_out"
rm -f "$T57_FIXTURE"
echo "  ✓ 'dependencies' label vetoes issue 206; issue 207 passes"

# ---------------------------------------------------------------------------
echo "=== T58: renovate[bot] author → excluded from candidates ==="
T58_FIXTURE="$STATE_DIR/t58-autoseed-$$.json"
cat >"$T58_FIXTURE" <<'EOF'
[
  {"number": 208, "labels": [{"name": "type:chore"}], "author": {"login": "renovate[bot]"}},
  {"number": 209, "labels": [{"name": "type:feature"}, {"name": "plan-tier:full"}], "author": {"login": "user7"}}
]
EOF
t58_out="$(MAKATO_LOOP_TEST_HOOK=1 \
  MAKATO_LOOP_AUTOSEED_OVERRIDE="$T58_FIXTURE" \
  "$LOOP" _test-auto-seed-candidates 2>/dev/null)"
echo "$t58_out" | jq -e '[.[] | select(.number == 208)] | length == 0' >/dev/null \
  || fail "T58: issue 208 (renovate[bot]) should be excluded; got: $t58_out"
echo "$t58_out" | jq -e '[.[] | select(.number == 209)] | length == 1' >/dev/null \
  || fail "T58: issue 209 (clean) should remain; got: $t58_out"
echo "$t58_out" | jq -e '[.[] | select(.number == 209)] | .[0].plan_tier == "full"' >/dev/null \
  || fail "T58: issue 209 should have plan_tier=full; got: $t58_out"
rm -f "$T58_FIXTURE"
echo "  ✓ renovate[bot] author vetoes issue 208; issue 209 passes with plan_tier=full"


# ---------------------------------------------------------------------------
# T59–T62: _auto_seed_dispatch_light (#370, epic #367 S2)
# ---------------------------------------------------------------------------

# T59: plan-tier:light candidate triggers a seed-issue dispatch.
echo "=== T59: light candidate dispatches seed-issue via test hook ==="
T59_PROMPT_CAPTURE="$STATE_DIR/t59-prompt-$$.txt"
T59_ENV_CAPTURE="$STATE_DIR/t59-env-$$.txt"
# Stub: capture the prompt (last arg) and env to files, exit 0.
T59_STUB="$(cat <<'STUB'
#!/usr/bin/env bash
# Write the -p prompt to a capture file, write key env vars to another.
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-p" ]]; then
    printf '%s' "$2" >"${T59_PROMPT_CAPTURE}"
    shift 2
  else
    shift
  fi
done
printf 'ISSUE_NUMBER=%s REPO=%s MAKATO_HEADLESS=%s BG_CEILING=%s\n' \
  "${ISSUE_NUMBER:-}" "${REPO:-}" "${MAKATO_HEADLESS:-}" \
  "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-UNSET}" \
  >"${T59_ENV_CAPTURE}"
exit 0
STUB
)"
T59_STUB_FILE="$STATE_DIR/t59-stub-$$.sh"
printf '%s\n' "$T59_STUB" >"$T59_STUB_FILE"
chmod +x "$T59_STUB_FILE"
T59_PROMPT_CAPTURE="$T59_PROMPT_CAPTURE" \
T59_ENV_CAPTURE="$T59_ENV_CAPTURE" \
MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
MAKATO_LOOP_TEST_HOOK=1 \
MAKATO_LOOP_SEED_TEST_CMD="$T59_STUB_FILE" \
  "$LOOP" _test-auto-seed-dispatch-light 301 light 2>/dev/null
# Assert the dispatch prompt contains seed-issue and the issue number.
grep -q "seed-issue" "$T59_PROMPT_CAPTURE" \
  || fail "T59: dispatch prompt should reference seed-issue; got: $(cat "$T59_PROMPT_CAPTURE" 2>/dev/null)"
grep -q "301" "$T59_PROMPT_CAPTURE" \
  || fail "T59: dispatch prompt should contain issue number 301; got: $(cat "$T59_PROMPT_CAPTURE" 2>/dev/null)"
# Assert MAKATO_HEADLESS=1 was exported to the stub.
grep -q "MAKATO_HEADLESS=1" "$T59_ENV_CAPTURE" \
  || fail "T59: MAKATO_HEADLESS=1 should be set; got: $(cat "$T59_ENV_CAPTURE" 2>/dev/null)"
# Assert CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 was exported.
grep -q "BG_CEILING=0" "$T59_ENV_CAPTURE" \
  || fail "T59: CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 should be set; got: $(cat "$T59_ENV_CAPTURE" 2>/dev/null)"
# Assert REPO is threaded into env from MAKATO_LOOP_DISPATCH_REPO.
grep -q "REPO=macatocz/makato" "$T59_ENV_CAPTURE" \
  || fail "T59: REPO should be macatocz/makato; got: $(cat "$T59_ENV_CAPTURE" 2>/dev/null)"
rm -f "$T59_STUB_FILE" "$T59_PROMPT_CAPTURE" "$T59_ENV_CAPTURE"
echo "  ✓ plan-tier:light: seed-issue dispatched with correct prompt and env"

# T60: non-light candidate is skipped, not dispatched.
echo "=== T60: non-light candidate (plan-tier:full) is skipped, no dispatch ==="
T60_DISPATCHED="$STATE_DIR/t60-dispatched-$$"
T60_STUB_FILE="$STATE_DIR/t60-stub-$$.sh"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$T60_DISPATCHED" >"$T60_STUB_FILE"
chmod +x "$T60_STUB_FILE"
t60_stderr="$(
  MAKATO_LOOP_TEST_HOOK=1 \
  MAKATO_LOOP_SEED_TEST_CMD="$T60_STUB_FILE" \
    "$LOOP" _test-auto-seed-dispatch-light 302 full 2>&1 >/dev/null
)"
[[ ! -f "$T60_DISPATCHED" ]] \
  || fail "T60: stub should NOT have been called for plan-tier:full; dispatch file exists"
echo "$t60_stderr" | grep -q "deferred to S4" \
  || fail "T60: skip log should mention 'deferred to S4'; got: $t60_stderr"
rm -f "$T60_STUB_FILE" "$T60_DISPATCHED"
echo "  ✓ non-light (full) candidate: skipped with deferral log, no dispatch"

# T61: stubbed seed-issue failure surfaces WARN and returns non-zero.
echo "=== T61: seed dispatch failure → WARN logged, non-zero return ==="
T61_STUB_FILE="$STATE_DIR/t61-stub-$$.sh"
printf '#!/usr/bin/env bash\nexit 7\n' >"$T61_STUB_FILE"
chmod +x "$T61_STUB_FILE"
t61_rc=0
t61_stderr="$(
  MAKATO_LOOP_TEST_HOOK=1 \
  MAKATO_LOOP_SEED_TEST_CMD="$T61_STUB_FILE" \
    "$LOOP" _test-auto-seed-dispatch-light 303 light 2>&1 >/dev/null
)" || t61_rc=$?
[[ "$t61_rc" -ne 0 ]] \
  || fail "T61: non-zero stub should cause non-zero return from dispatch; got rc=$t61_rc"
echo "$t61_stderr" | grep -q "WARN" \
  || fail "T61: WARN should be logged on dispatch failure; got: $t61_stderr"
echo "$t61_stderr" | grep -q "303" \
  || fail "T61: WARN log should name the issue number; got: $t61_stderr"
rm -f "$T61_STUB_FILE"
echo "  ✓ seed failure: WARN logged, non-zero return, no abort"

# T62: MAKATO_LOOP_DISPATCH_REPO is threaded into dispatch prompt env.
echo "=== T62: MAKATO_LOOP_DISPATCH_REPO is threaded into prompt env ==="
T62_ENV_CAPTURE="$STATE_DIR/t62-env-$$.txt"
T62_STUB_FILE="$STATE_DIR/t62-stub-$$.sh"
cat >"$T62_STUB_FILE" <<STUB
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "-p" ]]; then
    shift 2
  else
    shift
  fi
done
printf 'REPO=%s\n' "\${REPO:-}" >"${T62_ENV_CAPTURE}"
exit 0
STUB
chmod +x "$T62_STUB_FILE"
MAKATO_LOOP_DISPATCH_REPO="owner/other-repo" \
MAKATO_LOOP_TEST_HOOK=1 \
MAKATO_LOOP_SEED_TEST_CMD="$T62_STUB_FILE" \
  "$LOOP" _test-auto-seed-dispatch-light 304 light 2>/dev/null
grep -q "REPO=owner/other-repo" "$T62_ENV_CAPTURE" \
  || fail "T62: MAKATO_LOOP_DISPATCH_REPO should be threaded into REPO env; got: $(cat "$T62_ENV_CAPTURE" 2>/dev/null)"
rm -f "$T62_STUB_FILE" "$T62_ENV_CAPTURE"
echo "  ✓ MAKATO_LOOP_DISPATCH_REPO threaded into dispatch env as REPO"



# ---------------------------------------------------------------------------
# T63–T67: _auto_seed_block_full (#372, epic #367 S4)
# ---------------------------------------------------------------------------

# T63: plan-tier:full candidate → spec-stub created, board → Blocked, label applied, comment posted.
echo "=== T63: full-tier candidate → spec-stub, Blocked, needs-human-review, launch comment ==="
T63_STATE="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/t63-state"
T63_CONFIG="$STATE_DIR/t63-config-$$.json"
T63_BLOCK_FILE="$STATE_DIR/t63-block-$$.txt"
T63_COMMENT_FILE="$STATE_DIR/t63-comment-$$.txt"
T63_LABEL_FILE="$STATE_DIR/t63-label-$$.txt"
T63_SPEC_ROOT="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/t63-specs"
mkdir -p "$T63_STATE" "$T63_SPEC_ROOT"
# Config with blocked option id.
jq -n '{
  "github_project": {
    "owner":"macatocz","number":4,"host":"github.com",
    "project_node_id":"PVT_test",
    "fields":{"status":{
      "id":"STATUS_FIELD_ID",
      "options":{"blocked":"BLOCKED_OPT_ID","ready":"READY_OPT_ID"}
    }}
  }
}' >"$T63_CONFIG"
t63_stderr="$(
  MAKATO_LOOP_TEST_HOOK=1 \
  MAKATO_LOOP_CONFIG="$T63_CONFIG" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  MAKATO_LOOP_BLOCK_TEST_FILE="$T63_BLOCK_FILE" \
  MAKATO_LOOP_COMMENT_TEST_FILE="$T63_COMMENT_FILE" \
  MAKATO_LOOP_LABEL_TEST_FILE="$T63_LABEL_FILE" \
  MAKATO_LOOP_ISSUE_TITLE_OVERRIDE="Fix: widget not loading" \
  MAKATO_LOOP_AUTOSEED_SPEC_ROOT="$T63_SPEC_ROOT" \
    "$LOOP" _test-auto-seed-block-full 401 full 2>&1 >/dev/null
)"
# Spec stub must exist.
slug="401-fix-widget-not-loading"
[[ -f "$T63_SPEC_ROOT/${slug}/plan.md" ]] \
  || fail "T63: plan.md stub must be created at specs/${slug}/plan.md; got: $t63_stderr"
[[ -f "$T63_SPEC_ROOT/${slug}/seed-manifest.json" ]] \
  || fail "T63: seed-manifest.json must be created; got: $t63_stderr"
# seed-manifest.json must have correct fields.
jq -e '.issue_number == 401' "$T63_SPEC_ROOT/${slug}/seed-manifest.json" >/dev/null \
  || fail "T63: seed-manifest.json issue_number should be 401"
jq -e '.schema_version == "2"' "$T63_SPEC_ROOT/${slug}/seed-manifest.json" >/dev/null \
  || fail "T63: seed-manifest.json schema_version should be 2"
# Board blocked + label applied (via test files).
[[ -f "$T63_BLOCK_FILE" ]] \
  || fail "T63: block test file not written — board Blocked step skipped; got: $t63_stderr"
grep -q "block #401" "$T63_BLOCK_FILE" \
  || fail "T63: block file should record 'block #401'; got: $(cat "$T63_BLOCK_FILE")"
[[ -f "$T63_LABEL_FILE" ]] \
  || fail "T63: label test file not written — needs-human-review step skipped; got: $t63_stderr"
grep -q "label #401 needs-human-review" "$T63_LABEL_FILE" \
  || fail "T63: label file should record 'label #401 needs-human-review'; got: $(cat "$T63_LABEL_FILE")"
# Launch comment posted (via test file).
[[ -f "$T63_COMMENT_FILE" ]] \
  || fail "T63: comment test file not written — comment step skipped; got: $t63_stderr"
grep -q "comment #401" "$T63_COMMENT_FILE" \
  || fail "T63: comment file should record 'comment #401'; got: $(cat "$T63_COMMENT_FILE")"
grep -q "make seed-issue" "$T63_COMMENT_FILE" || grep -q "seed-issue" "$T63_COMMENT_FILE" \
  || fail "T63: comment should include 'seed-issue' launch command; got: $(cat "$T63_COMMENT_FILE")"
grep -q "<!-- makato:auto-seed-block:full -->" "$T63_COMMENT_FILE" \
  || fail "T63: comment should include sentinel; got: $(cat "$T63_COMMENT_FILE")"
rm -f "$T63_CONFIG" "$T63_BLOCK_FILE" "$T63_COMMENT_FILE" "$T63_LABEL_FILE"
echo "  ✓ full-tier: spec-stub created, Blocked, needs-human-review applied, launch comment posted"

# T64: untiered (empty plan_tier) candidate → identical to full-tier.
echo "=== T64: untiered (empty plan_tier) candidate → same as full-tier ==="
T64_BLOCK_FILE="$STATE_DIR/t64-block-$$.txt"
T64_COMMENT_FILE="$STATE_DIR/t64-comment-$$.txt"
T64_LABEL_FILE="$STATE_DIR/t64-label-$$.txt"
T64_CONFIG="$STATE_DIR/t64-config-$$.json"
T64_SPEC_ROOT="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/t64-specs"
mkdir -p "$T64_SPEC_ROOT"
jq -n '{
  "github_project": {
    "owner":"macatocz","number":4,"host":"github.com",
    "project_node_id":"PVT_test",
    "fields":{"status":{
      "id":"STATUS_FIELD_ID",
      "options":{"blocked":"BLOCKED_OPT_ID","ready":"READY_OPT_ID"}
    }}
  }
}' >"$T64_CONFIG"
t64_stderr="$(
  MAKATO_LOOP_TEST_HOOK=1 \
  MAKATO_LOOP_CONFIG="$T64_CONFIG" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  MAKATO_LOOP_BLOCK_TEST_FILE="$T64_BLOCK_FILE" \
  MAKATO_LOOP_COMMENT_TEST_FILE="$T64_COMMENT_FILE" \
  MAKATO_LOOP_LABEL_TEST_FILE="$T64_LABEL_FILE" \
  MAKATO_LOOP_ISSUE_TITLE_OVERRIDE="New feature request" \
  MAKATO_LOOP_AUTOSEED_SPEC_ROOT="$T64_SPEC_ROOT" \
    "$LOOP" _test-auto-seed-block-full 402 "" 2>&1 >/dev/null
)"
# Untiered must behave identically to full.
[[ -f "$T64_BLOCK_FILE" ]] \
  || fail "T64: untiered should act like full → board Blocked; got: $t64_stderr"
grep -q "block #402" "$T64_BLOCK_FILE" \
  || fail "T64: block file should record 'block #402'; got: $(cat "$T64_BLOCK_FILE")"
[[ -f "$T64_COMMENT_FILE" ]] \
  || fail "T64: untiered should post comment; got: $t64_stderr"
rm -f "$T64_CONFIG" "$T64_BLOCK_FILE" "$T64_COMMENT_FILE" "$T64_LABEL_FILE"
echo "  ✓ untiered candidate treated identically to full-tier"

# T65: already-blocked + sentinel present → no duplicate comment, no duplicate label.
echo "=== T65: sentinel already present → no duplicate comment ==="
T65_BLOCK_FILE="$STATE_DIR/t65-block-$$.txt"
T65_COMMENT_FILE="$STATE_DIR/t65-comment-$$.txt"
T65_LABEL_FILE="$STATE_DIR/t65-label-$$.txt"
T65_CONFIG="$STATE_DIR/t65-config-$$.json"
T65_SPEC_ROOT="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/t65-specs"
mkdir -p "$T65_SPEC_ROOT"
jq -n '{
  "github_project": {
    "owner":"macatocz","number":4,"host":"github.com",
    "project_node_id":"PVT_test",
    "fields":{"status":{
      "id":"STATUS_FIELD_ID",
      "options":{"blocked":"BLOCKED_OPT_ID","ready":"READY_OPT_ID"}
    }}
  }
}' >"$T65_CONFIG"
# Pre-seed a comments override file containing the sentinel so the function
# detects it and skips posting.
T65_COMMENTS_OVERRIDE="$STATE_DIR/t65-comments-$$.json"
jq -n '[{"body": "<!-- makato:auto-seed-block:full -->\nThis issue needs a full plan.\n"}]' \
  >"$T65_COMMENTS_OVERRIDE"
t65_stderr="$(
  MAKATO_LOOP_TEST_HOOK=1 \
  MAKATO_LOOP_CONFIG="$T65_CONFIG" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  MAKATO_LOOP_BLOCK_TEST_FILE="$T65_BLOCK_FILE" \
  MAKATO_LOOP_COMMENT_TEST_FILE="$T65_COMMENT_FILE" \
  MAKATO_LOOP_LABEL_TEST_FILE="$T65_LABEL_FILE" \
  MAKATO_LOOP_ISSUE_TITLE_OVERRIDE="Dedup test" \
  MAKATO_LOOP_AUTOSEED_SPEC_ROOT="$T65_SPEC_ROOT" \
  MAKATO_LOOP_COMMENTS_OVERRIDE="$T65_COMMENTS_OVERRIDE" \
    "$LOOP" _test-auto-seed-block-full 403 full 2>&1 >/dev/null
)"
# Block is still applied (idempotent) but comment must NOT be posted again.
[[ ! -f "$T65_COMMENT_FILE" ]] \
  || [[ ! -s "$T65_COMMENT_FILE" ]] \
  || fail "T65: sentinel already present — must NOT post duplicate comment; got: $(cat "$T65_COMMENT_FILE" 2>/dev/null)"
echo "$t65_stderr" | grep -q "sentinel" \
  || fail "T65: should log that sentinel was detected; got: $t65_stderr"
rm -f "$T65_CONFIG" "$T65_BLOCK_FILE" "$T65_COMMENT_FILE" "$T65_LABEL_FILE" "$T65_COMMENTS_OVERRIDE"
echo "  ✓ sentinel detected → no duplicate comment"

# T66: plan-tier:light candidate → no-op (S2 owns it, S4 must not block).
echo "=== T66: plan-tier:light candidate → no-op (S4 skips light tier) ==="
T66_BLOCK_FILE="$STATE_DIR/t66-block-$$.txt"
T66_COMMENT_FILE="$STATE_DIR/t66-comment-$$.txt"
T66_LABEL_FILE="$STATE_DIR/t66-label-$$.txt"
t66_stderr="$(
  MAKATO_LOOP_TEST_HOOK=1 \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  MAKATO_LOOP_BLOCK_TEST_FILE="$T66_BLOCK_FILE" \
  MAKATO_LOOP_COMMENT_TEST_FILE="$T66_COMMENT_FILE" \
  MAKATO_LOOP_LABEL_TEST_FILE="$T66_LABEL_FILE" \
    "$LOOP" _test-auto-seed-block-full 404 light 2>&1 >/dev/null
)"
[[ ! -f "$T66_BLOCK_FILE" ]] || [[ ! -s "$T66_BLOCK_FILE" ]] \
  || fail "T66: light-tier candidate must not trigger board Blocked; got: $(cat "$T66_BLOCK_FILE" 2>/dev/null)"
[[ ! -f "$T66_COMMENT_FILE" ]] || [[ ! -s "$T66_COMMENT_FILE" ]] \
  || fail "T66: light-tier candidate must not trigger comment; got: $(cat "$T66_COMMENT_FILE" 2>/dev/null)"
echo "$t66_stderr" | grep -qi "light\|skip" \
  || fail "T66: should log skip/light reason; got: $t66_stderr"
rm -f "$T66_BLOCK_FILE" "$T66_COMMENT_FILE" "$T66_LABEL_FILE"
echo "  ✓ plan-tier:light is a no-op (S2 owns it)"

# T67: spec folder already exists → idempotent skip.
echo "=== T67: spec folder already exists → idempotent skip (no error) ==="
T67_BLOCK_FILE="$STATE_DIR/t67-block-$$.txt"
T67_COMMENT_FILE="$STATE_DIR/t67-comment-$$.txt"
T67_LABEL_FILE="$STATE_DIR/t67-label-$$.txt"
T67_CONFIG="$STATE_DIR/t67-config-$$.json"
T67_SPEC_ROOT="${CLAUDE_JOB_DIR:-/tmp}/loop-smoke-$$/t67-specs"
mkdir -p "$T67_SPEC_ROOT"
jq -n '{
  "github_project": {
    "owner":"macatocz","number":4,"host":"github.com",
    "project_node_id":"PVT_test",
    "fields":{"status":{
      "id":"STATUS_FIELD_ID",
      "options":{"blocked":"BLOCKED_OPT_ID","ready":"READY_OPT_ID"}
    }}
  }
}' >"$T67_CONFIG"
# Pre-create the spec folder so the function sees it exists.
mkdir -p "$T67_SPEC_ROOT/405-already-seeded"
t67_stderr="$(
  MAKATO_LOOP_TEST_HOOK=1 \
  MAKATO_LOOP_CONFIG="$T67_CONFIG" \
  MAKATO_LOOP_DISPATCH_REPO="macatocz/makato" \
  MAKATO_LOOP_BLOCK_TEST_FILE="$T67_BLOCK_FILE" \
  MAKATO_LOOP_COMMENT_TEST_FILE="$T67_COMMENT_FILE" \
  MAKATO_LOOP_LABEL_TEST_FILE="$T67_LABEL_FILE" \
  MAKATO_LOOP_ISSUE_TITLE_OVERRIDE="Already seeded" \
  MAKATO_LOOP_AUTOSEED_SPEC_ROOT="$T67_SPEC_ROOT" \
    "$LOOP" _test-auto-seed-block-full 405 full 2>&1 >/dev/null
)"
# Must still proceed to block/label/comment but NOT error.
[[ $? -eq 0 ]] || fail "T67: function should exit 0 even when spec folder exists; got: $t67_stderr"
echo "$t67_stderr" | grep -qi "already exist\|skip.*folder\|folder.*exist" \
  || fail "T67: should log that folder already exists (idempotent); got: $t67_stderr"
[[ -f "$T67_BLOCK_FILE" ]] \
  || fail "T67: block should still fire even when folder exists; got: $t67_stderr"
rm -f "$T67_CONFIG" "$T67_BLOCK_FILE" "$T67_COMMENT_FILE" "$T67_LABEL_FILE"
echo "  ✓ existing spec folder: idempotent skip, rest of actions still fire"

echo
echo "=== ALL TESTS PASSED (incl. T31–T38 worktree reaper, #265; T39–T42 board-poll rate-limit, #289; T43 watchdog ownership guard, #312; T44–T48 stale-crash reaper, #320; T49–T53 dispatch gate, #318; T54–T58 auto-seed candidates, #369; T59–T62 auto-seed dispatch light, #370; T63–T67 auto-seed block full, #372) ==="
