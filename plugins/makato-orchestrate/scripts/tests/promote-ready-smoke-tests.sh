#!/usr/bin/env bash
# Smoke tests for scripts/promote-ready.sh — dependency-aware Ready
# promotion (#268). Run from the makato repo root:
#
#   plugins/makato-orchestrate/scripts/tests/promote-ready-smoke-tests.sh
#
# Scenarios (issue #268 AC):
#   T1: loads the dependency graph from created-issues.json and reports it.
#   T2: computes unblocked issues correctly (all blocked_by = Done) and
#       arranges them into topological waves.
#   T3: an issue whose blocker is NOT Done stays blocked (not recommended).
#   T4: the plan.md collision guard defers a second same-folder candidate.
#   T5: --dry-run makes NO board mutation (edit test file stays empty).
#   T6: forward-only — issues already at Ready/In progress/In review/Done
#       are never re-promoted.
#   T7: live promote (--yes) writes exactly the recommended issues to the
#       edit hook; deferred/blocked issues are not written.
#   T8: stories.json fallback — blockedBy story-sequences translate to
#       issue numbers via githubIssue; a story with no githubIssue warns.
#   T9: off-board issue (no board item) is promotable when unblocked; an
#       off-board issue whose blocker is off-board (not Done) stays blocked.
#   T10: an unfiled stories.json blocker (no githubIssue) keeps the dependent
#        issue BLOCKED — never silently dropped (CRITICAL, #268 verify).
#   T11: a dependency cycle terminates, warns, and promotes neither member.
#   T12: an all-unparseable graph shows "(no issues in graph)", no phantom Wave 0.
#   T13: a no-such-slug run is clean on bash 3.2 (no unbound-variable leak).
#
# Fully offline: the board is injected via MAKATO_PROMOTE_GH_OVERRIDE and
# promotions are captured via MAKATO_PROMOTE_EDIT_TEST_FILE — `gh` is never
# invoked. Mirrors loop-smoke-tests.sh conventions.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PR="$REPO_ROOT/plugins/makato-orchestrate/scripts/promote-ready.sh"

SANDBOX="${CLAUDE_JOB_DIR:-/tmp}/promote-ready-smoke-$$"
SPECS="$SANDBOX/specs"
mkdir -p "$SPECS"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

export MAKATO_PROMOTE_SPECS_DIR="$SPECS"

fail() { echo "  ✗ FAIL: $*" >&2; exit 1; }
pass() { echo "  ✓ $*"; }

# --- fixtures --------------------------------------------------------------
# alpha: #1(done) -> #2(todo) -> #3(todo). #2 unblocked, #3 blocked by #2.
mkdir -p "$SPECS/1-alpha"
cat >"$SPECS/1-alpha/created-issues.json" <<'EOF'
{"schema_version":"1","slug":"alpha","issues":[
 {"issue_number":1,"url":"https://x/1","title":"foundation","labels":[],"blocked_by":[]},
 {"issue_number":2,"url":"https://x/2","title":"api","labels":[],"blocked_by":[1]},
 {"issue_number":3,"url":"https://x/3","title":"ui","labels":[],"blocked_by":[2]}
]}
EOF
# beta: #10 and #11 both unblocked in the SAME folder -> collision.
mkdir -p "$SPECS/9-beta"
cat >"$SPECS/9-beta/created-issues.json" <<'EOF'
{"schema_version":"1","slug":"beta","issues":[
 {"issue_number":10,"url":"https://x/10","title":"beta-a","labels":[],"blocked_by":[]},
 {"issue_number":11,"url":"https://x/11","title":"beta-b","labels":[],"blocked_by":[]}
]}
EOF

BOARD="$SANDBOX/board.json"
cat >"$BOARD" <<'EOF'
{"items":[
 {"id":"it1","content":{"type":"Issue","number":1},"status":"Done"},
 {"id":"it2","content":{"type":"Issue","number":2},"status":"Todo"},
 {"id":"it3","content":{"type":"Issue","number":3},"status":"Todo"},
 {"id":"it10","content":{"type":"Issue","number":10},"status":"Todo"},
 {"id":"it11","content":{"type":"Issue","number":11},"status":"Todo"}
]}
EOF
export MAKATO_PROMOTE_GH_OVERRIDE="$BOARD"

# ---------------------------------------------------------------------------
echo "=== T1: loads dependency graph from created-issues.json ==="
OUT="$("$PR" plan alpha 2>&1)"
grep -q "alpha — 3 issue(s)" <<<"$OUT" || fail "graph not loaded: $OUT"
pass "loaded alpha graph (3 issues)"

# ---------------------------------------------------------------------------
echo "=== T2: unblocked computed + topological waves ==="
OUT="$("$PR" plan alpha 2>&1)"
grep -q "Wave 0:" <<<"$OUT" || fail "no Wave 0 in: $OUT"
grep -q "Wave 2:" <<<"$OUT" || fail "no Wave 2 in: $OUT"
# #2 is unblocked (blocker #1 is Done) -> recommended
grep -qE "#2 — api" <<<"$OUT" || fail "#2 not recommended: $OUT"
pass "unblocked #2 recommended; waves 0..2 present"

