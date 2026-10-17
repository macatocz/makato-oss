#!/usr/bin/env bash
# Smoke tests for the build-verify Gate-0 spec_key threading contract (#229).
#
# build-verify Step 3 (Gate 0: SENSORS) dispatches build-sensors. build-sensors
# marks `spec_key` REQUIRED (no default) and uses it to locate
# specs/<key>-<slug>/build.jsonl. If build-verify invokes the sensors run without
# threading the resolved <key>, the Gate-0 audit write lands nowhere consistent —
# and in autonomous mode the DoD Gate-0 record (item 5) is lost.
#
# The check is structural and deliberately shallow — the skill is executed by an
# LLM, not a shell. It checks the remaining spec_key audit-continuity contract.
#
# Coverage:
#   T1 — build-verify SKILL.md declares version >= 1.6.1
#   T2 — Step 3 prose names spec_key and references #229's audit-continuity intent
#   T3 — build-sensors still marks spec_key as required (contract anchor holds)
#
# Exit code: number of failures; 0 = all green.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_MD="$SCRIPT_DIR/../skills/build-verify/SKILL.md"
SENSORS_MD="$SCRIPT_DIR/../skills/build-sensors/SKILL.md"
FAIL=0

_pass() { printf '  ✓ %s\n' "$1"; }
_fail() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }

for f in "$VERIFY_MD" "$SENSORS_MD"; do
  if [[ ! -f "$f" ]]; then
    printf 'FATAL: cannot find SKILL.md at %s\n' "$f" >&2
    exit 99
  fi
done

# ----- T1: build-verify version >= 1.6.1 -----
echo "T1: build-verify SKILL.md version >= 1.6.1"
VERSION_LINE="$(grep -E '^version:' "$VERIFY_MD" | head -1)"
if [[ "$VERSION_LINE" =~ version:[[:space:]]*\"([0-9]+)\.([0-9]+)\.([0-9]+)\" ]]; then
  MAJOR="${BASH_REMATCH[1]}"
  MINOR="${BASH_REMATCH[2]}"
  PATCH="${BASH_REMATCH[3]}"
  if (( MAJOR > 1 )) \
    || { (( MAJOR == 1 )) && (( MINOR > 6 )); } \
    || { (( MAJOR == 1 )) && (( MINOR == 6 )) && (( PATCH >= 1 )); }; then
    _pass "version $VERSION_LINE"
  else
    _fail "version too low: $VERSION_LINE (need >= 1.6.1)"
  fi
else
  _fail "cannot parse version line: $VERSION_LINE"
fi


# ----- T2: Step 3 prose documents spec_key + #229 intent -----
echo "T2: Step 3 prose names spec_key and #229 audit continuity"
if grep -qE 'spec_key' "$VERIFY_MD" && grep -qE '#229' "$VERIFY_MD"; then
  _pass "spec_key rationale anchored to #229"
else
  _fail "missing spec_key prose or #229 reference in build-verify"
fi

# ----- T3: build-sensors still marks spec_key required (anchor) -----
echo "T3: build-sensors marks spec_key required (contract anchor)"
if grep -qE '\|[[:space:]]*.?spec_key.?[[:space:]]*\|[[:space:]]*string[[:space:]]*\|[[:space:]]*yes[[:space:]]*\|' "$SENSORS_MD"; then
  _pass "build-sensors spec_key still required"
else
  _fail "build-sensors no longer marks spec_key required — anchor broken"
fi

printf '\n'
if (( FAIL == 0 )); then
  printf 'All 3 tests passed.\n'
  exit 0
else
  printf '%d test(s) failed.\n' "$FAIL"
  exit "$FAIL"
fi
