#!/usr/bin/env bash
# context-handoff.sh — checkpoint, summarise, self-restart sequence for the
# HALT-007B proactive-handoff path (GAP-004 / #30).
#
# Lifecycle:
#   1. CHECK    — read workflow-state.json, compare budget_consumed_tokens
#                 against context_warn_tokens. No-op if below threshold.
#   2. CAP      — if session_count >= MAKATO_MAX_HANDOFFS (default 5), fall
#                 through to HALT-007 fallback (NEVER 8).
#   3. CHECKPOINT — patch workflow-state.json with resume_point,
#                   handoff_reason: "context_ceiling", increment
#                   session_count, append halt_audit entry for HALT-007B.
#   4. SUMMARISE — placeholder (the actual dispatch of context-summariser
#                  is owned by the PO-agent — see "Why this script doesn't
#                  call Claude" below).
#   5. EMIT     — write .claude/state/resume-{KEY}.sh with the exact
#                 re-invocation command. The file is idempotent: re-running
#                 it must detect resume_point already consumed and no-op.
#   6. RESTART  — execute resume-{KEY}.sh detached. On success, exit 0
#                 (status HANDOFF — NOT a HALT). On failure, set
#                 restart_failed: true and fall through to HALT-007.
#
# Usage:
#   context-handoff.sh check <KEY>
#     Evaluate threshold. Exit 0 = no handoff needed.
#                          Exit 2 = handoff initiated (HANDOFF status).
#                          Exit 1 = handoff failed (HALT-007 fallback).
#
#   context-handoff.sh emit-resume <KEY>
#     (Internal) Write .claude/state/resume-{KEY}.sh. Idempotent.
#
# Environment variables:
#   MAKATO_MAX_HANDOFFS         — cap on session_count (default 5).
#   MAKATO_CLAUDE_BIN           — path to the claude binary (default: `claude`
#                                 on PATH). Tests set this to a stub script.
#   MAKATO_HANDOFF_DISABLE=1    — short-circuit: never initiate handoff.
#                                 Threshold checks still print, but no
#                                 restart is attempted. Reserved for tests
#                                 and for the rare operator who wants to
#                                 force HALT-007 instead of handoff.
#   MAKATO_HANDOFF_DRY_RUN=1    — perform all state mutations and emit
#                                 resume-{KEY}.sh, but DO NOT execute the
#                                 detached restart subprocess. Tests use
#                                 this to verify state without forking.
#
# Why this script doesn't call Claude:
#   Dispatching the context-summariser sub-agent requires the Task tool
#   (or claude --print), which is a Claude harness primitive — not a
#   shell concern. The PO-agent does the dispatch and writes the result
#   to workflow-state.json BEFORE invoking this script. By the time
#   `check` runs, session_summary is already populated. This keeps the
#   shell logic deterministic and unit-testable without a Claude binary.

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
SUBCMD="${1:?subcommand required: check|emit-resume}"
KEY="${2:?key required}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
WS="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"
STATE_DIR="$REPO_ROOT/.claude/state"
RESUME_SCRIPT="$STATE_DIR/resume-${KEY}.sh"
MAX_HANDOFFS="${MAKATO_MAX_HANDOFFS:-5}"
CLAUDE_BIN="${MAKATO_CLAUDE_BIN:-claude}"

mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------------------
# ISO-8601 timestamp with milliseconds (UTC). Matches workflow-state.sh.
# ---------------------------------------------------------------------------
_now() {
  python3 -c "from datetime import datetime, timezone
n = datetime.now(timezone.utc)
print(n.strftime('%Y-%m-%dT%H:%M:%S.') + f'{n.microsecond // 1000:03d}Z')"
}

# ---------------------------------------------------------------------------
# Read a single field from workflow-state.json via jq.
# Args: <jq-path>
# ---------------------------------------------------------------------------
_state_field() {
  "$WS" read "$KEY" | jq -r "$1"
}

# ---------------------------------------------------------------------------
# Append a halt_audit entry via the canonical workflow-state.sh subcommand.
# Args:
#   $1 — HALT code (e.g. "HALT-007B")
#   $2 — JSON object (data payload)
# Note: the optional pre-read state JSON parameter was removed when this
# function delegated to `workflow-state.sh append-halt` — the subcommand
# reads + patches in a single shelled-out call (with schema validation),
# making the caller's pre-read optimisation unnecessary.
# ---------------------------------------------------------------------------
_append_halt_audit() {
  local code="$1"
  local data="$2"
  "$WS" append-halt "$KEY" "$code" "$data"
}

# ---------------------------------------------------------------------------
# emit-resume — write the resume script. Idempotent.
# ---------------------------------------------------------------------------
_emit_resume() {
  local issue
  issue="$(_state_field '.issue_number')"
  local now
  now="$(_now)"

  cat > "$RESUME_SCRIPT" <<EOF
#!/usr/bin/env bash
# Auto-generated by context-handoff.sh on $now
# Resume the PO-agent loop for issue #$issue after a HALT-007B handoff.
# Idempotent: if workflow-state.json shows the resume_point is already
# consumed (status complete), this script exits 0 without re-dispatching.
set -euo pipefail

KEY="$KEY"
ISSUE="$issue"

# Idempotency guard — reading state via the helper handles missing-file
# (returns {}); jq treats that as null which compares cleanly.
STATE_PHASE="\$( "$WS" read "\$KEY" 2>/dev/null | jq -r '.current_phase // "null"')"
if [[ "\$STATE_PHASE" == "done" ]]; then
  echo "resume-\$KEY: run already complete (current_phase=done) — no-op" >&2
  exit 0
fi

exec env MAKATO_HEADLESS=1 "$CLAUDE_BIN" --dangerously-skip-permissions --resume "\$KEY" -p "Use the Task tool to dispatch the makato-orchestrate:po-agent subagent to resume driving GitHub issue #\$ISSUE to a merged PR. The po-agent owns the outer loop, workflow-state, and all makato-build --autonomous dispatch; do not invoke makato-build or makato-plan skills directly from this session. Return the po-agent's final R1 envelope verbatim."
EOF
  chmod +x "$RESUME_SCRIPT"
}

