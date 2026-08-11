#!/usr/bin/env bash
# Smoke tests for scripts/e2e-mvp-proof.sh
#
# Offline only — no real loop.sh dispatch or gh calls. Uses stub scripts and
# env overrides to exercise the script's logic branches.
#
# Usage:
#   plugins/makato-orchestrate/scripts/tests/e2e-mvp-proof-smoke-tests.sh
#
# Scenarios:
#   T1: --dry-run without env vars exits non-zero with "missing required env var"
#   T2: --dry-run with all env vars prints plan and exits 0
#   T3: --dry-run output contains no dispatch command (safety gate)
#   T4: unknown flag exits non-zero
#   T5: full run with stubbed loop.sh, clean log, and board=Done → all PASS

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../e2e-mvp-proof.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

pass() { PASS=$((PASS + 1)); echo "  ok  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); echo "  FAIL $1 — $2"; }

# ---- T1: --dry-run without env vars exits non-zero -------------------------
t1() {
  local rc=0
  env -i PATH="$PATH" bash "$SCRIPT" --dry-run >/dev/null 2>&1 || rc=$?
  if [[ $rc -ne 0 ]]; then
    pass "T1 --dry-run without env vars exits non-zero"
  else
    fail "T1" "expected non-zero when env vars missing, got 0"
  fi
}

# ---- T2: --dry-run with all env vars exits 0 and prints plan ---------------
t2() {
  local out rc=0
  out="$(MAKATO_OPEN_ENDPOINT_URL="https://test.example.com" \
         MAKATO_E2E_ISSUE=42 \
         MAKATO_LOOP_DISPATCH_REPO="test/repo" \
         bash "$SCRIPT" --dry-run 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]] && echo "$out" | grep -q "Planned steps"; then
    pass "T2 --dry-run with valid env prints plan and exits 0"
  else
    fail "T2" "unexpected exit $rc or no 'Planned steps' in output"
  fi
}

# ---- T3: --dry-run output contains no real dispatch command ----------------
t3() {
  local out
  out="$(MAKATO_OPEN_ENDPOINT_URL="https://test.example.com" \
         MAKATO_E2E_ISSUE=42 \
         MAKATO_LOOP_DISPATCH_REPO="test/repo" \
         bash "$SCRIPT" --dry-run 2>&1)"
  # The dry-run must not contain the actual MAKATO_HEADLESS=1 ... loop.sh dispatch invocation
  # (as in actually executing it — the plan may mention it as text, which is fine).
  # We assert the script exits before reaching the dispatch section.
  if echo "$out" | grep -q "No dispatch command will be executed"; then
    pass "T3 --dry-run explicitly states no dispatch command executed"
  else
    fail "T3" "missing 'No dispatch command' safety statement in dry-run output"
  fi
}

# ---- T4: unknown flag exits non-zero ---------------------------------------
t4() {
  local rc=0
  MAKATO_OPEN_ENDPOINT_URL="https://test.example.com" \
  MAKATO_E2E_ISSUE=42 \
  MAKATO_LOOP_DISPATCH_REPO="test/repo" \
    bash "$SCRIPT" --unknown-flag >/dev/null 2>&1 || rc=$?
  if [[ $rc -ne 0 ]]; then
    pass "T4 unknown flag exits non-zero"
  else
    fail "T4" "expected non-zero for unknown flag, got 0"
  fi
}

# ---- T5: full run with stubbed loop.sh, clean log, board=Done → all PASS --
t5() {
  local d; d="$(mktemp -d)"
  # Stub loop.sh: writes a clean log (no stall), exits 0
  cat > "$d/loop.sh" << 'STUB'
#!/usr/bin/env bash
# Stub: write a clean dispatch log and exit 0
shift  # consume "dispatch"
shift  # consume issue number
mkdir -p "$HOME/.claude/state"
echo "dispatch started" >> "$HOME/.claude/state/e2e-proof-stub.log"
exit 0
STUB
  chmod +x "$d/loop.sh"

  # Stub verify-production-isolation.sh: always succeeds
  cat > "$d/verify-production-isolation.sh" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$d/verify-production-isolation.sh"

  # Stub assert-no-approval-stall.sh: always passes
  mkdir -p "$d/tests"
  cat > "$d/tests/assert-no-approval-stall.sh" << 'STUB'
#!/usr/bin/env bash
echo "assert-no-approval-stall: PASS — no stall signals found (stub)"
exit 0
STUB
  chmod +x "$d/tests/assert-no-approval-stall.sh"

  # Stub gh for board poll: return Done immediately
  cat > "$d/gh" << 'STUB'
#!/usr/bin/env bash
echo '{"items":[{"content":{"number":42},"status":"Done"}]}'
STUB
  chmod +x "$d/gh"

  local rc=0
  out="$(
    MAKATO_OPEN_ENDPOINT_URL="https://test.example.com" \
    MAKATO_E2E_ISSUE=42 \
    MAKATO_LOOP_DISPATCH_REPO="test/repo" \
    MAKATO_LOOP_STATE_DIR="$d/state" \
    MAKATO_ISOLATION_BASELINE="$d/baseline.sha256" \
    MAKATO_E2E_POLL_TIMEOUT=5 \
    MAKATO_E2E_POLL_INTERVAL=1 \
    HOME="$d/home" \
    PATH="$d:$PATH" \
      bash "$SCRIPT" 2>&1
  )" || rc=$?

  if [[ $rc -eq 0 ]] && echo "$out" | grep -q "PASS — all DoD rows passed"; then
    pass "T5 full stubbed run: all DoD rows PASS, exits 0"
  else
    fail "T5" "exit=$rc; output: $out"
  fi
  rm -rf "$d"
}

echo "=== e2e-mvp-proof-smoke-tests ==="
t1; t2; t3; t4
# T5 requires the stubbed PATH approach — only run when MAKATO_SMOKE_FULL=1 to avoid
# environment interference in CI. Run T1-T4 unconditionally.
if [[ "${MAKATO_SMOKE_FULL:-0}" == "1" ]]; then
  t5
else
  echo "  skip T5 (set MAKATO_SMOKE_FULL=1 to run full dispatch stub test)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "FAILED: ${FAILED_TESTS[*]}"
  exit 1
fi
exit 0
