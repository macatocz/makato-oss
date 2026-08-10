#!/usr/bin/env bash
# Smoke tests for .github/scripts/classify-plan-tier.sh (#211).
#
# Usage:
#   .github/scripts/classify-plan-tier-smoke-tests.sh
#
# Exercises the D8 precedence ladder end-to-end plus the two critical spec
# scenarios (human override preserved; keyword word-boundary correctness).
# Pure bash — no gh, no network.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CLASSIFY="$REPO_ROOT/.github/scripts/classify-plan-tier.sh"

pass=0
fail=0

# run <expected> <title> <body> <labels...>
run() {
  local expected="$1" title="$2" body="$3"; shift 3
  local labels; labels="$(printf '%s\n' "$@")"
  local got
  got="$(TITLE="$title" BODY="$body" LABELS="$labels" bash "$CLASSIFY")"
  if [ "$got" = "$expected" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s → %s\n' "${TEST_NAME:-test}" "$got"
  else
    fail=$((fail + 1))
    printf '  ✗ %s: expected [%s] got [%s]\n' "${TEST_NAME:-test}" "$expected" "$got"
  fi
}

big_body() { head -c "$1" /dev/zero | tr '\0' 'x'; }

TEST_NAME="T1 override wins over conflicting effort:xs"
run "full override" "small thing" "" "plan-tier:full" "effort:xs" "type:feature"

TEST_NAME="T2 override light preserved despite effort:xl"
run "light override" "anything" "$(big_body 5000)" "plan-tier:light" "effort:xl"

TEST_NAME="T3 type:change → change"
run "change classified" "add a feature" "" "type:change" "type:feature"

TEST_NAME="T4 fix keyword in title → change"
run "change classified" "fix broken login" "" "type:feature"

TEST_NAME="T5 hotfix/regression keyword in body snippet → change"
run "change classified" "urgent" "we hit a regression in prod" "effort:s"

TEST_NAME="T6 word-boundary: 'prefix' does NOT match 'fix'"
run "light classified" "add a prefix option" "" "effort:xs"

TEST_NAME="T7 word-boundary: 'debugging' does NOT match 'bug'"
run "light classified" "improve debugging output" "" "type:feature"

TEST_NAME="T7b canonical type:feat (enum) → light"
run "light classified" "add a prefix option" "" "type:feat"

TEST_NAME="T8 effort:l → light (a ~week story fits one build session; NOT a decomposition signal)"
run "light classified" "medium feature" "" "effort:l" "type:feature"

TEST_NAME="T9 effort:xl → full (>1 week ⇒ decomposition candidate)"
run "full classified" "big feature" "" "effort:xl"

TEST_NAME="T10 epic:* label → full"
run "full classified" "part of an epic" "" "epic:planning-lane" "type:feature"

TEST_NAME="T11 phase:* label → full"
run "full classified" "phase work" "" "phase:2" "type:feature"

TEST_NAME="T12 points:13 → full (at Fibonacci split threshold)"
run "full classified" "large story" "" "points:13" "type:feat"

TEST_NAME="T12b points:21 → full (above threshold)"
run "full classified" "huge story" "" "points:21" "type:feat"

TEST_NAME="T13 points:8 → light (below threshold; fits one build session)"
run "light classified" "sizable but single story" "" "points:8" "type:feat"

TEST_NAME="T13b points:12 → light (just below threshold)"
run "light classified" "just under" "" "points:12" "type:feat"

TEST_NAME="T13c multiple points:* labels → max value decides (5 + 13 ⇒ full)"
run "full classified" "conflicting estimates" "" "points:5" "points:13"

TEST_NAME="T14 long well-written body, no size label → light (body length is NOT a signal)"
run "light classified" "long spec" "$(big_body 3000)" "type:feat"

TEST_NAME="T14b very long body alone (no labels) → light (default), body length ignored"
run "light classified" "sprawling description" "$(big_body 5000)" ""

TEST_NAME="T15 epic-child shape (type:feat + effort:m + points:5) → light"
run "light classified" "add admin console widget" "" "type:feat" "tier:foundation" "effort:m" "points:5"

TEST_NAME="T16 type:feature + short body → light"
run "light classified" "a feature" "short description here" "type:feature"

TEST_NAME="T17 ambiguous (no signals) → light default (flipped from full)"
run "light classified" "mysterious issue" "" "priority:p2"

TEST_NAME="T18 empty everything → light default (flipped from full)"
run "light classified" "" "" ""

TEST_NAME="T19 change precedence beats effort:xl (rule 2 before rule 3)"
run "change classified" "fix the thing" "" "effort:xl" "epic:foo"

TEST_NAME="T20 custom points threshold via env (points:8 below default is full when threshold=8)"
got="$(TITLE="t" BODY="" LABELS="points:8" \
  PLAN_TIER_POINTS_THRESHOLD=8 bash "$CLASSIFY")"
if [ "$got" = "full classified" ]; then
  pass=$((pass + 1)); printf '  ✓ %s → %s\n' "$TEST_NAME" "$got"
else
  fail=$((fail + 1)); printf '  ✗ %s: expected [full classified] got [%s]\n' "$TEST_NAME" "$got"
fi

TEST_NAME="T20b body length has no env knob any more — huge body stays light regardless"
run "light classified" "no length knob" "$(big_body 9000)" "type:feat"

TEST_NAME="T21 SC-4: classifier references no ANTHROPIC_API_KEY / no LLM egress"
if grep -qiE 'ANTHROPIC_API_KEY|api\.anthropic|claude ' "$CLASSIFY"; then
  fail=$((fail + 1)); printf '  ✗ %s: classifier must not reference any LLM secret\n' "$TEST_NAME"
else
  pass=$((pass + 1)); printf '  ✓ %s\n' "$TEST_NAME"
fi

TEST_NAME="T22 SC-4: project-board-sync workflow references no ANTHROPIC_API_KEY"
WORKFLOW="$REPO_ROOT/.github/workflows/project-board-sync.yml"
if grep -qiE 'ANTHROPIC_API_KEY|api\.anthropic' "$WORKFLOW"; then
  fail=$((fail + 1)); printf '  ✗ %s: workflow must not reference any LLM secret\n' "$TEST_NAME"
else
  pass=$((pass + 1)); printf '  ✓ %s\n' "$TEST_NAME"
fi

echo ""
echo "plan-tier classifier smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