# ---------------------------------------------------------------------------
echo "=== T3: issue with non-Done blocker stays blocked ==="
OUT="$("$PR" plan alpha 2>&1)"
grep -q "Still blocked" <<<"$OUT" || fail "no blocked section: $OUT"
grep -qE "#3 — waiting on #2" <<<"$OUT" || fail "#3 not shown blocked by #2: $OUT"
# #3 must NOT appear in the recommend-now list
if grep -qE "^ +#3 — ui" <<<"$OUT"; then fail "#3 wrongly recommended: $OUT"; fi
pass "#3 stays blocked on #2, not recommended"

# ---------------------------------------------------------------------------
echo "=== T4: plan.md collision guard defers same-folder sibling ==="
OUT="$("$PR" plan beta 2>&1)"
grep -qE "#10 — beta-a" <<<"$OUT" || fail "#10 not recommended: $OUT"
grep -q "plan.md collision" <<<"$OUT" || fail "no collision section: $OUT"
grep -qE "#11 \[beta\] — collides with #10" <<<"$OUT" || fail "#11 not deferred: $OUT"
pass "#10 promoted, #11 deferred (same folder)"

# ---------------------------------------------------------------------------
echo "=== T5: --dry-run makes no board mutation ==="
EDITLOG="$SANDBOX/edits-dry.txt"; : >"$EDITLOG"
# MAKATO_PROMOTE_YES=1 bypasses the non-TTY approval guard, so the --dry-run
# early-return is the ONLY gate standing between this call and a non-empty
# edit log. Without --yes the test would pass even if --dry-run were deleted
# (the non-TTY guard also blocks mutation) — a vacuous assertion.
MAKATO_PROMOTE_EDIT_TEST_FILE="$EDITLOG" MAKATO_PROMOTE_YES=1 \
  "$PR" run alpha --dry-run >/dev/null 2>&1
if [[ -s "$EDITLOG" ]]; then fail "--dry-run mutated board: $(cat "$EDITLOG")"; fi
pass "--dry-run wrote no promotions (dry-run gate isolated via --yes)"

# ---------------------------------------------------------------------------
echo "=== T6: forward-only — Ready/In progress not re-promoted ==="
BOARD2="$SANDBOX/board-fwd.json"
cat >"$BOARD2" <<'EOF'
{"items":[
 {"id":"it1","content":{"type":"Issue","number":1},"status":"Done"},
 {"id":"it2","content":{"type":"Issue","number":2},"status":"In progress"},
 {"id":"it3","content":{"type":"Issue","number":3},"status":"Ready"}
]}
EOF
EDITLOG="$SANDBOX/edits-fwd.txt"; : >"$EDITLOG"
MAKATO_PROMOTE_GH_OVERRIDE="$BOARD2" MAKATO_PROMOTE_EDIT_TEST_FILE="$EDITLOG" \
  MAKATO_PROMOTE_YES=1 "$PR" run alpha >/dev/null 2>&1
if [[ -s "$EDITLOG" ]]; then fail "re-promoted an already-progressing issue: $(cat "$EDITLOG")"; fi
OUT="$(MAKATO_PROMOTE_GH_OVERRIDE="$BOARD2" "$PR" plan alpha 2>&1)"
grep -q "Already progressing" <<<"$OUT" || fail "no skipped section: $OUT"
pass "In progress #2 / Ready #3 not re-promoted (forward-only)"

# ---------------------------------------------------------------------------
echo "=== T7: live promote (--yes) writes only recommended issues ==="
EDITLOG="$SANDBOX/edits-live.txt"; : >"$EDITLOG"
MAKATO_PROMOTE_EDIT_TEST_FILE="$EDITLOG" MAKATO_PROMOTE_YES=1 \
  "$PR" run beta >/dev/null 2>&1
grep -qE "^promote #10 beta" "$EDITLOG" || fail "#10 not promoted: $(cat "$EDITLOG")"
if grep -qE "^promote #11 " "$EDITLOG"; then fail "#11 wrongly promoted (collision): $(cat "$EDITLOG")"; fi
n="$(wc -l <"$EDITLOG" | tr -d ' ')"
[[ "$n" -eq 1 ]] || fail "expected exactly 1 promotion, got $n: $(cat "$EDITLOG")"
pass "live promote wrote exactly #10; #11 deferred"

