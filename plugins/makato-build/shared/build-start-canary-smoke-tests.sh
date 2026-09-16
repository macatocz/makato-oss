#!/usr/bin/env bash
# Smoke tests for build-start Step 2e canary gate (#586).
#
# Asserts that:
#   T1 — Step 2e heading is present and positioned between Step 2 and Step 3
#   T2 — Step 2e prose references gate-scout dispatch
#   T3 — Step 2e prose references unit command with a timeout
#   T4 — CANARY_FAILED is registered in halt-codes.md
#   T5 — CANARY_FAILED is listed in EXPECTED_CODES in halt-codes-smoke-tests.sh
#   T6 — Step 2e documents the no-unit-command skip path
#   T7 — Step 2e references build.jsonl log entry for canary outcome
#
# All tests are grep-based prose assertions; no subprocess execution.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_START_SKILL="$PLUGIN_DIR/skills/build-start/SKILL.md"
HALT_CODES_REGISTRY="$PLUGIN_DIR/halt-codes.md"
HALT_CODES_SMOKE="$PLUGIN_DIR/shared/halt-codes-smoke-tests.sh"

FAIL=0
_pass() { printf '  \xe2\x9c\x93 %s\n' "$1"; }
_fail() { printf '  \xe2\x9c\x97 %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ----- T1: Step 2e heading present and positioned between Step 2 and Step 3 ---
echo "T1: Step 2e heading positioned between Step 2 and Step 3"
if [[ -s "$BUILD_START_SKILL" ]]; then
  LINE_2=$(grep -n "### Step 2 " "$BUILD_START_SKILL" | head -1 | cut -d: -f1)
  LINE_2E=$(grep -n "### Step 2e " "$BUILD_START_SKILL" | head -1 | cut -d: -f1)
  LINE_3=$(grep -n "### Step 3 " "$BUILD_START_SKILL" | head -1 | cut -d: -f1)
  if [[ -n "$LINE_2E" ]]; then
    _pass "Step 2e heading present (line $LINE_2E)"
    if [[ -n "$LINE_2" && -n "$LINE_3" ]] && \
       [[ "$LINE_2" -lt "$LINE_2E" && "$LINE_2E" -lt "$LINE_3" ]]; then
      _pass "Step 2e positioned after Step 2 (line $LINE_2) and before Step 3 (line $LINE_3)"
    else
      _fail "Step 2e ordering wrong: 2=$LINE_2, 2e=$LINE_2E, 3=$LINE_3"
    fi
  else
    _fail "Step 2e heading absent from $BUILD_START_SKILL"
  fi
else
  _fail "build-start SKILL.md missing at $BUILD_START_SKILL"
fi

# ----- T2: Step 2e prose references gate-scout dispatch -----
echo "T2: Step 2e references gate-scout dispatch"
if grep -q "gate-scout" "$BUILD_START_SKILL"; then
  _pass "gate-scout referenced in build-start SKILL.md"
else
  _fail "gate-scout not referenced — Step 2e must dispatch gate-scout to discover unit command"
fi

# ----- T3: Step 2e prose references unit command with a timeout -----
echo "T3: Step 2e references unit command with timeout"
if grep -qE "\-\-timeout [0-9]+" "$BUILD_START_SKILL"; then
  _pass "timeout flag pattern referenced (e.g. --timeout 30)"
else
  _fail "no timeout pattern found in $BUILD_START_SKILL — Step 2e must document a timeout"
fi

# ----- T4: CANARY_FAILED registered in halt-codes.md -----
echo "T4: CANARY_FAILED registered in halt-codes.md"
if [[ -s "$HALT_CODES_REGISTRY" ]]; then
  if grep -q "CANARY_FAILED" "$HALT_CODES_REGISTRY"; then
    _pass "CANARY_FAILED registered in halt-codes.md"
  else
    _fail "CANARY_FAILED missing from halt-codes.md registry"
  fi
else
  _fail "halt-codes.md missing at $HALT_CODES_REGISTRY"
fi

# ----- T5: CANARY_FAILED listed in EXPECTED_CODES array of halt-codes-smoke-tests.sh -----
echo "T5: CANARY_FAILED in halt-codes-smoke-tests.sh EXPECTED_CODES"
if [[ -s "$HALT_CODES_SMOKE" ]]; then
  if grep -q "CANARY_FAILED" "$HALT_CODES_SMOKE"; then
    _pass "CANARY_FAILED present in halt-codes-smoke-tests.sh"
  else
    _fail "CANARY_FAILED absent from EXPECTED_CODES in halt-codes-smoke-tests.sh"
  fi
else
  _fail "halt-codes-smoke-tests.sh missing at $HALT_CODES_SMOKE"
fi

# ----- T6: Step 2e documents the no-unit-command skip path -----
echo "T6: Step 2e documents no-unit-command skip path"
if grep -qE "no.unit.command|no unit command|CANARY_SKIPPED" "$BUILD_START_SKILL"; then
  _pass "no-unit-command skip path documented in build-start SKILL.md"
else
  _fail "no-unit-command skip path absent — Step 2e must document skip when no unit command discovered"
fi

# ----- T7: Step 2e references build.jsonl log entry for canary outcome -----
echo "T7: Step 2e references build.jsonl log entry for canary outcome"
if grep -qE 'build\.jsonl|step.*canary|canary.*step' "$BUILD_START_SKILL"; then
  _pass "build.jsonl canary log entry referenced in build-start SKILL.md"
else
  _fail "build.jsonl canary log entry not referenced — Step 2e must document JSONL audit entries"
fi

# ----- T8: workspace isolation is mandatory in autonomous and interactive modes
echo "T8: build-start documents both workspace isolation contracts"
if grep -qF 'WORKTREE_PATH' "$BUILD_START_SKILL" && \
   grep -qF 'MISSING_INPUT: WORKTREE_PATH required in autonomous mode' "$BUILD_START_SKILL" && \
   grep -qF 'interactive-worktree.sh' "$BUILD_START_SKILL" && \
   grep -qF 'Never fall back to the main' "$BUILD_START_SKILL"; then
  _pass "build-start requires an autonomous path and creates an interactive worktree"
else
  _fail "build-start missing interactive/autonomous WORKTREE_PATH guard"
fi

# ----- Summary -----
echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "All build-start canary smoke tests passed."
  exit 0
else
  echo "$FAIL build-start canary smoke test(s) failed."
  exit 1
fi
