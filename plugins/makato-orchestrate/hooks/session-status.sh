#!/usr/bin/env bash
# session-status.sh — SessionStart hook for the PO-agent autonomous loop (GAP-014 / #31).
#
# Fires when Claude Code opens a new session. Prints a one-line banner per active
# workflow it discovers in `specs/*/workflow-state.json`, so an operator can see at
# a glance whether a run is in progress, what phase it is in, how much budget is
# consumed, whether a HALT fired, and when state was last updated. Prevents
# duplicate dispatches and surfaces stale runs immediately.
#
# Settings.json wiring (copy into the consumer repo):
# {
#   "matcher": "SessionStart",
#   "hooks": [{
#     "type": "command",
#     "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-status.sh",
#     "timeout": 10000
#   }]
# }
#
# Environment variables:
#   MAKATO_HALT_FILE             — override default ~/.claude/HALT (e.g. for tests)
#   MAKATO_DISABLE_SESSION_STATUS — set to 1 to short-circuit and exit 0 silently
#   MAKATO_SPECS_ROOT            — override the specs/ scan root (defaults to
#                                  `git rev-parse --show-toplevel`/specs)
#   MAKATO_STALE_HOURS           — override stale threshold in hours (default 24)
#
# Why this script is intentionally read-only:
#   - SessionStart fires before any agent prompt. A write here would race with the
#     PO-agent's sole-writer contract on workflow-state.json (AGENTS.md, never-patterns.md).
#   - Failure modes are deliberate: a malformed state file is skipped with a warning
#     to stderr; the hook never aborts the session start.

set -uo pipefail

# Emergency bypass — silent exit (no banner).
if [[ "${MAKATO_DISABLE_SESSION_STATUS:-0}" == "1" ]]; then
  exit 0
fi

HALT_FILE="${MAKATO_HALT_FILE:-$HOME/.claude/HALT}"
STALE_HOURS="${MAKATO_STALE_HOURS:-24}"
# Validate STALE_HOURS is a positive integer — env var injection guard.
if ! [[ "$STALE_HOURS" =~ ^[0-9]+$ ]]; then
  STALE_HOURS="24"
fi

# Resolve specs root. Allow override for tests; otherwise locate via git.
SPECS_ROOT="${MAKATO_SPECS_ROOT:-}"
if [[ -z "$SPECS_ROOT" ]]; then
  if REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    SPECS_ROOT="$REPO_ROOT/specs"
  else
    # Not in a git repo — nothing to scan. Exit silently.
    exit 0
  fi
fi

# Verify jq is available — same dependency as workflow-state.sh.
if ! command -v jq >/dev/null 2>&1; then
  echo "session-status: jq not found, skipping banner" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# HALT-file banner — print first, before any workflow listing.
# ---------------------------------------------------------------------------
if [[ -e "$HALT_FILE" ]]; then
  printf '═══════════════════════════════════════════════════════════════\n'
  printf '⛔  HALT ACTIVE — remove %s to resume\n' "$HALT_FILE"
  printf '═══════════════════════════════════════════════════════════════\n'
fi

# ---------------------------------------------------------------------------
# Scan specs/*/workflow-state-*.json (per-issue layout — #173) with a fallback
# to any legacy specs/*/workflow-state.json that has not been migrated yet.
# Use nullglob so a missing match is empty.
# ---------------------------------------------------------------------------
shopt -s nullglob
state_files=(
  "$SPECS_ROOT"/*/workflow-state-*.json
  "$SPECS_ROOT"/*/workflow-state.json
)
shopt -u nullglob

if [[ ${#state_files[@]} -eq 0 ]]; then
  echo "No active workflows"
  exit 0
fi

# ---------------------------------------------------------------------------
# Compute stale cutoff once. Use python3 (portable across BSD/GNU date).
# ---------------------------------------------------------------------------
cutoff_epoch="$(python3 -c "
import sys
from datetime import datetime, timezone, timedelta
print(int((datetime.now(timezone.utc) - timedelta(hours=int(sys.argv[1]))).timestamp()))
" "$STALE_HOURS")"

echo "Active workflows:"
for state_file in "${state_files[@]}"; do
  # Parse fields. Validate JSON shape with one `jq -c '.'` round-trip; on
  # failure fall back to a readable placeholder rather than aborting.
  if ! payload="$(jq -c '.' "$state_file" 2>/dev/null)"; then
    echo "  ⚠ malformed: $state_file" >&2
    continue
  fi

  # Extract all six fields in one jq invocation (tab-separated) instead of
  # six separate forks per workflow. SessionStart is in the hot path —
  # operators with N active workflows previously paid 6N+ subprocess starts.
  IFS=$'\t' read -r issue phase consumed limit updated_at halt_count last_halt_code <<<"$(jq -r '
    [
      (.issue_number // "?"),
      (.current_phase // "?"),
      (.budget_consumed_tokens // 0),
      (.budget_limit_tokens // 0),
      (.updated_at // ""),
      (.halt_audit | length),
      (if (.halt_audit | length) > 0 then .halt_audit[-1].code else "" end)
    ] | @tsv
  ' <<<"$payload")"

  # Budget percentage — guard against zero limit and non-numeric values.
  if [[ "$limit" =~ ^[0-9]+$ ]] && [[ "$consumed" =~ ^[0-9]+$ ]] && (( limit > 0 )); then
    pct="$(( consumed * 100 / limit ))%"
  else
    pct="?%"
  fi

  # Stale detection — convert updated_at to epoch using GNU `date -d`
  # (linux) or BSD `date -j -f` (macos). Falls back to 0 (= not stale) if
  # neither parses the timestamp, avoiding the per-workflow python3 fork.
  stale_marker=""
  if [[ -n "$updated_at" ]]; then
    if updated_epoch="$(date -d "$updated_at" +%s 2>/dev/null)"; then
      :
    elif updated_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%S' \
        "${updated_at%%.*}" +%s 2>/dev/null)"; then
      :
    else
      updated_epoch=0
    fi
    if (( updated_epoch > 0 && updated_epoch < cutoff_epoch )); then
      stale_marker=" ⚠ STALE — resume: /loop --autonomous $issue"
    fi
  fi

  # HALT marker on per-workflow line.
  halt_marker=""
  if [[ "$halt_count" =~ ^[0-9]+$ ]] && (( halt_count > 0 )) && [[ -n "$last_halt_code" ]]; then
    halt_marker=" | HALT: $last_halt_code"
  fi

  printf '  #%s | phase: %s | budget: %s/%s (%s) | halts: %s | updated: %s%s%s\n' \
    "$issue" "$phase" "$consumed" "$limit" "$pct" "$halt_count" "$updated_at" \
    "$halt_marker" "$stale_marker"
done

exit 0