# ---------------------------------------------------------------------------
echo "=== T8: stories.json fallback — sequence->githubIssue translation ==="
mkdir -p "$SPECS/7-gamma"
cat >"$SPECS/7-gamma/stories.json" <<'EOF'
{"version":"2.0","slug":"gamma","stories":[
 {"sequence":1,"summary":"g-foundation","githubIssue":20,"dependencies":{"blockedBy":[]}},
 {"sequence":2,"summary":"g-api","githubIssue":21,"dependencies":{"blockedBy":[1]}},
 {"sequence":3,"summary":"g-nogh","dependencies":{"blockedBy":[2]}}
]}
EOF
BOARD3="$SANDBOX/board-gamma.json"
cat >"$BOARD3" <<'EOF'
{"items":[
 {"id":"g20","content":{"type":"Issue","number":20},"status":"Done"},
 {"id":"g21","content":{"type":"Issue","number":21},"status":"Todo"}
]}
EOF
OUT="$(MAKATO_PROMOTE_GH_OVERRIDE="$BOARD3" "$PR" plan gamma 2>&1)"
# story seq2 (#21) blockedBy seq1 (#20 Done) -> #21 unblocked, recommended
grep -qE "#21 — g-api" <<<"$OUT" || fail "stories.json fallback: #21 not recommended: $OUT"
# story seq3 has no githubIssue -> warned + skipped
grep -q "has no githubIssue" <<<"$OUT" || fail "no warning for missing githubIssue: $OUT"
pass "stories.json blockedBy seq->issue translated; missing githubIssue warned"

# ---------------------------------------------------------------------------
echo "=== T9: off-board issue promotable when unblocked ==="
# beta board with NO items at all -> #10/#11 are off-board, no blockers -> promotable.
BOARD4="$SANDBOX/board-empty.json"
echo '{"items":[]}' >"$BOARD4"
OUT="$(MAKATO_PROMOTE_GH_OVERRIDE="$BOARD4" "$PR" plan beta 2>&1)"
grep -qE "#10 — beta-a" <<<"$OUT" || fail "off-board #10 not promotable: $OUT"
# alpha off-board: #2 blocked by #1 which is off-board (not Done) -> #2 blocked.
OUT="$(MAKATO_PROMOTE_GH_OVERRIDE="$BOARD4" "$PR" plan alpha 2>&1)"
grep -qE "#2 — waiting on #1" <<<"$OUT" || fail "off-board blocker not honored: $OUT"
pass "off-board unblocked promotable; off-board blocker still blocks"

# ---------------------------------------------------------------------------
echo "=== T10: unfiled stories.json blocker keeps dependent BLOCKED (not dropped) ==="
# CRITICAL regression (#268 verify): a blockedBy sequence whose upstream story
# has no githubIssue must NOT be silently dropped — the dependent issue must
# stay blocked, not appear unblocked and get promoted.
mkdir -p "$SPECS/6-delta"
cat >"$SPECS/6-delta/stories.json" <<'EOF'
{"version":"2.0","slug":"delta","stories":[
 {"sequence":1,"summary":"unfiled-upstream","dependencies":{"blockedBy":[]}},
 {"sequence":2,"summary":"dependent","githubIssue":42,"dependencies":{"blockedBy":[1]}}
]}
EOF
BOARD_D="$SANDBOX/board-delta.json"
echo '{"items":[{"id":"d42","content":{"type":"Issue","number":42},"status":"Todo"}]}' >"$BOARD_D"
OUT="$(MAKATO_PROMOTE_GH_OVERRIDE="$BOARD_D" "$PR" plan delta 2>&1)"
grep -qE "#42 — waiting on seq 1" <<<"$OUT" || fail "unfiled blocker dropped, #42 not blocked: $OUT"
if grep -qE "^ +#42 — dependent" <<<"$OUT"; then fail "#42 wrongly recommended despite unfiled blocker: $OUT"; fi
# And it must NOT be promoted on a live run.
EDITLOG="$SANDBOX/edits-delta.txt"; : >"$EDITLOG"
MAKATO_PROMOTE_GH_OVERRIDE="$BOARD_D" MAKATO_PROMOTE_EDIT_TEST_FILE="$EDITLOG" \
  MAKATO_PROMOTE_YES=1 "$PR" run delta >/dev/null 2>&1
if grep -qE "^promote #42 " "$EDITLOG"; then fail "#42 promoted despite unfiled blocker: $(cat "$EDITLOG")"; fi
pass "unfiled stories.json blocker keeps #42 blocked (conservative contract)"

# ---------------------------------------------------------------------------
echo "=== T11: dependency cycle terminates, warns, promotes nothing ==="
mkdir -p "$SPECS/8-cyc"
cat >"$SPECS/8-cyc/created-issues.json" <<'EOF'
{"schema_version":"1","slug":"cyc","issues":[
 {"issue_number":50,"url":"https://x/50","title":"c-a","labels":[],"blocked_by":[51]},
 {"issue_number":51,"url":"https://x/51","title":"c-b","labels":[],"blocked_by":[50]}
]}
EOF
BOARD_C="$SANDBOX/board-cyc.json"
echo '{"items":[]}' >"$BOARD_C"
OUT="$(MAKATO_PROMOTE_GH_OVERRIDE="$BOARD_C" "$PR" plan cyc 2>&1)"
grep -qi "cycle detected" <<<"$OUT" || fail "no cycle warning: $OUT"
# Neither cycle member may be recommended (each blocks the other, neither Done).
if grep -qE "^ +#5[01] — c-" <<<"$OUT"; then fail "cycle member wrongly recommended: $OUT"; fi
pass "cycle terminates, warns, promotes neither member"

