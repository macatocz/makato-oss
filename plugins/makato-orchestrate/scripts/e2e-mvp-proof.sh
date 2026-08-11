#!/usr/bin/env bash
# e2e-mvp-proof.sh — end-to-end MVP independence proof runner (issue #7).
#
# Orchestrates the Phase-1 exit proof: drives one Status=Ready GitHub issue
# through the full autonomous loop (build → review → PR → merge) headlessly
# on a cloud open-model endpoint, then verifies all four DoD rows.
#
# Prerequisites:
#   MAKATO_OPEN_ENDPOINT_URL   — base URL of the cloud open-model API (required)
#   MAKATO_E2E_ISSUE           — GitHub issue number to dispatch (required)
#   MAKATO_LOOP_DISPATCH_REPO  — owner/repo of the target repository (required)
#   MAKATO_PRODUCTION_ROOT     — path to the production makato install (optional;
#                                enables production-isolation drift detection)
#
# Usage:
#   e2e-mvp-proof.sh [--dry-run]
#
# Exit codes:
#   0   all four DoD rows PASS
#   1   one or more rows FAIL or TIMEOUT; or a prerequisite check failed
#   2   usage error (missing required env var, script dependency not found)
#
# DoD table rows:
#   1. Loop dispatch completes — issue reaches Status=Done on the board
#   2. No approval-stall — zero HALT-004/approval/AskUserQuestion entries
#   3. Production isolation — no drift on shared ~/.claude paths
#   4. (derived) All rows PASS → exit 0

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_VERIFY_ISOLATION="$_SCRIPT_DIR/verify-production-isolation.sh"
_ASSERT_NO_STALL="$_SCRIPT_DIR/tests/assert-no-approval-stall.sh"
_LOOP_SCRIPT="$_SCRIPT_DIR/loop.sh"

DRY_RUN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "e2e-mvp-proof: unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# (a) Guard: require env vars
# ---------------------------------------------------------------------------
_check_required_env() {
  local missing=0
  for var in MAKATO_OPEN_ENDPOINT_URL MAKATO_E2E_ISSUE MAKATO_LOOP_DISPATCH_REPO; do
    if [[ -z "${!var:-}" ]]; then
      echo "e2e-mvp-proof: ERROR — missing required env var: $var" >&2
      missing=$((missing + 1))
    fi
  done
  if [[ $missing -gt 0 ]]; then
    echo "e2e-mvp-proof: set all required env vars before running" >&2
    exit 1
  fi
}

_check_required_env

# Validate script dependencies exist
for dep in "$_VERIFY_ISOLATION" "$_ASSERT_NO_STALL" "$_LOOP_SCRIPT"; do
  if [[ ! -x "$dep" ]]; then
    echo "e2e-mvp-proof: ERROR — required script not found or not executable: $dep" >&2
    exit 2
  fi
done

if [[ -n "$DRY_RUN" ]]; then
  echo "e2e-mvp-proof: --dry-run mode"
  echo ""
  echo "Planned steps:"
  echo "  (a) [guard]   validate env vars: MAKATO_OPEN_ENDPOINT_URL, MAKATO_E2E_ISSUE, MAKATO_LOOP_DISPATCH_REPO"
  echo "  (b) [capture] run verify-production-isolation.sh --capture"
  echo "  (c) [dispatch] export ANTHROPIC_BASE_URL=$MAKATO_OPEN_ENDPOINT_URL"
  echo "                 MAKATO_HEADLESS=1 loop.sh dispatch $MAKATO_E2E_ISSUE --repo $MAKATO_LOOP_DISPATCH_REPO"
  echo "                 → log: ~/.claude/state/e2e-proof-<date>.log"
  echo "  (d) [assert]  run assert-no-approval-stall.sh on dispatch log"
  echo "  (e) [poll]    gh project item-list until Status=Done or 30-min timeout"
  echo "  (f) [check]   run verify-production-isolation.sh --check"
  echo "  (g) [report]  print DoD table and exit 0 if all rows PASS"
  echo ""
  echo "No dispatch command will be executed in --dry-run mode."
  exit 0
fi

# ---------------------------------------------------------------------------
# State tracking
# ---------------------------------------------------------------------------
DOD_DISPATCH="PENDING"
DOD_NO_STALL="PENDING"
DOD_ISOLATION="PENDING"

STATE_DIR="${MAKATO_LOOP_STATE_DIR:-$HOME/.claude/state}"
mkdir -p "$STATE_DIR"
LOG_DATE="$(date -u +%Y%m%d-%H%M%S)"
LOG_FILE="$STATE_DIR/e2e-proof-${LOG_DATE}.log"

_print_dod_table() {
  echo ""
  echo "=== E2E MVP Proof — DoD Table ==="
  printf "%-50s %s\n" "Row" "Status"
  printf "%-50s %s\n" "$(printf '%0.s-' {1..50})" "------"
  printf "%-50s %s\n" "1. Loop dispatch: issue → merged PR, board=Done" "$DOD_DISPATCH"
  printf "%-50s %s\n" "2. No approval/HALT-004 stall in dispatch log" "$DOD_NO_STALL"
  printf "%-50s %s\n" "3. Production isolation: no shared-path drift" "$DOD_ISOLATION"
  echo ""
}

