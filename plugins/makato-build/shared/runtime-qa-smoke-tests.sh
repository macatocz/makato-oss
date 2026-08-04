#!/usr/bin/env bash
# Smoke tests for the build-runtime-qa doc-contract (#582).
#
# Verifies that all required artefacts for the runtime-qa lane exist and
# reference each other correctly. All assertions are grep-based doc-contract
# checks against local files — no network, no mutation, no agent dispatch.
#
# Coverage:
#   T1 — agents/runtime-qa.md exists and contains `name: runtime-qa` frontmatter
#   T2 — agents/RETURN-CONTRACT.md documents runtime-qa data schema
#   T3 — skills/build-runtime-qa/SKILL.md exists and contains RUNTIME_QA_BLOCKED
#        in its ## HALT Codes section
#   T4 — halt-codes.md contains RUNTIME_QA_BLOCKED row
#   T5 — po-agent.md contains build-runtime-qa in Step 6
#   T6 — po-agent.md progress-comment narration table contains build-runtime-qa row
#
# Exit code: number of failures; 0 = all green.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ORCH_DIR="$(cd "$PLUGIN_DIR/../makato-orchestrate" && pwd)"

AGENT_MD="$PLUGIN_DIR/agents/runtime-qa.md"
RETURN_CONTRACT="$PLUGIN_DIR/agents/RETURN-CONTRACT.md"
SKILL_MD="$PLUGIN_DIR/skills/build-runtime-qa/SKILL.md"
HALT_CODES="$PLUGIN_DIR/halt-codes.md"
PO_AGENT="$ORCH_DIR/agents/po-agent.md"

FAIL=0
_pass() { printf '  ✓ %s\n' "$1"; }
_fail() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ----- T1: agents/runtime-qa.md exists with correct frontmatter -----
echo "T1: agents/runtime-qa.md exists with name: runtime-qa frontmatter"
if [[ ! -f "$AGENT_MD" ]]; then
  _fail "runtime-qa.md NOT FOUND at $AGENT_MD"
elif grep -qE '^name: runtime-qa' "$AGENT_MD"; then
  _pass "runtime-qa.md present with name: runtime-qa"
else
  _fail "runtime-qa.md exists but missing 'name: runtime-qa' frontmatter line"
fi

# ----- T2: RETURN-CONTRACT.md documents runtime-qa data schema -----
echo "T2: RETURN-CONTRACT.md documents runtime-qa data schema"
if [[ ! -f "$RETURN_CONTRACT" ]]; then
  _fail "RETURN-CONTRACT.md NOT FOUND at $RETURN_CONTRACT"
elif grep -q "runtime-qa" "$RETURN_CONTRACT"; then
  _pass "RETURN-CONTRACT.md references runtime-qa"
else
  _fail "RETURN-CONTRACT.md does NOT document runtime-qa per-agent data schema"
fi

# ----- T3: skills/build-runtime-qa/SKILL.md exists with RUNTIME_QA_BLOCKED -----
echo "T3: skills/build-runtime-qa/SKILL.md exists with RUNTIME_QA_BLOCKED in HALT Codes"
if [[ ! -f "$SKILL_MD" ]]; then
  _fail "build-runtime-qa/SKILL.md NOT FOUND at $SKILL_MD"
else
  _pass "build-runtime-qa/SKILL.md present"
  # Check RUNTIME_QA_BLOCKED appears in the ## HALT Codes section
  if awk '/^## HALT Codes/{inside=1; next} inside && /^## /{inside=0} inside' "$SKILL_MD" \
      | grep -q "RUNTIME_QA_BLOCKED"; then
    _pass "RUNTIME_QA_BLOCKED found in SKILL.md ## HALT Codes section"
  else
    _fail "RUNTIME_QA_BLOCKED NOT found in build-runtime-qa/SKILL.md ## HALT Codes section"
  fi
fi

# ----- T4: halt-codes.md contains RUNTIME_QA_BLOCKED row -----
echo "T4: halt-codes.md contains RUNTIME_QA_BLOCKED row"
if [[ ! -f "$HALT_CODES" ]]; then
  _fail "halt-codes.md NOT FOUND at $HALT_CODES"
elif grep -qE '^\| `RUNTIME_QA_BLOCKED`' "$HALT_CODES"; then
  _pass "RUNTIME_QA_BLOCKED registry row present in halt-codes.md"
else
  _fail "RUNTIME_QA_BLOCKED registry row MISSING from halt-codes.md"
fi

# ----- T5: po-agent.md contains build-runtime-qa in Step 6 -----
echo "T5: po-agent.md contains build-runtime-qa in Step 6 dispatch block"
if [[ ! -f "$PO_AGENT" ]]; then
  _fail "po-agent.md NOT FOUND at $PO_AGENT"
elif grep -q "build-runtime-qa" "$PO_AGENT"; then
  _pass "po-agent.md references build-runtime-qa"
else
  _fail "po-agent.md does NOT reference build-runtime-qa"
fi

# ----- T6: po-agent.md progress-comment table contains build-runtime-qa row -----
echo "T6: po-agent.md progress-comment narration table contains build-runtime-qa row"
if [[ ! -f "$PO_AGENT" ]]; then
  _fail "po-agent.md NOT FOUND at $PO_AGENT"
elif grep -qE '\| Step 6 #1b \|.*build-runtime-qa' "$PO_AGENT"; then
  _pass "po-agent.md narration table has build-runtime-qa row at Step 6 #1b"
else
  _fail "po-agent.md narration table MISSING build-runtime-qa row (expected Step 6 #1b)"
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "All runtime-qa smoke tests passed."
  exit 0
else
  echo "$FAIL runtime-qa smoke test(s) failed."
  exit "$FAIL"
fi