# ---------------------------------------------------------------------------
echo "=== T12: empty graph (all files unparseable) shows 'no issues in graph' ==="
mkdir -p "$SPECS/3-corrupt"
printf 'NOT JSON {{{\n' >"$SPECS/3-corrupt/created-issues.json"
OUT="$(MAKATO_PROMOTE_GH_OVERRIDE="$BOARD_C" "$PR" plan corrupt 2>&1)"
grep -q "(no issues in graph)" <<<"$OUT" || fail "empty-graph message not shown: $OUT"
pass "empty graph shows '(no issues in graph)', no phantom Wave 0"

# ---------------------------------------------------------------------------
echo "=== T13: no-such-slug is clean on bash 3.2 (no unbound-variable leak) ==="
# _collect_graph_files must not leak `dirs[@]: unbound variable` under set -u
# on macOS /bin/bash 3.2 when the slug matches no directory.
ERR="$(MAKATO_PROMOTE_GH_OVERRIDE="$BOARD_C" "$PR" plan no-such-slug-xyz 2>&1 >/dev/null || true)"
if grep -q "unbound variable" <<<"$ERR"; then fail "bash-3.2 empty-array leak: $ERR"; fi
grep -q "no created-issues.json or stories.json found" <<<"$ERR" || fail "expected clean no-files message: $ERR"
pass "no-such-slug: clean message, no unbound-variable leak"

# ---------------------------------------------------------------------------
echo "=== T-pjson-valid: plan --json outputs valid JSON with required keys ==="
# Two-issue alpha graph with a blocked_by dependency.
OUT="$("$PR" plan --json alpha 2>/dev/null)"
# Must exit 0 and emit valid JSON to stdout.
echo "$OUT" | jq empty 2>/dev/null || fail "plan --json output is not valid JSON: $OUT"
# Required top-level keys.
for key in ready waves blocked skipped deferred_collision; do
  echo "$OUT" | jq -e "has(\"$key\")" >/dev/null 2>&1 || fail "plan --json missing key '$key': $OUT"
done
# ready must contain the unblocked issue (#2) with at least .issue field.
echo "$OUT" | jq -e '.ready | length >= 1' >/dev/null 2>&1 || fail "plan --json ready[] is empty: $OUT"
echo "$OUT" | jq -e '.ready[] | select(.issue == 2)' >/dev/null 2>&1 || fail "#2 not in ready[]: $OUT"
pass "plan --json: valid JSON with all required keys; #2 in ready[]"

# ---------------------------------------------------------------------------
echo "=== T-pjson-collision: plan --json with slug collision populates deferred_collision ==="
# beta graph: #10 and #11 both unblocked but share the same spec folder.
OUT="$("$PR" plan --json beta 2>/dev/null)"
echo "$OUT" | jq empty 2>/dev/null || fail "plan --json (collision) output not valid JSON: $OUT"
# Lower issue (#10) should be in ready.
echo "$OUT" | jq -e '.ready[] | select(.issue == 10)' >/dev/null 2>&1 || fail "#10 not in ready[]: $OUT"
# Higher issue (#11) should be in deferred_collision (not empty).
echo "$OUT" | jq -e '.deferred_collision | length >= 1' >/dev/null 2>&1 || fail "deferred_collision is empty: $OUT"
echo "$OUT" | jq -e '.deferred_collision[] | select(.issue == 11)' >/dev/null 2>&1 || fail "#11 not in deferred_collision[]: $OUT"
# #11 must NOT appear in ready.
if echo "$OUT" | jq -e '.ready[] | select(.issue == 11)' >/dev/null 2>&1; then
  fail "#11 wrongly appears in ready[] despite collision: $OUT"
fi
pass "plan --json: deferred_collision populated; #10 in ready[], #11 in deferred_collision[]"

# ---------------------------------------------------------------------------
# T-VCR-6 through T-VCR-9: MAKATO_MIN_VCR gate in promote-ready.sh (#585)
#
# REPO_ROOT is derived via `git rev-parse --show-toplevel` inside the
# script. To control the loop-status.json path without patching the real
# state dir we run each sub-test inside a throwaway git repo sandbox so
# the path expands to our fixture root.
# ---------------------------------------------------------------------------