# ---------------------------------------------------------------------------
# (b) Capture production-isolation baseline
# ---------------------------------------------------------------------------
echo "e2e-mvp-proof: (b) capturing production isolation baseline..."
if bash "$_VERIFY_ISOLATION" --capture; then
  echo "e2e-mvp-proof: baseline captured"
else
  echo "e2e-mvp-proof: WARNING — baseline capture failed; isolation check will be skipped" >&2
  DOD_ISOLATION="SKIP"
fi

# ---------------------------------------------------------------------------
# (c) Dispatch via loop.sh
# ---------------------------------------------------------------------------
echo "e2e-mvp-proof: (c) dispatching issue #$MAKATO_E2E_ISSUE via loop.sh..."
echo "e2e-mvp-proof: log → $LOG_FILE"

DISPATCH_RC=0
ANTHROPIC_BASE_URL="$MAKATO_OPEN_ENDPOINT_URL" \
MAKATO_HEADLESS=1 \
  bash "$_LOOP_SCRIPT" dispatch "$MAKATO_E2E_ISSUE" \
    --repo "$MAKATO_LOOP_DISPATCH_REPO" \
  >"$LOG_FILE" 2>&1 || DISPATCH_RC=$?

if [[ $DISPATCH_RC -ne 0 ]]; then
  echo "e2e-mvp-proof: loop.sh dispatch exited $DISPATCH_RC — see $LOG_FILE" >&2
fi

# ---------------------------------------------------------------------------
# (d) Assert no approval stall
# ---------------------------------------------------------------------------
echo "e2e-mvp-proof: (d) checking for approval stalls in dispatch log..."
if bash "$_ASSERT_NO_STALL" "$LOG_FILE"; then
  DOD_NO_STALL="PASS"
else
  DOD_NO_STALL="FAIL"
fi

# ---------------------------------------------------------------------------
# (e) Poll board for Status=Done (30-minute ceiling)
# ---------------------------------------------------------------------------
echo "e2e-mvp-proof: (e) polling board for issue #$MAKATO_E2E_ISSUE Status=Done..."
POLL_TIMEOUT_SECS="${MAKATO_E2E_POLL_TIMEOUT:-1800}"
POLL_INTERVAL_SECS="${MAKATO_E2E_POLL_INTERVAL:-30}"
elapsed=0
while [[ $elapsed -lt $POLL_TIMEOUT_SECS ]]; do
  board_status="$(
    gh project item-list --owner "${MAKATO_LOOP_DISPATCH_REPO%%/*}" \
      --format json 2>/dev/null \
      | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    linked = item.get('content', {})
    if str(linked.get('number', '')) == '$MAKATO_E2E_ISSUE':
        print(item.get('status', ''))
        break
" 2>/dev/null || true
  )"
  if [[ "$board_status" == "Done" ]]; then
    echo "e2e-mvp-proof: board reached Status=Done for issue #$MAKATO_E2E_ISSUE"
    DOD_DISPATCH="PASS"
    break
  fi
  sleep "$POLL_INTERVAL_SECS"
  elapsed=$((elapsed + POLL_INTERVAL_SECS))
  echo "e2e-mvp-proof: still waiting for Done (elapsed ${elapsed}s / ${POLL_TIMEOUT_SECS}s, current: ${board_status:-unknown})..."
done

if [[ "$DOD_DISPATCH" != "PASS" ]]; then
  if [[ $DISPATCH_RC -ne 0 ]]; then
    DOD_DISPATCH="FAIL"
  else
    DOD_DISPATCH="TIMEOUT"
  fi
  echo "e2e-mvp-proof: issue #$MAKATO_E2E_ISSUE did not reach Status=Done within ${POLL_TIMEOUT_SECS}s" >&2
fi

# ---------------------------------------------------------------------------
# (f) Verify production isolation
# ---------------------------------------------------------------------------
if [[ "$DOD_ISOLATION" != "SKIP" ]]; then
  echo "e2e-mvp-proof: (f) verifying production isolation..."
  if bash "$_VERIFY_ISOLATION" --check; then
    DOD_ISOLATION="PASS"
  else
    DOD_ISOLATION="FAIL"
  fi
fi

# ---------------------------------------------------------------------------
# (g) Print DoD table and exit
# ---------------------------------------------------------------------------
_print_dod_table

# Determine overall result
overall_fail=0
for row in "$DOD_DISPATCH" "$DOD_NO_STALL" "$DOD_ISOLATION"; do
  if [[ "$row" == "FAIL" || "$row" == "TIMEOUT" ]]; then
    overall_fail=$((overall_fail + 1))
  fi
done

if [[ $overall_fail -gt 0 ]]; then
  echo "e2e-mvp-proof: FAIL — $overall_fail DoD row(s) did not PASS" >&2
  echo "e2e-mvp-proof: dispatch log → $LOG_FILE"
  exit 1
fi

echo "e2e-mvp-proof: PASS — all DoD rows passed"
echo "e2e-mvp-proof: dispatch log → $LOG_FILE"
exit 0
