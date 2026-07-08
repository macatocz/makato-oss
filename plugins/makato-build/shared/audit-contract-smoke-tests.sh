#!/usr/bin/env bash
# Smoke tests for the build-create-pr audit contract (#169).
#
# build-create-pr MUST emit exactly one terminal step:"session" line per
# invocation — either status:"ok" (Step 7 happy path) or status:"error"
# (Step 5c failure branch). This test guards SKILL.md against regressions
# that would let the skill exit silently between the pr-draft-approval
# bypass and gh pr create, as observed in #169.
#
# The check is structural: it scans SKILL.md for the required audit-log
# invocations and section markers. This is deliberately shallow — the
# skill is executed by an LLM, not a shell, so we cannot exercise the
# gh-failure branch end-to-end. What we CAN enforce is that the SKILL.md
# contract text describing that branch is present. If the text is stripped
# the contract is silently broken; the smoke test catches that.
#
# Coverage:
#   T1 — SKILL.md declares version >= 1.7.0
#   T2 — Step 5a mandatory pre-call pr_created status:"start" log exists
#   T3 — Step 5c on-success pr_created status:"ok" log exists
#   T4 — Step 5c on-failure pr_created status:"error" log exists
#   T5 — Step 5c terminal session status:"error" log exists
#   T6 — Step 7 terminal session status:"ok" log still present
#   T7 — HALT codes GH_AUTH_FAILED and PR_CREATE_FAILED are both classified
#   T8 — Return Format section documents the failure R1 envelope shape
#   T9 — "Audit invariant" section is present and references #169
#  T10 — Return Format failure envelope names both HALT codes as valid values
#
# Exit code: number of failures; 0 = all green.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_MD="$SCRIPT_DIR/../skills/build-create-pr/SKILL.md"
FAIL=0

_pass() { printf '  ✓ %s\n' "$1"; }
_fail() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }

if [[ ! -f "$SKILL_MD" ]]; then
  printf 'FATAL: cannot find SKILL.md at %s\n' "$SKILL_MD" >&2
  exit 99
fi

# ----- T1: version >= 1.7.0 -----
echo "T1: SKILL.md version >= 1.7.0"
VERSION_LINE="$(grep -E '^version:' "$SKILL_MD" | head -1)"
if [[ "$VERSION_LINE" =~ version:[[:space:]]*\"([0-9]+)\.([0-9]+)\.([0-9]+)\" ]]; then
  MAJOR="${BASH_REMATCH[1]}"
  MINOR="${BASH_REMATCH[2]}"
  if (( MAJOR > 1 )) || { (( MAJOR == 1 )) && (( MINOR >= 7 )); }; then
    _pass "version $VERSION_LINE"
  else
    _fail "version too low: $VERSION_LINE (need >= 1.7.0)"
  fi
else
  _fail "cannot parse version line: $VERSION_LINE"
fi

# ----- T2: Step 5a pr_created status:"start" -----
echo "T2: Step 5a pr_created status:\"start\" log"
if grep -qE '"step":"pr_created","status":"start"' "$SKILL_MD"; then
  _pass "pre-call start event documented"
else
  _fail "missing pre-call pr_created status:\"start\" log"
fi

# ----- T3: Step 5c on-success pr_created status:"ok" -----
echo "T3: Step 5c pr_created status:\"ok\" log"
if grep -qE '"step":"pr_created","status":"ok"' "$SKILL_MD"; then
  _pass "on-success ok event documented"
else
  _fail "missing pr_created status:\"ok\" log"
fi

# ----- T4: Step 5c on-failure pr_created status:"error" -----
echo "T4: Step 5c pr_created status:\"error\" log"
if grep -qE '"step":"pr_created","status":"error"' "$SKILL_MD"; then
  _pass "on-failure error event documented"
else
  _fail "missing pr_created status:\"error\" log"
fi

# ----- T5: Step 5c terminal session status:"error" -----
echo "T5: Step 5c terminal session status:\"error\" log"
if grep -qE '"step":"session","status":"error"' "$SKILL_MD"; then
  _pass "terminal session error event documented"
else
  _fail "missing terminal session status:\"error\" — silent-exit contract violated"
fi

# ----- T6: Step 7 terminal session status:"ok" still there -----
echo "T6: Step 7 terminal session status:\"ok\" log"
if grep -qE '"step":"session","status":"ok"' "$SKILL_MD"; then
  _pass "terminal session ok event documented"
else
  _fail "missing terminal session status:\"ok\" — happy path broken"
fi

# ----- T7: HALT codes classification -----
echo "T7: HALT codes GH_AUTH_FAILED + PR_CREATE_FAILED classified"
if grep -qE 'GH_AUTH_FAILED' "$SKILL_MD" && grep -qE 'PR_CREATE_FAILED' "$SKILL_MD"; then
  _pass "both HALT codes present"
else
  _fail "one or both HALT codes missing (GH_AUTH_FAILED, PR_CREATE_FAILED)"
fi

# ----- T8: Return Format failure envelope -----
echo "T8: Return Format section documents failure envelope"
if grep -qE '"status":[[:space:]]*"failure"' "$SKILL_MD"; then
  _pass "failure envelope documented"
else
  _fail "Return Format missing failure envelope shape"
fi

# ----- T9: Audit invariant section present + references #169 -----
echo "T9: Audit invariant section references #169"
if grep -qE '### Audit invariant' "$SKILL_MD" && grep -qE '#169' "$SKILL_MD"; then
  _pass "Audit invariant section anchored to #169"
else
  _fail "missing 'Audit invariant' section or #169 reference"
fi

# ----- T10: failure envelope enumerates both HALT codes -----
echo "T10: failure envelope enumerates GH_AUTH_FAILED | PR_CREATE_FAILED"
if grep -qE '"GH_AUTH_FAILED"[[:space:]]*\|[[:space:]]*"PR_CREATE_FAILED"' "$SKILL_MD"; then
  _pass "failure envelope halt_code enum documented"
else
  _fail "failure envelope halt_code enum missing"
fi

printf '\n'
if (( FAIL == 0 )); then
  printf 'All 10 tests passed.\n'
  exit 0
else
  printf '%d test(s) failed.\n' "$FAIL"
  exit "$FAIL"
fi