_vcr_sandbox="${CLAUDE_JOB_DIR:-/tmp}/promote-ready-smoke-$$-vcr"
rm -rf "$_vcr_sandbox"; mkdir -p "$_vcr_sandbox"
(
  cd "$_vcr_sandbox"
  git init -q -b main
  git config user.email t@t.t; git config user.name t
  git commit -q --allow-empty -m init
)
# Shared spec dir for the VCR tests — one unblocked issue so ready_count > 0.
_vcr_specs="$_vcr_sandbox/vcr-specs"
mkdir -p "$_vcr_specs/1-vcr-alpha"
cat >"$_vcr_specs/1-vcr-alpha/created-issues.json" <<'CEOF'
{"schema_version":"1","slug":"vcr-alpha","issues":[
  {"issue_number":99,"url":"https://x/99","title":"vcr-target","labels":[],"blocked_by":[]}
]}
CEOF
_vcr_board="$_vcr_sandbox/vcr-board.json"
echo '{"items":[{"id":"v99","content":{"type":"Issue","number":99},"status":"Todo"}]}' >"$_vcr_board"
_vcr_editlog="$_vcr_sandbox/vcr-edits.txt"
_vcr_state_dir="$_vcr_sandbox/.claude/state"
mkdir -p "$_vcr_state_dir"

echo "=== T-VCR-6: MAKATO_MIN_VCR unset → promotion proceeds, no gate check ==="
: >"$_vcr_editlog"
(
  cd "$_vcr_sandbox" &&
  MAKATO_PROMOTE_SPECS_DIR="$_vcr_specs" \
  MAKATO_PROMOTE_GH_OVERRIDE="$_vcr_board" \
  MAKATO_PROMOTE_EDIT_TEST_FILE="$_vcr_editlog" \
  MAKATO_PROMOTE_YES=1 \
  unset MAKATO_MIN_VCR 2>/dev/null; \
  MAKATO_PROMOTE_SPECS_DIR="$_vcr_specs" \
  MAKATO_PROMOTE_GH_OVERRIDE="$_vcr_board" \
  MAKATO_PROMOTE_EDIT_TEST_FILE="$_vcr_editlog" \
  MAKATO_PROMOTE_YES=1 \
    "$PR" run vcr-alpha >/dev/null 2>&1 || true
)
# Gate was not set — promote_one should have been called (entry in editlog).
grep -q "^promote #99 " "$_vcr_editlog" \
  || fail "T-VCR-6: MAKATO_MIN_VCR unset — expected promote #99 in editlog, got: $(cat "$_vcr_editlog")"
pass "MAKATO_MIN_VCR unset — promotion reached promote_one, no gate block"
echo "T-VCR-6 passed"

echo "=== T-VCR-7: MAKATO_MIN_VCR=0.5, rate=0.3 → gate fires, no item-edit, exit 0 ==="
: >"$_vcr_editlog"
echo '{"vcr":{"activated":10,"verified":3,"rate":0.3}}' >"$_vcr_state_dir/loop-status.json"
(
  cd "$_vcr_sandbox" &&
  MAKATO_PROMOTE_SPECS_DIR="$_vcr_specs" \
  MAKATO_PROMOTE_GH_OVERRIDE="$_vcr_board" \
  MAKATO_PROMOTE_EDIT_TEST_FILE="$_vcr_editlog" \
  MAKATO_PROMOTE_YES=1 \
  MAKATO_MIN_VCR=0.5 \
    "$PR" run vcr-alpha >/dev/null 2>&1
) && true   # must exit 0
EXIT7=$?
[[ "$EXIT7" -eq 0 ]] || fail "T-VCR-7: expected exit 0, got $EXIT7"
if grep -q "^promote #99 " "$_vcr_editlog"; then
  fail "T-VCR-7: gate should have blocked promotion but editlog has: $(cat "$_vcr_editlog")"
fi
pass "MAKATO_MIN_VCR=0.5, rate=0.3 — gate fired, no promote_one, exit 0"
echo "T-VCR-7 passed"

echo "=== T-VCR-8: MAKATO_MIN_VCR=0.5, rate=0.5 → gate passes (rate == floor), promotion proceeds ==="
: >"$_vcr_editlog"
echo '{"vcr":{"activated":10,"verified":5,"rate":0.5}}' >"$_vcr_state_dir/loop-status.json"
(
  cd "$_vcr_sandbox" &&
  MAKATO_PROMOTE_SPECS_DIR="$_vcr_specs" \
  MAKATO_PROMOTE_GH_OVERRIDE="$_vcr_board" \
  MAKATO_PROMOTE_EDIT_TEST_FILE="$_vcr_editlog" \
  MAKATO_PROMOTE_YES=1 \
  MAKATO_MIN_VCR=0.5 \
    "$PR" run vcr-alpha >/dev/null 2>&1 || true
)
grep -q "^promote #99 " "$_vcr_editlog" \
  || fail "T-VCR-8: rate==floor should pass gate, expected promote #99, got: $(cat "$_vcr_editlog")"
pass "MAKATO_MIN_VCR=0.5, rate=0.5 — gate passed (floor is inclusive), promotion proceeded"
echo "T-VCR-8 passed"