# ---------------------------------------------------------------------------
# Fallback to HALT-007 (cost-control). Sets restart_failed=true,
# applies needs-human-review tag conceptually (kill-switch skill carries
# the actual gh CLI invocation), exits 1.
# ---------------------------------------------------------------------------
_halt_007_fallback() {
  local reason="$1"
  "$WS" patch "$KEY" '.restart_failed' 'true'
  _append_halt_audit "HALT-007" "$(jq -n \
    --arg reason "$reason" \
    '{trigger: "context-handoff-fallback", reason: $reason}')"
  cat >&2 <<HALT
HALT-007: context-handoff fell back to cost-control HALT.

  Reason: $reason

The kill-switch skill will apply needs-human-review on its next poll.
Operator action required.
HALT
  exit 1
}

# ---------------------------------------------------------------------------
# check — evaluate threshold and dispatch if crossed.
# Exit codes:
#   0 — below threshold, no-op
#   1 — handoff failed (HALT-007 fallback fired)
#   2 — handoff initiated cleanly (status HANDOFF)
# ---------------------------------------------------------------------------
_check() {
  # Single state read; extract all five fields from the same payload to avoid
  # five separate `workflow-state.sh read` subprocess chains per check.
  local state
  state="$("$WS" read "$KEY")"
  local consumed warn count summary resume_point
  consumed="$(jq -r '.budget_consumed_tokens'   <<<"$state")"
  warn="$(jq    -r '.context_warn_tokens'       <<<"$state")"
  count="$(jq   -r '.session_count'             <<<"$state")"
  summary="$(jq -r '.session_summary // ""'     <<<"$state")"
  resume_point="$(jq -r '.resume_point // ""'   <<<"$state")"

  # Below threshold — nothing to do.
  if (( consumed < warn )); then
    exit 0
  fi

  # NEVER 8 — session_count cap.
  if (( count >= MAX_HANDOFFS )); then
    _halt_007_fallback "session_count=$count >= MAKATO_MAX_HANDOFFS=$MAX_HANDOFFS"
  fi

  # Operator opt-out.
  if [[ "${MAKATO_HANDOFF_DISABLE:-0}" == "1" ]]; then
    _halt_007_fallback "MAKATO_HANDOFF_DISABLE=1 — operator disabled handoff"
  fi

  # Confirm session_summary is present — the PO-agent should have
  # populated it before invoking this script. NEVER 6 says we don't
  # paper over contract violations.
  if [[ -z "$summary" || "$summary" == "null" ]]; then
    _halt_007_fallback "session_summary not populated — PO-agent contract violation"
  fi

  # Bump session_count and set handoff_reason in a single state mutation so
  # the file is never observable with one bumped and the other unset.
  local merged
  merged="$(jq --argjson c "$((count + 1))" \
    '. + {session_count: $c, handoff_reason: "context_ceiling"}' \
    <<<"$state")"
  "$WS" write "$KEY" "$merged"

  if [[ -z "$resume_point" || "$resume_point" == "null" ]]; then
    resume_point="unknown"
  fi

  _append_halt_audit "HALT-007B" "$(jq -n \
    --argjson consumed "$consumed" \
    --argjson warn "$warn" \
    --argjson session "$((count + 1))" \
    --arg resume "$resume_point" \
    '{
      budget_consumed_tokens: $consumed,
      context_warn_tokens: $warn,
      session_count: $session,
      resume_point: $resume
    }')"

  # Emit the resume script.
  _emit_resume

  # Verify the claude binary is reachable. Tests use MAKATO_CLAUDE_BIN
  # pointing at a stub script; production uses `claude` on PATH.
  if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1 && ! [[ -x "$CLAUDE_BIN" ]]; then
    _halt_007_fallback "claude binary not found at: $CLAUDE_BIN"
  fi

  # Dry-run mode — do the state mutations but skip the detached restart.
  if [[ "${MAKATO_HANDOFF_DRY_RUN:-0}" == "1" ]]; then
    echo "context-handoff: HANDOFF (dry-run — resume script ready at $RESUME_SCRIPT)" >&2
    exit 2
  fi

  # Detached restart. nohup + & + redirect stdio so this process can exit
  # cleanly. The fresh subprocess inherits the resume command from the
  # emitted script, not from this script's env.
  nohup bash "$RESUME_SCRIPT" >/dev/null 2>&1 &
  disown $! 2>/dev/null || true

  echo "context-handoff: HANDOFF (session_count=$((count + 1)), resume script: $RESUME_SCRIPT)" >&2
  exit 2
}

case "$SUBCMD" in
  check)        _check ;;
  emit-resume)  _emit_resume ;;
  *)
    echo "context-handoff: unknown subcommand '$SUBCMD'. Valid: check|emit-resume" >&2
    exit 1
    ;;
esac
