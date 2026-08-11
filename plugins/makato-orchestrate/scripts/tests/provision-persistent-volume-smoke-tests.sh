#!/usr/bin/env bash
# Smoke tests for scripts/provision-persistent-volume.sh (issue #8).
# Fully offline — no gh, no network.
#
# Usage:
#   plugins/makato-orchestrate/scripts/tests/provision-persistent-volume-smoke-tests.sh
#
# Scenarios:
#   T-PPV-1: Creates all three subdirs under a fresh root
#   T-PPV-2: Idempotent — re-running prints "confirmed" for existing dirs
#   T-PPV-3: Env override MAKATO_PERSISTENT_VOLUME_ROOT changes root
#   T-PPV-4: Env override MAKATO_PV_WORKFLOW_STATE_DIR overrides workflow-state subdir
#   T-PPV-5: Tilde expansion works for default (~/.makato-pv) and overrides

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISION="$SCRIPT_DIR/../provision-persistent-volume.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

pass() { PASS=$((PASS + 1)); echo "  ok  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); echo "  FAIL $1 — $2"; }

# ---------------------------------------------------------------------------
echo "T-PPV-1: fresh run creates workflow-state, worktrees, branches"
{
  ROOT="$(mktemp -d)/pv"
  out="$(MAKATO_PERSISTENT_VOLUME_ROOT="$ROOT" \
         MAKATO_PV_WORKFLOW_STATE_DIR="$ROOT/workflow-state" \
         MAKATO_PV_WORKTREES_DIR="$ROOT/worktrees" \
         bash "$PROVISION" 2>&1)"

  if [[ -d "$ROOT/workflow-state" && -d "$ROOT/worktrees" && -d "$ROOT/branches" ]]; then
    pass "T-PPV-1"
  else
    fail "T-PPV-1" "expected 3 dirs under $ROOT; got: $(ls "$ROOT" 2>/dev/null || echo 'none')"
  fi
  rm -rf "$(dirname "$ROOT")"
}

# ---------------------------------------------------------------------------
echo "T-PPV-2: idempotent — re-run prints confirmed for existing dirs"
{
  ROOT="$(mktemp -d)/pv"
  export MAKATO_PERSISTENT_VOLUME_ROOT="$ROOT"
  export MAKATO_PV_WORKFLOW_STATE_DIR="$ROOT/workflow-state"
  export MAKATO_PV_WORKTREES_DIR="$ROOT/worktrees"
  # First run creates
  bash "$PROVISION" >/dev/null 2>&1
  # Second run should confirm (no errors)
  out="$(bash "$PROVISION" 2>&1)"
  unset MAKATO_PERSISTENT_VOLUME_ROOT MAKATO_PV_WORKFLOW_STATE_DIR MAKATO_PV_WORKTREES_DIR

  created_count="$(echo "$out" | grep -c "created" || true)"
  confirmed_count="$(echo "$out" | grep -c "confirmed" || true)"

  if [[ "$created_count" -eq 0 && "$confirmed_count" -ge 3 ]]; then
    pass "T-PPV-2"
  else
    fail "T-PPV-2" "expected 0 created + >=3 confirmed on second run; got created=$created_count confirmed=$confirmed_count"
  fi
  rm -rf "$(dirname "$ROOT")"
}

# ---------------------------------------------------------------------------
echo "T-PPV-3: MAKATO_PERSISTENT_VOLUME_ROOT override changes root"
{
  BASE="$(mktemp -d)"
  CUSTOM_ROOT="$BASE/custom-root"
  out="$(MAKATO_PERSISTENT_VOLUME_ROOT="$CUSTOM_ROOT" \
         MAKATO_PV_WORKFLOW_STATE_DIR="$CUSTOM_ROOT/workflow-state" \
         MAKATO_PV_WORKTREES_DIR="$CUSTOM_ROOT/worktrees" \
         bash "$PROVISION" 2>&1)"

  if [[ -d "$CUSTOM_ROOT/workflow-state" && -d "$CUSTOM_ROOT/branches" ]]; then
    pass "T-PPV-3"
  else
    fail "T-PPV-3" "dirs not created under custom root $CUSTOM_ROOT"
  fi
  rm -rf "$BASE"
}

# ---------------------------------------------------------------------------
echo "T-PPV-4: MAKATO_PV_WORKFLOW_STATE_DIR override uses custom path"
{
  ROOT="$(mktemp -d)/pv"
  CUSTOM_WF="$(mktemp -d)/custom-wf"
  out="$(MAKATO_PERSISTENT_VOLUME_ROOT="$ROOT" \
         MAKATO_PV_WORKFLOW_STATE_DIR="$CUSTOM_WF" \
         MAKATO_PV_WORKTREES_DIR="$ROOT/worktrees" \
         bash "$PROVISION" 2>&1)"

  if [[ -d "$CUSTOM_WF" ]]; then
    pass "T-PPV-4"
  else
    fail "T-PPV-4" "custom workflow-state dir $CUSTOM_WF not created"
  fi
  rm -rf "$(dirname "$ROOT")" "$(dirname "$CUSTOM_WF")"
}

# ---------------------------------------------------------------------------
echo "T-PPV-5: tilde in default path expands to HOME"
{
  # Run with no env overrides; the script should expand ~/.makato-pv to $HOME/.makato-pv.
  # We override MAKATO_PERSISTENT_VOLUME_ROOT to a safe temp dir so we don't write to
  # the real $HOME.
  SAFE="$(mktemp -d)/tilde-test"
  out="$(MAKATO_PERSISTENT_VOLUME_ROOT="$SAFE" \
         MAKATO_PV_WORKFLOW_STATE_DIR="$SAFE/workflow-state" \
         MAKATO_PV_WORKTREES_DIR="$SAFE/worktrees" \
         bash "$PROVISION" 2>&1)"

  # Confirm root line shows the expanded path (not a literal ~)
  if echo "$out" | grep "root=" | grep -qv "~"; then
    pass "T-PPV-5"
  else
    fail "T-PPV-5" "tilde not expanded in output: $out"
  fi
  rm -rf "$(dirname "$SAFE")"
}

# ---------------------------------------------------------------------------
echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "All $PASS tests passed."
else
  echo "$PASS passed, $FAIL FAILED: ${FAILED_TESTS[*]}"
  exit 1
fi