echo "=== T-VCR-9: MAKATO_MIN_VCR set, loop-status.json absent → rate=0.0, gate fires ==="
: >"$_vcr_editlog"
rm -f "$_vcr_state_dir/loop-status.json"
(
  cd "$_vcr_sandbox" &&
  MAKATO_PROMOTE_SPECS_DIR="$_vcr_specs" \
  MAKATO_PROMOTE_GH_OVERRIDE="$_vcr_board" \
  MAKATO_PROMOTE_EDIT_TEST_FILE="$_vcr_editlog" \
  MAKATO_PROMOTE_YES=1 \
  MAKATO_MIN_VCR=0.5 \
    "$PR" run vcr-alpha >/dev/null 2>&1
) && true   # must exit 0
EXIT9=$?
[[ "$EXIT9" -eq 0 ]] || fail "T-VCR-9: expected exit 0, got $EXIT9"
if grep -q "^promote #99 " "$_vcr_editlog"; then
  fail "T-VCR-9: absent loop-status.json should default rate=0.0 and block, but editlog has: $(cat "$_vcr_editlog")"
fi
pass "MAKATO_MIN_VCR set, loop-status.json absent — treated as rate=0.0, gate fired, no promote"
echo "T-VCR-9 passed"

rm -rf "$_vcr_sandbox"

# ---------------------------------------------------------------------------
echo "=== T-PROMOTE-CLOSED-SKIP: CLOSED issue is never promoted to Ready ==="
# A CLOSED GitHub issue (content.state=CLOSED) with no blockers must land in
# .skipped with status "closed" and must NOT appear in .ready, regardless of
# its board Status value (here: null/off-board, which would normally make it
# PROMOTABLE via the "" path).
CLOSED_SANDBOX="${CLAUDE_JOB_DIR:-/tmp}/promote-ready-smoke-$$-closed"
mkdir -p "$CLOSED_SANDBOX/specs/1-closed-test"

cat >"$CLOSED_SANDBOX/specs/1-closed-test/created-issues.json" <<'EOF'
{"schema_version":"1","slug":"test","issues":[
 {"issue_number":23,"url":"https://x/23","title":"old epic","labels":[],"blocked_by":[]}
]}
EOF

cat >"$CLOSED_SANDBOX/board-closed.json" <<'EOF'
{"items":[
 {"id":"ITEM1","content":{"type":"Issue","number":23,"state":"CLOSED","title":"test","url":"https://x/23"},"status":null}
]}
EOF

OUT="$(MAKATO_PROMOTE_SPECS_DIR="$CLOSED_SANDBOX/specs" \
       MAKATO_PROMOTE_GH_OVERRIDE="$CLOSED_SANDBOX/board-closed.json" \
       "$PR" plan --json test 2>/dev/null)"
echo "$OUT" | jq empty 2>/dev/null || fail "T-PROMOTE-CLOSED-SKIP: output is not valid JSON: $OUT"
echo "$OUT" | jq -e '.ready | length == 0' >/dev/null 2>&1 \
  || fail "T-PROMOTE-CLOSED-SKIP: CLOSED issue #23 appeared in .ready: $OUT"
echo "$OUT" | jq -e '.skipped | length == 1' >/dev/null 2>&1 \
  || fail "T-PROMOTE-CLOSED-SKIP: expected 1 skipped entry, got: $OUT"
echo "$OUT" | jq -e '.skipped[0].status == "closed"' >/dev/null 2>&1 \
  || fail "T-PROMOTE-CLOSED-SKIP: .skipped[0].status != \"closed\": $OUT"
rm -rf "$CLOSED_SANDBOX"
pass "CLOSED issue #23 not promoted; in .skipped with status \"closed\""

echo "=== T-PROMOTE-CLOSED-SKIP-TODO: CLOSED issue with board Status=Todo is never promoted ==="
# Primary repro path from #747: CLOSED issue that has board Status="Todo"
# (not merely off-board). The CLOSED guard must fire before the PROMOTABLE
# check so the issue does not slip through via the "todo" → Ready path.
CLOSED_TODO_SANDBOX="${CLAUDE_JOB_DIR:-/tmp}/promote-ready-smoke-$$-closed-todo"
mkdir -p "$CLOSED_TODO_SANDBOX/specs/1-closed-todo-test"

cat >"$CLOSED_TODO_SANDBOX/specs/1-closed-todo-test/created-issues.json" <<'EOF'
{"schema_version":"1","slug":"test","issues":[
 {"issue_number":23,"url":"https://x/23","title":"old epic","labels":[],"blocked_by":[]}
]}
EOF

cat >"$CLOSED_TODO_SANDBOX/board-closed-todo.json" <<'EOF'
{"items":[
 {"id":"ITEM1","content":{"type":"Issue","number":23,"state":"CLOSED","title":"test","url":"https://x/23"},"status":"Todo"}
]}
EOF

OUT="$(MAKATO_PROMOTE_SPECS_DIR="$CLOSED_TODO_SANDBOX/specs" \
       MAKATO_PROMOTE_GH_OVERRIDE="$CLOSED_TODO_SANDBOX/board-closed-todo.json" \
       "$PR" plan --json test 2>/dev/null)"
