#!/usr/bin/env bash
# gate4-mandatory-integration-smoke-tests.sh
# Smoke tests for the Gate 4 mandatory-integration contract (#581).
#
# Tests are grep-based contract assertions against the modified files:
#   - workflow-state.schema.json  (Task 1: plan_analysis field)
#   - build-verify/SKILL.md       (Task 2: Gate 4 mandatory-gate contract)
#
# Run:  bash plugins/makato-build/shared/gate4-mandatory-integration-smoke-tests.sh
# Pass: exit 0 with PASS line per assertion
# Fail: exit 1 with first FAIL line and assertion label
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCHEMA="$REPO_ROOT/plugins/makato-orchestrate/skills/workflow-state/references/workflow-state.schema.json"
SKILL="$REPO_ROOT/plugins/makato-build/skills/build-verify/SKILL.md"

PASS=0
FAIL=0

assert_grep() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label  (pattern='$pattern' not found in $file)"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep_count() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  local min="$4"
  local actual
  actual="$(grep -c "$pattern" "$file" 2>/dev/null || echo 0)"
  if [ "$actual" -ge "$min" ]; then
    echo "PASS: $label  (count=$actual >= min=$min)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label  (count=$actual < min=$min, pattern='$pattern')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Gate 4 mandatory-integration contract smoke tests (#581) ==="
echo ""

# ── Task 1: workflow-state schema contains plan_analysis ───────────────────
echo "--- Task 1: workflow-state schema ---"

assert_grep \
  "T1-1: schema contains plan_analysis top-level property" \
  '"plan_analysis"' \
  "$SCHEMA"

assert_grep \
  "T1-2: schema plan_analysis contains tracer_required (boolean)" \
  '"tracer_required"' \
  "$SCHEMA"

assert_grep \
  "T1-3: schema plan_analysis contains layers_detected (array)" \
  '"layers_detected"' \
  "$SCHEMA"

assert_grep \
  "T1-4: schema plan_analysis contains distinct_layer_count (integer)" \
  '"distinct_layer_count"' \
  "$SCHEMA"

# Verify the schema is valid JSON
if python3 -c "import json; json.load(open('$SCHEMA'))" 2>/dev/null; then
  echo "PASS: T1-5: schema is valid JSON"
  PASS=$((PASS + 1))
else
  echo "FAIL: T1-5: schema is NOT valid JSON"
  FAIL=$((FAIL + 1))
fi

echo ""

# ── Task 2: build-verify SKILL.md Gate 4 contract ──────────────────────────
echo "--- Task 2: build-verify SKILL.md Gate 4 ---"

assert_grep \
  "T2-1: Gate 4 Step 7 references plan_analysis field from workflow-state" \
  "plan_analysis" \
  "$SKILL"

assert_grep \
  "T2-2: Gate 4 Step 7 references tracer_required condition" \
  "tracer_required" \
  "$SKILL"

assert_grep \
  "T2-3: Gate 4 Step 7 references distinct_layer_count >= 3" \
  "distinct_layer_count" \
  "$SKILL"

assert_grep \
  "T2-4: Gate 4 Step 7 distinguishes MANDATORY vs non-mandatory path" \
  "MANDATORY" \
  "$SKILL"

assert_grep \
  "T2-5: Gate 4 Step 7 documents backward-compatible non-blocking path for single-layer changes" \
  "single-layer" \
  "$SKILL"

assert_grep \
  "T2-6: Gate 4 Step 7 log entry includes mandatory boolean field" \
  '"mandatory"' \
  "$SKILL"

echo ""

# ── Summary ────────────────────────────────────────────────────────────────
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "SMOKE TEST FAILED — $FAIL assertion(s) did not pass."
  exit 1
fi

echo "All $PASS assertions passed."
exit 0
