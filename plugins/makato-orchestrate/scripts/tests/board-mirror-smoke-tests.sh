#!/usr/bin/env bash
# Smoke tests for scripts/board-mirror.sh (issue #9 — offline board mirror + sync).
# Fully offline: no network, gh replaced by a stub for flush scenarios.
#
# Usage:
#   plugins/makato-orchestrate/scripts/tests/board-mirror-smoke-tests.sh
#
# Scenarios:
#   T-MIR-1  refresh + read round-trip preserves board items
#   T-MIR-2  read fails with no mirror, and when MAKATO_LOOP_MIRROR=0 (disabled)
#   T-MIR-3  apply_local enqueues a push AND flips the snapshot item status
#   T-MIR-4  refresh re-applies pending queue (last-writer-wins over fetched board)
#   T-MIR-5  flush pushes via gh, drops pushed entries, keeps failed ones
#   T-MIR-6  flush collapses to latest status per issue (last-writer-wins)
#   T-MIR-7  disabled flag → refresh/apply/flush no-op, read fails

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIRROR_SH="$SCRIPT_DIR/../board-mirror.sh"

PASS=0
FAIL=0
FAILED_TESTS=()
pass() { PASS=$((PASS + 1)); echo "  ok  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); echo "  FAIL $1 — $2"; }

# board-mirror.sh calls _now() (defined in functions.sh at runtime). Provide a
# monotonic stub so last-writer-wins ordering is deterministic across calls.
_NOW_SEQ=0
_now() { _NOW_SEQ=$((_NOW_SEQ + 1)); printf '2026-01-01T00:00:%02d.000Z\n' "$_NOW_SEQ"; }

# shellcheck source=../board-mirror.sh
source "$MIRROR_SH"

# A minimal board fixture: two Ready issues with project item ids.
board_fixture() {
  cat <<'JSON'
{"items":[
  {"id":"ITEM_101","status":"Ready","content":{"type":"Issue","number":101,"repository":"o/r","title":"a","url":"u1"}},
  {"id":"ITEM_102","status":"Ready","content":{"type":"Issue","number":102,"repository":"o/r","title":"b","url":"u2"}}
]}
JSON
}

# Sets up a fresh sandbox and exports the mirror paths + config into THIS shell
# (not a subshell — call as `new_sandbox`, then use $SB, never `$(new_sandbox)`).
new_sandbox() {
  SB="$(mktemp -d)"
  export STATE_DIR="$SB"
  export MAKATO_LOOP_MIRROR_FILE="$SB/board-mirror.json"
  export MAKATO_LOOP_MIRROR_QUEUE="$SB/board-mirror-queue.jsonl"
  export CONFIG_FILE="$SB/config.json"
  unset MAKATO_LOOP_MIRROR
  cat >"$CONFIG_FILE" <<'JSON'
{"github_project":{"project_node_id":"PVT_1","fields":{"status":{"id":"FIELD_1","options":{"ready":"OPT_READY","in_progress":"OPT_INPROG","done":"OPT_DONE"}}}}}
JSON
}

# ---------------------------------------------------------------------------
# T-MIR-1: refresh + read round-trip
# ---------------------------------------------------------------------------
echo "T-MIR-1: refresh + read round-trip preserves board items"
{
  new_sandbox; sb="$SB"
  mirror_refresh "$(board_fixture)"
  got="$(mirror_read)"
  n="$(jq '.items | length' <<<"$got" 2>/dev/null || echo 0)"
  s101="$(jq -r '.items[] | select(.content.number==101) | .status' <<<"$got" 2>/dev/null)"
  if [[ "$n" == "2" && "$s101" == "Ready" ]]; then
    pass "T-MIR-1 round-trip preserved 2 items, #101 Ready"
  else
    fail "T-MIR-1" "expected 2 items and #101 Ready; got n=$n s101=$s101"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# T-MIR-2: read fails with no mirror and when disabled
# ---------------------------------------------------------------------------
echo "T-MIR-2: read fails with no mirror / when disabled"
{
  new_sandbox; sb="$SB"
  if mirror_read >/dev/null 2>&1; then
    fail "T-MIR-2a" "read should fail with no mirror file"
  else
    pass "T-MIR-2a read fails cleanly with no mirror"
  fi
  mirror_refresh "$(board_fixture)"
  MAKATO_LOOP_MIRROR=0
  if mirror_read >/dev/null 2>&1; then
    fail "T-MIR-2b" "read should fail when MAKATO_LOOP_MIRROR=0"
  else
    pass "T-MIR-2b read fails when disabled"
  fi
  unset MAKATO_LOOP_MIRROR
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# T-MIR-3: apply_local enqueues a push and flips the snapshot status
# ---------------------------------------------------------------------------
echo "T-MIR-3: apply_local enqueues push + flips snapshot status"
{
  new_sandbox; sb="$SB"
  mirror_refresh "$(board_fixture)"
  mirror_apply_local 101 "In progress"
  q_lines="$(wc -l <"$MAKATO_LOOP_MIRROR_QUEUE" | tr -d ' ')"
  snap_status="$(jq -r '.items[] | select(.content.number==101) | .status' <(mirror_read))"
  if [[ "$q_lines" == "1" && "$snap_status" == "In progress" ]]; then
    pass "T-MIR-3 queued 1 push and snapshot #101 → In progress"
  else
    fail "T-MIR-3" "expected 1 queue line + snapshot In progress; got q=$q_lines snap=$snap_status"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# T-MIR-4: refresh re-applies pending queue (last-writer-wins)
# ---------------------------------------------------------------------------
echo "T-MIR-4: refresh overlays pending local writes on a fetched Ready board"
{
  new_sandbox; sb="$SB"
  mirror_refresh "$(board_fixture)"
  mirror_apply_local 101 "In progress"     # queue a local write, board still says Ready
  mirror_refresh "$(board_fixture)"        # fetch a board that STILL says Ready for #101
  status="$(jq -r '.items[] | select(.content.number==101) | .status' <(mirror_read))"
  if [[ "$status" == "In progress" ]]; then
    pass "T-MIR-4 pending local write survived refresh (last-writer-wins)"
  else
    fail "T-MIR-4" "expected In progress after refresh overlay; got $status"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# T-MIR-5: flush pushes via gh, drops pushed / keeps failed
# ---------------------------------------------------------------------------
echo "T-MIR-5: flush pushes queued writes, drops on success, keeps on failure"
{
  new_sandbox; sb="$SB"
  # Stub gh: succeed for ITEM_101, fail for ITEM_102.
  stubdir="$sb/bin"; mkdir -p "$stubdir"
  cat >"$stubdir/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"ITEM_102"* ]]; then exit 1; fi
exit 0
STUB
  chmod +x "$stubdir/gh"
  mirror_refresh "$(board_fixture)"
  mirror_apply_local 101 "In progress"
  mirror_apply_local 102 "In progress"
  PATH="$stubdir:$PATH" mirror_flush "github.com" 2>/dev/null
  remaining="$(wc -l <"$MAKATO_LOOP_MIRROR_QUEUE" 2>/dev/null | tr -d ' ' || echo 0)"
  kept="$(jq -r '.issue' "$MAKATO_LOOP_MIRROR_QUEUE" 2>/dev/null | tr '\n' ' ')"
  if [[ "$remaining" == "1" && "$kept" == "102 " ]]; then
    pass "T-MIR-5 pushed #101 (dropped), kept failed #102"
  else
    fail "T-MIR-5" "expected only #102 remaining; got remaining=$remaining kept='$kept'"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# T-MIR-6: flush collapses to latest status per issue (last-writer-wins)
# ---------------------------------------------------------------------------
echo "T-MIR-6: flush pushes only the latest status per issue"
{
  new_sandbox; sb="$SB"
  stubdir="$sb/bin"; mkdir -p "$stubdir"
  # Stub gh: record every --single-select-option-id pushed.
  cat >"$stubdir/gh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in OPT_*) echo "\$a" >>"$sb/pushed.log";; esac
done
exit 0
STUB
  chmod +x "$stubdir/gh"
  mirror_refresh "$(board_fixture)"
  mirror_apply_local 101 "In progress"   # older
  mirror_apply_local 101 "Done"          # newer — should win
  PATH="$stubdir:$PATH" mirror_flush "github.com" 2>/dev/null
  pushed="$(tr '\n' ' ' <"$sb/pushed.log" 2>/dev/null)"
  if [[ "$pushed" == "OPT_DONE " ]]; then
    pass "T-MIR-6 pushed only latest status (Done) for #101"
  else
    fail "T-MIR-6" "expected only OPT_DONE pushed; got '$pushed'"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# T-MIR-7: disabled flag makes every mutation a no-op
# ---------------------------------------------------------------------------
echo "T-MIR-7: MAKATO_LOOP_MIRROR=0 disables all mirror behaviour"
{
  new_sandbox; sb="$SB"
  export MAKATO_LOOP_MIRROR=0
  mirror_refresh "$(board_fixture)"
  mirror_apply_local 101 "In progress"
  no_file=1; [[ -e "$MAKATO_LOOP_MIRROR_FILE" ]] && no_file=0
  no_queue=1; [[ -e "$MAKATO_LOOP_MIRROR_QUEUE" ]] && no_queue=0
  if mirror_read >/dev/null 2>&1; then no_read=0; else no_read=1; fi
  unset MAKATO_LOOP_MIRROR
  if [[ "$no_file" == "1" && "$no_queue" == "1" && "$no_read" == "1" ]]; then
    pass "T-MIR-7 disabled → no files written, read fails"
  else
    fail "T-MIR-7" "expected no writes + read fail; file=$no_file queue=$no_queue read_fail=$no_read"
  fi
  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "All $PASS tests passed."
else
  echo "$PASS passed, $FAIL FAILED: ${FAILED_TESTS[*]}"
  exit 1
fi