echo "$OUT" | jq empty 2>/dev/null || fail "T-PROMOTE-CLOSED-SKIP-TODO: output is not valid JSON: $OUT"
echo "$OUT" | jq -e '.ready | length == 0' >/dev/null 2>&1 \
  || fail "T-PROMOTE-CLOSED-SKIP-TODO: CLOSED+Todo issue #23 appeared in .ready: $OUT"
echo "$OUT" | jq -e '.skipped[0].status == "closed"' >/dev/null 2>&1 \
  || fail "T-PROMOTE-CLOSED-SKIP-TODO: .skipped[0].status != \"closed\": $OUT"
rm -rf "$CLOSED_TODO_SANDBOX"
pass "CLOSED+Todo issue #23 not promoted; in .skipped with status \"closed\""

# ---------------------------------------------------------------------------
# T-reconcile-1/2/3: _reconcile_blocked_by_labels doc-contract assertions
# These are grep-based structural checks — no network calls.
#
# Scope boundary (cfb1605 / #697): _reconcile_blocked_by_labels calls
# `gh issue edit` to add/remove blocked-by: labels on issues.  It does NOT
# call `gh project item-edit` and is therefore entirely outside the
# cfb1605 --project-id fix scope.  The cfb1605 fix patched
# _reconcile_orphaned_in_progress and _reconcile_orphaned_stale in loop.sh,
# which write to the project board via `gh project item-edit`.
# promote-ready.sh's reconciler only touches issue labels, never the board.
# ---------------------------------------------------------------------------

echo "=== T-reconcile-1: _reconcile_blocked_by_labels function exists in promote-ready.sh ==="
grep -q "_reconcile_blocked_by_labels()" "$PR" \
  || fail "T-reconcile-1: _reconcile_blocked_by_labels function not found in promote-ready.sh"
pass "_reconcile_blocked_by_labels function present"

echo "=== T-reconcile-2: promote-ready.sh contains blocked-by: pattern (stale label removal) ==="
grep -q '"blocked-by:' "$PR" \
  || fail "T-reconcile-2: blocked-by: label pattern not found in promote-ready.sh"
pass "blocked-by: pattern present in promote-ready.sh"

echo "=== T-reconcile-3: promote-ready.sh calls _reconcile_blocked_by_labels from cmd_run ==="
grep -q "_reconcile_blocked_by_labels$" "$PR" \
  || fail "T-reconcile-3: _reconcile_blocked_by_labels is not called (no bare call line found)"
pass "_reconcile_blocked_by_labels called from cmd_run"

