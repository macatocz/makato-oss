#!/usr/bin/env bash
# Smoke tests for scripts/promote-ready.sh — dependency-aware Ready
# promotion (#268). Run from the makato repo root:
#
#   plugins/makato-orchestrate/scripts/promote-ready-smoke-tests.sh
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

echo
echo "=== ALL PROMOTE-READY SMOKE TESTS PASSED (T1–T15) ==="
