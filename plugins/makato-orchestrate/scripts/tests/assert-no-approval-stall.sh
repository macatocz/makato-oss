#!/usr/bin/env bash
# assert-no-approval-stall.sh — scan a dispatch log for approval-stall signals.
#
# Used by e2e-mvp-proof.sh (Task 4) to assert the E2E acceptance criterion:
# "No approval-prompt / HALT-004 entry appears in the loop log for the run
# (sub-agents included)."
#
# Can also be run stand-alone after any headless dispatch:
#   assert-no-approval-stall.sh ~/.claude/state/e2e-proof-20260811.log
#
# Usage:
#   assert-no-approval-stall.sh <log-file>
#
# Exit codes:
#   0   log is clean — no approval-stall patterns found
#   1   stall signal detected — first matching line is printed to stderr
#   2   usage error (missing or unreadable log file)

set -euo pipefail

LOG_FILE="${1:-}"

if [[ -z "$LOG_FILE" ]]; then
  echo "Usage: $(basename "$0") <log-file>" >&2
  echo "  Scans <log-file> for approval / HALT-004 / AskUserQuestion entries." >&2
  exit 2
fi

if [[ ! -f "$LOG_FILE" ]]; then
  echo "assert-no-approval-stall: ERROR — file not found: $LOG_FILE" >&2
  exit 2
fi

if [[ ! -r "$LOG_FILE" ]]; then
  echo "assert-no-approval-stall: ERROR — file not readable: $LOG_FILE" >&2
  exit 2
fi

# Patterns that indicate an approval stall or a blocked headless dispatch.
# Case-insensitive match. Covers:
#   - HALT-004 (AskUserQuestion)
#   - Literal "approval" (approval-prompt log entries)
#   - "AskUserQuestion" (claude code tool name, case-sensitive variant)
STALL_PATTERN="approval|HALT-004|AskUserQuestion"

first_match="$(grep -im 1 -E "$STALL_PATTERN" "$LOG_FILE" 2>/dev/null || true)"

if [[ -n "$first_match" ]]; then
  echo "assert-no-approval-stall: FAIL — stall signal detected in $LOG_FILE" >&2
  echo "  First match: $first_match" >&2
  exit 1
fi

echo "assert-no-approval-stall: PASS — no approval/HALT-004/AskUserQuestion entry in $(basename "$LOG_FILE")"
exit 0
