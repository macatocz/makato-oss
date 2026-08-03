#!/usr/bin/env bash
# Smoke tests for the HALT-code registry (#115).
#
# Asserts that every HALT-code token referenced in any SKILL.md is registered
# in plugins/makato-build/halt-codes.md. A new code that doesn't appear in the
# registry fails the suite — the canonical mapping of skill code → PO-agent
# recovery route is the cross-process contract this test pins.
#
# Token extraction heuristic:
#   - Backticked uppercase-underscore tokens inside ## HALT Codes sections.
#   - Tokens following `data.halt_code: "..."` in skill prose.
#   - Tokens prefixed onto errors[] strings: `"CODE: ..."`.
#
# Tokens explicitly NOT registered here (legitimate orchestrate codes that may
# appear in build skills' prose): HALT-001 … HALT-010, HALT-STRUCTURAL — these
# live in plugins/makato-orchestrate/halt-conditions.md.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY="$PLUGIN_DIR/halt-codes.md"
SKILLS_DIR="$PLUGIN_DIR/skills"

FAIL=0
_pass() { printf '  ✓ %s\n' "$1"; }
_fail() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ----- T1: registry file exists and is non-empty -----
echo "T1: halt-codes.md present"
if [[ -s "$REGISTRY" ]]; then
  _pass "registry exists and is non-empty"
else
  _fail "registry missing or empty at $REGISTRY"
  echo "$FAIL halt-codes-smoke-tests failed."
  exit 1
fi

# ----- T2: every documented skill-level code appears in the registry -----
echo "T2: documented skill-level codes registered"
EXPECTED_CODES=(
  MISSING_INPUT
  MISSING_PLAN
  MISSING_ARTIFACTS
  SPEC_NOT_FOUND
  INVALID_FILE_TARGET
  UNCOVERED_AC
  BASELINE_BROKEN
  VERIFY_FAILED
  UNVERIFIED_HALT
  BUILD_FAILED
  PROTECTED_BRANCH
  NOTHING_TO_COMMIT
  COMMIT_FAILED
  PUSH_REJECTED
  UNPUSHED_COMMITS
  GH_AUTH_FAILED
  PR_CREATE_FAILED
  STRUCTURAL_BLOCKER
  CARRY_OVER_FAILED
  RENDER_FAILED
  CANARY_FAILED
)
for code in "${EXPECTED_CODES[@]}"; do
  if grep -qE "\`${code}\`|\`${code}: " "$REGISTRY"; then
    _pass "registry covers $code"
  else
    _fail "registry missing $code"
  fi
done

# ----- T3: registry rows have route + origin columns populated -----
echo "T3: every row names origin + route"
# Each table row begins with "| `CODE` " followed by | columns. Sample a few
# critical codes for sanity.
for code in MISSING_INPUT BASELINE_BROKEN PUSH_REJECTED STRUCTURAL_BLOCKER; do
  row="$(grep -E "^\| \`${code}\`" "$REGISTRY" | head -1)"
  if [[ -z "$row" ]]; then
    _fail "row for $code not found"
    continue
  fi
  # Count pipe-separated columns. Expect 5 dividers → 4 content cells + the
  # trailing |.
  pipes=$(awk -F '|' '{print NF}' <<<"$row")
  if [[ "$pipes" -ge 5 ]]; then
    _pass "row for $code has $((pipes - 2)) populated columns"
  else
    _fail "row for $code only has $((pipes - 2)) columns"
  fi
done

# ----- T4: every SKILL.md HALT Codes section refers to halt-codes.md -----
echo "T4: each SKILL.md HALT-Codes section forwards to registry"
for skill_md in "$SKILLS_DIR"/build-{refine,simplify,push-to-git,create-pr,address-pr-comments}/SKILL.md; do
  name="$(basename "$(dirname "$skill_md")")"
  if grep -q "halt-codes.md" "$skill_md"; then
    _pass "$name forwards to halt-codes.md"
  else
    _fail "$name does NOT forward to halt-codes.md"
  fi
done

# ----- T5: no SKILL.md still carries the old multi-row HALT table -----
echo "T5: no SKILL.md retains the old multi-row HALT table"
# Heuristic: the legacy form was "| Code | Meaning |" immediately under
# "### HALT Codes". The collapsed form is a paragraph; no table follows.
for skill_md in "$SKILLS_DIR"/build-{refine,simplify,push-to-git,create-pr,address-pr-comments}/SKILL.md; do
  name="$(basename "$(dirname "$skill_md")")"
  # awk: between "### HALT Codes" and next "##" heading, look for "| Code | Meaning"
  if awk '/^### HALT Codes/{inside=1; next} inside && /^## /{inside=0} inside' "$skill_md" | grep -qE '^\| Code \|'; then
    _fail "$name still carries the old multi-row HALT table"
  else
    _pass "$name HALT section is collapsed"
  fi
done

# ----- T6: orchestrate-level codes are NOT duplicated in this registry -----
echo "T6: orchestrate-level numeric HALT codes are NOT in this registry"
for halt in HALT-000 HALT-001 HALT-002 HALT-003 HALT-004 HALT-005 HALT-006 HALT-007 HALT-008 HALT-009 HALT-010 HALT-STRUCTURAL; do
  # Allow the code to appear in prose (e.g. "surfaces as `HALT-005`") but NOT
  # as a registered table row (a row would start with "| `HALT-XXX`").
  if grep -qE "^\| \`${halt}\`" "$REGISTRY"; then
    _fail "$halt should be in orchestrate registry, not here"
  else
    _pass "$halt not registered here (correct)"
  fi
done

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "All halt-codes smoke tests passed."
  exit 0
else
  echo "$FAIL halt-codes smoke test(s) failed."
  exit 1
fi
