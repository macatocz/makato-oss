#!/usr/bin/env bash
# Smoke tests for .github/workflows/loop-cron.yml — YAML invariant assertions (#600).
# Run from the makato repo root.
#
# Usage:
#   plugins/makato-orchestrate/scripts/loop-cron-smoke-tests.sh
#
# Scenarios:
#   T-CRON-1: schedule: trigger present
#   T-CRON-2: runner is self-hosted, NOT ubuntu-latest on the runs-on line
#   T-CRON-3: MAKATO_HEADLESS: "1" present in env block (headless subprocess guard)
#   T-CRON-4: cancel-in-progress: false present in concurrency block
#   T-CRON-5: step invokes loop.sh run --once
#
# Tests run WITHOUT gh, network, or real claude — pure file content checks.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKFLOW="$REPO_ROOT/.github/workflows/loop-cron.yml"

PASS=0
FAIL=0

fail() {
  echo "  FAIL: $*" >&2
  FAIL=$(( FAIL + 1 ))
}

pass() {
  echo "  PASS: $*"
  PASS=$(( PASS + 1 ))
}

cleanup() {
  : # no temp files to remove
}
trap cleanup EXIT

# Guard: workflow file must exist before any assertion
if [[ ! -f "$WORKFLOW" ]]; then
  echo "FATAL: $WORKFLOW not found — cannot run smoke tests" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
echo "=== T-CRON-1: schedule: trigger present ==="
{
  if grep -q 'schedule:' "$WORKFLOW"; then
    pass "T-CRON-1: 'schedule:' trigger found in loop-cron.yml"
  else
    fail "T-CRON-1: 'schedule:' trigger missing from loop-cron.yml"
  fi
}

# ---------------------------------------------------------------------------
echo "=== T-CRON-2: runner is self-hosted, NOT ubuntu-latest ==="
{
  has_self_hosted=0
  has_ubuntu_latest=0

  if grep -q 'self-hosted' "$WORKFLOW"; then
    has_self_hosted=1
  fi
  # Check specifically the runs-on line for ubuntu-latest
  if grep 'runs-on' "$WORKFLOW" | grep -q 'ubuntu-latest'; then
    has_ubuntu_latest=1
  fi

  if [[ "$has_self_hosted" -eq 1 && "$has_ubuntu_latest" -eq 0 ]]; then
    pass "T-CRON-2: runner is self-hosted; ubuntu-latest absent from runs-on"
  elif [[ "$has_self_hosted" -eq 0 ]]; then
    fail "T-CRON-2: 'self-hosted' not found in loop-cron.yml"
  else
    fail "T-CRON-2: 'ubuntu-latest' present on runs-on line — cloud runner must not be used"
  fi
}

# ---------------------------------------------------------------------------
echo "=== T-CRON-3: MAKATO_HEADLESS: \"1\" present in env block ==="
{
  if grep -q 'MAKATO_HEADLESS:' "$WORKFLOW" && grep 'MAKATO_HEADLESS:' "$WORKFLOW" | grep -q '"1"'; then
    pass "T-CRON-3: MAKATO_HEADLESS: \"1\" found in env block"
  else
    fail "T-CRON-3: MAKATO_HEADLESS: \"1\" missing from env block — loop.sh will deadlock in headless subprocess"
  fi
}

# ---------------------------------------------------------------------------
echo "=== T-CRON-4: cancel-in-progress: false present in concurrency block ==="
{
  if grep -q 'cancel-in-progress: false' "$WORKFLOW"; then
    pass "T-CRON-4: cancel-in-progress: false found in concurrency block"
  else
    fail "T-CRON-4: cancel-in-progress: false missing — overlapping cron ticks may stack"
  fi
}

# ---------------------------------------------------------------------------
echo "=== T-CRON-5: step invokes loop.sh run --once ==="
{
  if grep -q 'run --once' "$WORKFLOW"; then
    pass "T-CRON-5: 'run --once' found in workflow run block"
  else
    fail "T-CRON-5: 'run --once' missing — loop.sh must be invoked with run --once"
  fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL=$(( PASS + FAIL ))
echo ""
echo "=== loop-cron smoke tests: ${PASS}/${TOTAL} passed ==="
if [[ "$FAIL" -gt 0 ]]; then
  echo "FAILED: $FAIL test(s) failed" >&2
  exit 1
fi
exit 0
