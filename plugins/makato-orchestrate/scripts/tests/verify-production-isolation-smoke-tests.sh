#!/usr/bin/env bash
# Smoke tests for scripts/verify-production-isolation.sh
#
# Fully offline: all paths are temp fixture directories; no real ~/.claude paths
# are read or written. Uses MAKATO_ISOLATION_BASELINE to redirect the baseline
# file to a sandbox location.
#
# Usage:
#   plugins/makato-orchestrate/scripts/tests/verify-production-isolation-smoke-tests.sh
#
# Scenarios:
#   T1: --capture creates a baseline file with expected entries
#   T2: --check passes immediately after --capture (no drift)
#   T3: --check detects a modified file (drift)
#   T4: --check detects a removed file (drift)
#   T5: --check without prior --capture exits non-zero with clear message
#   T6: --capture includes MAKATO_PRODUCTION_ROOT when set
#   T7: unknown flag exits non-zero with usage message

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../verify-production-isolation.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

pass() { PASS=$((PASS + 1)); echo "  ok  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); echo "  FAIL $1 — $2"; }

# Fresh sandbox with fixture paths
new_sandbox() {
  local d; d="$(mktemp -d)"
  # Create a fixture file that represents ~/.claude/settings.json
  mkdir -p "$d/dot-claude"
  echo '{"model":"test"}' > "$d/dot-claude/settings.json"
  echo "$d"
}

run_capture() {
  local sandbox="$1"
  MAKATO_ISOLATION_BASELINE="$sandbox/baseline.sha256" \
  HOME="$sandbox/fake_home" \
    bash "$SCRIPT" --capture 2>&1
}

run_check() {
  local sandbox="$1"
  MAKATO_ISOLATION_BASELINE="$sandbox/baseline.sha256" \
  HOME="$sandbox/fake_home" \
    bash "$SCRIPT" --check 2>&1
  echo "exit:$?"
}

# ---- T1: --capture creates baseline file -----------------------------------
t1() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/fake_home/.claude"
  echo '{"model":"test"}' > "$d/fake_home/.claude/settings.json"

  MAKATO_ISOLATION_BASELINE="$d/baseline.sha256" \
  HOME="$d/fake_home" \
    bash "$SCRIPT" --capture >/dev/null 2>&1
  if [[ -f "$d/baseline.sha256" ]]; then
    pass "T1 --capture creates baseline file"
  else
    fail "T1" "baseline.sha256 not created"
  fi
  rm -rf "$d"
}

# ---- T2: --check passes after --capture (no drift) -------------------------
t2() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/fake_home/.claude"
  echo '{"model":"test"}' > "$d/fake_home/.claude/settings.json"

  MAKATO_ISOLATION_BASELINE="$d/baseline.sha256" HOME="$d/fake_home" \
    bash "$SCRIPT" --capture >/dev/null 2>&1
  local rc=0
  MAKATO_ISOLATION_BASELINE="$d/baseline.sha256" HOME="$d/fake_home" \
    bash "$SCRIPT" --check >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "T2 --check passes immediately after --capture"
  else
    fail "T2" "unexpected drift; exit $rc"
  fi
  rm -rf "$d"
}

# ---- T3: --check detects modified file -------------------------------------
t3() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/fake_home/.claude"
  echo '{"model":"test"}' > "$d/fake_home/.claude/settings.json"

  MAKATO_ISOLATION_BASELINE="$d/baseline.sha256" HOME="$d/fake_home" \
    bash "$SCRIPT" --capture >/dev/null 2>&1
  # Mutate settings.json after capture
  echo '{"model":"changed"}' > "$d/fake_home/.claude/settings.json"
  local rc=0
  MAKATO_ISOLATION_BASELINE="$d/baseline.sha256" HOME="$d/fake_home" \
    bash "$SCRIPT" --check >/dev/null 2>&1 || rc=$?
  if [[ $rc -ne 0 ]]; then
    pass "T3 --check exits non-zero on modified file"
  else
    fail "T3" "expected non-zero exit for mutated settings.json, got 0"
  fi
  rm -rf "$d"
}

# ---- T4: --check detects removed file (absent → present drift) -------------
t4() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/fake_home/.claude"
  echo '{"model":"test"}' > "$d/fake_home/.claude/settings.json"
  # Add HALT file at capture time, then remove it
  touch "$d/fake_home/.claude/HALT"

  MAKATO_ISOLATION_BASELINE="$d/baseline.sha256" HOME="$d/fake_home" \
    bash "$SCRIPT" --capture >/dev/null 2>&1
  rm "$d/fake_home/.claude/HALT"
  local rc=0
  MAKATO_ISOLATION_BASELINE="$d/baseline.sha256" HOME="$d/fake_home" \
    bash "$SCRIPT" --check >/dev/null 2>&1 || rc=$?
  if [[ $rc -ne 0 ]]; then
    pass "T4 --check exits non-zero when file removed post-capture"
  else
    fail "T4" "expected non-zero exit for removed HALT file, got 0"
  fi
  rm -rf "$d"
}

# ---- T5: --check without prior --capture exits non-zero --------------------
t5() {
  local d; d="$(mktemp -d)"
  local rc=0
  MAKATO_ISOLATION_BASELINE="$d/no-such-baseline.sha256" HOME="$d/fake_home" \
    bash "$SCRIPT" --check >/dev/null 2>&1 || rc=$?
  if [[ $rc -ne 0 ]]; then
    pass "T5 --check without baseline exits non-zero"
  else
    fail "T5" "expected non-zero when no baseline exists, got 0"
  fi
  rm -rf "$d"
}

# ---- T6: --capture includes MAKATO_PRODUCTION_ROOT when set ----------------
t6() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/fake_home/.claude"
  echo '{}' > "$d/fake_home/.claude/settings.json"
  local prod_root="$d/prod-makato"
  mkdir -p "$prod_root"
  echo "fake-file" > "$prod_root/loop.sh"

  MAKATO_ISOLATION_BASELINE="$d/baseline.sha256" \
  HOME="$d/fake_home" \
  MAKATO_PRODUCTION_ROOT="$prod_root" \
    bash "$SCRIPT" --capture >/dev/null 2>&1
  if grep -qF "  $prod_root" "$d/baseline.sha256" 2>/dev/null; then
    pass "T6 MAKATO_PRODUCTION_ROOT included in baseline"
  else
    fail "T6" "production root not found in baseline: $(cat "$d/baseline.sha256")"
  fi
  rm -rf "$d"
}

# ---- T7: unknown flag exits non-zero with usage ----------------------------
t7() {
  local rc=0
  bash "$SCRIPT" --unknown >/dev/null 2>&1 || rc=$?
  if [[ $rc -ne 0 ]]; then
    pass "T7 unknown flag exits non-zero"
  else
    fail "T7" "expected non-zero for unknown flag, got 0"
  fi
}

echo "=== verify-production-isolation-smoke-tests ==="
t1; t2; t3; t4; t5; t6; t7

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "FAILED: ${FAILED_TESTS[*]}"
  exit 1
fi
exit 0