# ---------------------------------------------------------------------------
# T-SB-1/2/3: reconcile-blocked functional tests (#32) — stale-blocked heal,
# merged-PR (stateReason=COMPLETED) signal, and rate-limit retry + WARN.
# Fully offline via a stateful PATH gh stub that records removed labels so the
# reconciler's "fully unblocked?" re-check sees them gone.
# ---------------------------------------------------------------------------
SB_BIN="$SANDBOX/sbbin"
mkdir -p "$SB_BIN"
cat > "$SB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal stateful gh stub for reconcile-blocked smoke tests (#32).
args=("$@"); sub="$1 $2"
emit() { # $1=json ; applies a trailing --jq filter if present
  local json="$1" i jqf=""
  for ((i=0;i<${#args[@]};i++)); do [[ "${args[$i]}" == "--jq" ]] && jqf="${args[$((i+1))]}"; done
  if [[ -n "$jqf" ]]; then jq -r "$jqf" <<<"$json"; else echo "$json"; fi
}
case "$sub" in
  "repo view") emit '{"nameWithOwner":"test/repo"}' ;;
  "issue list") emit "${GH_STUB_ISSUE_LIST:-[]}" ;;
  "issue view")
    n="$3"
    if [[ "$n" == "${GH_STUB_DEP:-564}" ]]; then
      json="${GH_STUB_DEP_JSON}"
      if [[ -s "${GH_STUB_REMOVED:-/dev/null}" ]]; then
        while IFS= read -r rl; do
          [[ -z "$rl" ]] && continue
          json="$(jq --arg l "$rl" '.labels |= map(select(.name != $l))' <<<"$json")"
        done < "${GH_STUB_REMOVED}"
      fi
      emit "$json"
    else
      emit "$(jq -n --arg s "${GH_STUB_BLOCKER_STATE:-OPEN}" --arg r "${GH_STUB_BLOCKER_REASON:-}" \
        '{state:$s, stateReason:(if $r=="" then null else $r end)}')"
    fi
    ;;
  "issue edit")
    ex="${GH_STUB_EDIT_EXIT:-0}"
    echo "edit $*" >> "${GH_STUB_EDIT_LOG:-/dev/null}"
    if [[ "$ex" == "0" ]]; then
      for ((i=0;i<${#args[@]};i++)); do
        [[ "${args[$i]}" == "--remove-label" ]] && echo "${args[$((i+1))]}" >> "${GH_STUB_REMOVED:-/dev/null}"
      done
    fi
    exit "$ex"
    ;;
  "label list") echo "" ;;
  *) : ;;
esac
STUB
chmod +x "$SB_BIN/gh"

SB_LIST='[{"number":564,"labels":[{"name":"blocked-by:563"},{"name":"status:blocked"}]}]'
SB_DEP_JSON='{"labels":[{"name":"blocked-by:563"},{"name":"status:blocked"}]}'

echo "=== T-SB-1: reconcile-blocked heals a stale status:blocked (blocker CLOSED) ==="
SB_LOG="$SANDBOX/sb1-edit.log"; SB_REMOVED="$SANDBOX/sb1-removed"; : >"$SB_LOG"; : >"$SB_REMOVED"
PATH="$SB_BIN:$PATH" MAKATO_RECONCILE_RETRY_SLEEP=0 \
  GH_STUB_ISSUE_LIST="$SB_LIST" GH_STUB_DEP=564 GH_STUB_DEP_JSON="$SB_DEP_JSON" \
  GH_STUB_EDIT_LOG="$SB_LOG" GH_STUB_REMOVED="$SB_REMOVED" GH_STUB_BLOCKER_STATE=CLOSED \
  bash "$PR" reconcile-blocked >/dev/null 2>&1 || fail "T-SB-1: reconcile-blocked exited non-zero"
grep -q -- "--remove-label blocked-by:563" "$SB_LOG" || fail "T-SB-1: blocked-by:563 not removed: $(cat "$SB_LOG")"
grep -q -- "--remove-label status:blocked"  "$SB_LOG" || fail "T-SB-1: status:blocked not removed: $(cat "$SB_LOG")"
pass "stale status:blocked healed (both labels removed) when blocker CLOSED"

echo "=== T-SB-2: merged-PR signal — stateReason=COMPLETED counts as resolved ==="
SB_LOG="$SANDBOX/sb2-edit.log"; SB_REMOVED="$SANDBOX/sb2-removed"; : >"$SB_LOG"; : >"$SB_REMOVED"
PATH="$SB_BIN:$PATH" MAKATO_RECONCILE_RETRY_SLEEP=0 \
  GH_STUB_ISSUE_LIST="$SB_LIST" GH_STUB_DEP=564 GH_STUB_DEP_JSON="$SB_DEP_JSON" \
  GH_STUB_EDIT_LOG="$SB_LOG" GH_STUB_REMOVED="$SB_REMOVED" GH_STUB_BLOCKER_STATE=OPEN GH_STUB_BLOCKER_REASON=COMPLETED \
  bash "$PR" reconcile-blocked >/dev/null 2>&1 || fail "T-SB-2: reconcile-blocked exited non-zero"
grep -q -- "--remove-label blocked-by:563" "$SB_LOG" || fail "T-SB-2: blocked-by:563 not removed on COMPLETED: $(cat "$SB_LOG")"
grep -q -- "--remove-label status:blocked"  "$SB_LOG" || fail "T-SB-2: status:blocked not removed on COMPLETED: $(cat "$SB_LOG")"
pass "merged-PR (stateReason=COMPLETED) treated as resolved"

echo "=== T-SB-3: rate-limit during removal → bounded retry + WARN, no silent swallow ==="
SB_LOG="$SANDBOX/sb3-edit.log"; SB_REMOVED="$SANDBOX/sb3-removed"; SB_ERR="$SANDBOX/sb3-stderr.log"
: >"$SB_LOG"; : >"$SB_REMOVED"; : >"$SB_ERR"
PATH="$SB_BIN:$PATH" MAKATO_RECONCILE_RETRY_SLEEP=0 MAKATO_RECONCILE_LABEL_RETRIES=3 \
  GH_STUB_ISSUE_LIST="$SB_LIST" GH_STUB_DEP=564 GH_STUB_DEP_JSON="$SB_DEP_JSON" \
  GH_STUB_EDIT_LOG="$SB_LOG" GH_STUB_REMOVED="$SB_REMOVED" GH_STUB_BLOCKER_STATE=CLOSED GH_STUB_EDIT_EXIT=1 \
  bash "$PR" reconcile-blocked >/dev/null 2>"$SB_ERR" || fail "T-SB-3: reconcile-blocked aborted on label-remove failure (should continue best-effort)"
grep -q "reconcile: WARN — could not remove label" "$SB_ERR" || fail "T-SB-3: no WARN logged on retry exhaustion: $(cat "$SB_ERR")"
[[ "$(grep -c -- "--remove-label blocked-by:563" "$SB_LOG")" -ge 3 ]] \
  || fail "T-SB-3: expected >=3 retry attempts, got $(grep -c -- '--remove-label blocked-by:563' "$SB_LOG")"
pass "rate-limit triggers bounded retry and logs WARN on exhaustion (no silent swallow)"

echo
echo "=== ALL PROMOTE-READY SMOKE TESTS PASSED (T1–T13, T-pjson-valid, T-pjson-collision, T-VCR-6–T-VCR-9, T-reconcile-1–T-reconcile-3, T-SB-1–T-SB-3, T-PROMOTE-CLOSED-SKIP, T-PROMOTE-CLOSED-SKIP-TODO) ==="
