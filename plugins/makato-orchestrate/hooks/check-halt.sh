#!/usr/bin/env bash
# check-halt.sh — PreToolUse hook for autonomous mode (GAP-004 / #30).
#
# Fires before every Bash tool call when wired into a consumer repo's
# .claude/settings.json under hooks.PreToolUse. Exits non-zero if
# ~/.claude/HALT exists, blocking the tool call so the PO-agent observes
# HALT-000 at the next outer-loop boundary.
#
# Settings.json wiring (copy into the consumer repo):
# {
#   "matcher": "Bash",
#   "hooks": [{
#     "type": "command",
#     "command": "${CLAUDE_PLUGIN_ROOT}/hooks/check-halt.sh",
#     "blocking": true,
#     "timeout": 5000
#   }]
# }
#
# Environment variables:
#   MAKATO_HALT_FILE       — override default ~/.claude/HALT (e.g. for tests)
#   MAKATO_HALT_DISABLE=1  — emergency bypass; logs the bypass and exits 0.
#                            Reserved for operators on hotfix runs, never set
#                            globally. Every bypass is auditable via the JSONL
#                            line written below.
#
# Why this script is intentionally small:
#   - It runs on EVERY Bash tool call. A 5-line filesystem stat is the right
#     budget. Heavy logic (label polling, budget checks) lives in the
#     kill-switch skill which runs only at outer-loop boundaries.
#   - Failure modes are deliberate: a missing helper is a HALT, not a
#     silent allow. The agent should never produce output that depends on
#     a broken kill-switch.

set -euo pipefail

HALT_FILE="${MAKATO_HALT_FILE:-$HOME/.claude/HALT}"

# Emergency bypass — log and allow.
if [[ "${MAKATO_HALT_DISABLE:-0}" == "1" ]]; then
  printf '{"ts":"%s","skill":"check-halt","step":"bypass","status":"warn","data":{"reason":"MAKATO_HALT_DISABLE=1"}}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >&2
  exit 0
fi

# Steady state — no HALT file, allow the tool call.
if [[ ! -e "$HALT_FILE" ]]; then
  exit 0
fi

# HALT-000 fires. Print a human-readable reason to stderr (surfaced to the
# agent as the tool result) and exit non-zero to block.
REASON_TEXT="(no reason text in HALT file)"
if [[ -s "$HALT_FILE" ]]; then
  REASON_TEXT="$(head -c 500 "$HALT_FILE")"
fi

cat >&2 <<HALT
HALT-000: ~/.claude/HALT file detected — operator-initiated kill-switch.

  Path:   $HALT_FILE
  Reason: $REASON_TEXT

The PO-agent will terminate at the next outer-loop boundary. No
needs-human-review label is applied — HALT-000 is operator-initiated.

To resume:
  rm "$HALT_FILE"
  # re-invoke loop --autonomous <issue>

HALT
exit 1
