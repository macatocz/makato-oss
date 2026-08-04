#!/usr/bin/env bash
# Smoke tests for the stale-artifact sensor doc-contract (#596).
#
# Verifies that all required artefacts for the stale-artifact sensor lane
# exist and reference each other correctly. All assertions are grep/jq-based
# doc-contract checks — no network, no mutation, no pre-commit execution.
#
# Coverage:
#   T1 — finding-routes.json contains stale-artifact:console-log key
#   T2 — stale-artifact:console-log route has fallback_skill (autofix-then-skill requirement)
#   T3 — stale-artifact-check.sh is executable and references console.log pattern
#   T4 — definition-of-done/SKILL.md item 8 references stale-artifact-check
#   T5 — build-verify/SKILL.md Gate 8 row references stale-artifact-check
#
# Exit code: number of failures; 0 = all green.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTES_JSON="$SCRIPT_DIR/finding-routes.json"
HOOK_SCRIPT="$SCRIPT_DIR/../pre-commit/stale-artifact-check.sh"
DOD_MD="$SCRIPT_DIR/../skills/definition-of-done/SKILL.md"
VERIFY_MD="$SCRIPT_DIR/../skills/build-verify/SKILL.md"
FAIL=0

_pass() { printf '  ✓ %s\n' "$1"; }
_fail() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }

# Guard: required files must exist before running assertions
for f in "$ROUTES_JSON" "$HOOK_SCRIPT" "$DOD_MD" "$VERIFY_MD"; do
  if [[ ! -f "$f" ]]; then
    printf 'FATAL: required file not found: %s\n' "$f" >&2
    exit 99
  fi
done

# ----- T1: finding-routes.json contains stale-artifact:console-log key -----
echo "T1: finding-routes.json contains stale-artifact:console-log"
ROUTE_VAL="$(jq -r '.routes["stale-artifact:console-log"] // empty' "$ROUTES_JSON" 2>/dev/null)"
if [[ -n "$ROUTE_VAL" ]]; then
  _pass "stale-artifact:console-log route present"
else
  _fail "stale-artifact:console-log route MISSING from finding-routes.json"
fi

# ----- T2: stale-artifact:console-log route has fallback_skill -----
echo "T2: stale-artifact:console-log route has fallback_skill"
FALLBACK="$(jq -r '.routes["stale-artifact:console-log"].fallback_skill // empty' "$ROUTES_JSON" 2>/dev/null)"
if [[ -n "$FALLBACK" ]]; then
  _pass "fallback_skill present: $FALLBACK"
else
  _fail "stale-artifact:console-log route missing fallback_skill (required for autofix-then-skill)"
fi

# ----- T3: stale-artifact-check.sh is executable and references console.log pattern -----
echo "T3: stale-artifact-check.sh executable and references console.log pattern"
if [[ -x "$HOOK_SCRIPT" ]]; then
  _pass "stale-artifact-check.sh is executable"
else
  _fail "stale-artifact-check.sh is NOT executable"
fi
if grep -q 'console\.log' "$HOOK_SCRIPT"; then
  _pass "stale-artifact-check.sh references console.log pattern"
else
  _fail "stale-artifact-check.sh does NOT reference console.log pattern"
fi

# ----- T4: definition-of-done/SKILL.md item 8 references stale-artifact-check -----
echo "T4: definition-of-done/SKILL.md item 8 references stale-artifact-check"
if grep -q 'stale-artifact-check' "$DOD_MD"; then
  _pass "DoD SKILL.md references stale-artifact-check"
else
  _fail "DoD SKILL.md does NOT reference stale-artifact-check (item 8 not updated)"
fi

# ----- T5: build-verify/SKILL.md Gate 8 row references stale-artifact-check -----
echo "T5: build-verify/SKILL.md Gate 8 row references stale-artifact-check"
if grep -q 'stale-artifact-check' "$VERIFY_MD"; then
  _pass "build-verify SKILL.md Gate 8 references stale-artifact-check"
else
  _fail "build-verify SKILL.md does NOT reference stale-artifact-check (Gate 8 not updated)"
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "All smoke tests passed."
else
  echo "$FAIL smoke test(s) FAILED."
fi

exit "$FAIL"
