#!/usr/bin/env bash
# clock-out.sh — Human-session clock-out helper for the makato-orchestrate plugin.
#
# Usage: clock-out.sh <KEY> <ISSUE_NUMBER> <DESCRIPTION>
#
# Appends a lessons_learned entry to workflow-state-<ISSUE_NUMBER>.json via
# workflow-state.sh append-lesson, updates resume_point via workflow-state.sh patch,
# and prints the git commit command the operator should paste. Does NOT commit
# automatically — the operator stays in control of the final commit.
#
# Arguments:
#   KEY          — workflow key, e.g. gap-006 or 602-repo-wide-feat-human-session-clock-in
#   ISSUE_NUMBER — GitHub issue number (positive integer)
#   DESCRIPTION  — free-text description of what was done / what to do next (≤ 200 chars)
#
# Exit codes:
#   0 — success (entries written, commit command printed)
#   1 — missing or invalid arguments, or workflow-state.sh subcommand failure
#
# Environment variables honoured by the underlying workflow-state.sh helper:
#   MAKATO_SPECS_ROOT — override the specs/ scan root (defaults to repo root/specs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WS="$SCRIPT_DIR/../shared/workflow-state.sh"

# ---------------------------------------------------------------------------
# Argument validation — exit 1 when required args are absent or malformed.
# ---------------------------------------------------------------------------
KEY="${1:-}"
ISSUE_NUMBER="${2:-}"
DESCRIPTION="${3:-}"

if [[ -z "$KEY" ]]; then
  echo "clock-out: KEY argument is required" >&2
  echo "Usage: clock-out.sh <KEY> <ISSUE_NUMBER> <DESCRIPTION>" >&2
  exit 1
fi

if [[ -z "$ISSUE_NUMBER" ]]; then
  echo "clock-out: ISSUE_NUMBER argument is required" >&2
  echo "Usage: clock-out.sh <KEY> <ISSUE_NUMBER> <DESCRIPTION>" >&2
  exit 1
fi

if [[ ! "$ISSUE_NUMBER" =~ ^[0-9]+$ ]] || [[ "$ISSUE_NUMBER" -lt 1 ]]; then
  echo "clock-out: ISSUE_NUMBER must be a positive integer (got '$ISSUE_NUMBER')" >&2
  exit 1
fi

if [[ -z "$DESCRIPTION" ]]; then
  echo "clock-out: DESCRIPTION argument is required" >&2
  echo "Usage: clock-out.sh <KEY> <ISSUE_NUMBER> <DESCRIPTION>" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Append a lessons_learned entry.
#    cycle=0, trigger=halt — conventional for human session notes.
# ---------------------------------------------------------------------------
"$WS" append-lesson "$KEY" "$ISSUE_NUMBER" 0 halt "$DESCRIPTION"

# ---------------------------------------------------------------------------
# 2. Update resume_point to the description (truncated at 60 chars) so the
#    next session has a plain-English pointer to where work left off.
# ---------------------------------------------------------------------------
RESUME_POINT="${DESCRIPTION:0:60}"
"$WS" patch "$KEY" "$ISSUE_NUMBER" .resume_point "\"$RESUME_POINT\""

# ---------------------------------------------------------------------------
# 3. Locate the state file and print the commit command.
#    The operator pastes this — clock-out.sh never runs git itself.
# ---------------------------------------------------------------------------
SPECS_ROOT="${MAKATO_SPECS_ROOT:-$REPO_ROOT/specs}"
STATE_FILE="$(ls "$SPECS_ROOT"/${KEY}-*/workflow-state-${ISSUE_NUMBER}.json \
              "$SPECS_ROOT"/${KEY}/workflow-state-${ISSUE_NUMBER}.json \
              2>/dev/null | head -1 || true)"

if [[ -z "$STATE_FILE" ]]; then
  # Fallback: print the conventional path pattern even if we can't resolve it.
  STATE_FILE="specs/${KEY}-*/workflow-state-${ISSUE_NUMBER}.json"
fi

# Make the path relative to REPO_ROOT for the git add command.
REL_STATE_FILE="${STATE_FILE#$REPO_ROOT/}"

echo ""
echo "Clock-out recorded:"
echo "  lessons_learned: appended"
echo "  resume_point:    $RESUME_POINT"
echo ""
echo "Paste this to commit the state file:"
echo ""
echo "  git add $REL_STATE_FILE"
echo "  git commit -m 'chore: session clock-out — update resume_point'"
