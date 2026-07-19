#!/usr/bin/env bash
# context-handoff.sh — checkpoint, summarise, self-restart sequence for the
# HALT-007B proactive-handoff path (GAP-004 / #30).
#
# Lifecycle:
#   1. CHECK    — read workflow-state.json, compare the per-session context
#                 delta (budget_consumed_tokens - session_baseline_tokens)
#                 against context_warn_tokens. No-op if below threshold. The
#                 delta (not the cumulative total) is what gates HALT-007B so a
#                 resumed session starts its context budget fresh (#281).
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
#   context-handoff.sh check <KEY> <ISSUE_NUMBER>
#     Evaluate threshold. Exit 0 = no handoff needed.
#                          Exit 2 = handoff initiated (HANDOFF status).
#                          Exit 1 = handoff failed (HALT-007 fallback).
#
#   context-handoff.sh emit-resume <KEY> <ISSUE_NUMBER>
#     (Internal) Write .claude/state/resume-{KEY}.sh. Idempotent.
#
#   context-handoff.sh check-pid <KEY> <ISSUE_NUMBER>
#     Liveness watchdog for a HALT-007B handoff (#284). No-op unless the state
#     shows an in-flight handoff (handoff_reason == "context_ceiling" AND
#     spawned_pid set). If the resumed session has acknowledged startup
#     (resume_ack fresher than the latest HALT-007B audit entry) the PID is
#     cleared and the check passes. Otherwise, if the PID is dead OR
#     MAKATO_HANDOFF_ACK_TIMEOUT seconds have elapsed since the handoff with no
#     ack, the HALT-007 fallback fires (restart_failed=true, needs-human-review
#     applied directly — the kill-switch poller died with the old session).
#     Exit 0 = healthy / still waiting / nothing pending. Exit 1 = fallback fired.
#
# Environment variables:
#   MAKATO_MAX_HANDOFFS         — cap on session_count (default 5).
#   MAKATO_CLAUDE_BIN           — path to the claude binary (default: `claude`
#                                 on PATH). Tests set this to a stub script.
#   MAKATO_HANDOFF_ACK_TIMEOUT  — seconds check-pid waits for the resumed
#                                 session to write resume_ack before firing the
#                                 HALT-007 fallback (default 120). A dead PID
#                                 short-circuits this wait — the fallback fires
#                                 immediately regardless of the timeout.
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
SUBCMD="${1:?subcommand required: check|emit-resume|check-pid}"
KEY="${2:?key required}"
ISSUE_NUMBER="${3:?issue_number required (per-issue state file, #173)}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
WS="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"
STATE_DIR="$REPO_ROOT/.claude/state"
RESUME_SCRIPT="$STATE_DIR/resume-${KEY}-${ISSUE_NUMBER}.sh"
MAX_HANDOFFS="${MAKATO_MAX_HANDOFFS:-5}"
CLAUDE_BIN="${MAKATO_CLAUDE_BIN:-claude}"
ACK_TIMEOUT="${MAKATO_HANDOFF_ACK_TIMEOUT:-120}"

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
# Convert an ISO-8601 (millisecond, UTC) timestamp to a Unix epoch integer,
# or print nothing on parse failure. Mirrors loop.sh:_reap_epoch_of_iso — a
# handful of state timestamps must be compared as epochs (handoff age, ack
# freshness) and macOS `date` lacks GNU `-d`, so python3 is the portable path.
# Args: <iso-8601-string>
# ---------------------------------------------------------------------------
_epoch_of_iso() {
  local iso="$1"
  [[ -n "$iso" && "$iso" != "null" ]] || return 0
  python3 -c "import sys,datetime
try:
    s=sys.argv[1].replace('Z','+00:00')
    print(int(datetime.datetime.fromisoformat(s).timestamp()))
except Exception:
    pass" "$iso" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Read a single field from workflow-state.json via jq.
# Args: <jq-path>
# ---------------------------------------------------------------------------
_state_field() {
  "$WS" read "$KEY" "$ISSUE_NUMBER" | jq -r "$1"
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
  "$WS" append-halt "$KEY" "$ISSUE_NUMBER" "$code" "$data"
}

# ---------------------------------------------------------------------------
# emit-resume — write the resume script. Idempotent.
# ---------------------------------------------------------------------------
_emit_resume() {
  local issue
  issue="$(_state_field '.issue_number')"
  local now
  now="$(_now)"

  # #467: detect a type:change run by the presence of change-state-<N>.json
  # under any specs/ subdirectory. Filesystem check — offline-safe, no gh call,
  # state-as-truth. The file was written by makato-change:orchestrate Step 0.5
  # well before this handoff fires, so the detection is reliable.
  local change_state_file="" glob_match
  for glob_match in "$REPO_ROOT"/specs/*/change-state-"${issue}".json; do
    [[ -f "$glob_match" ]] && { change_state_file="$glob_match"; break; }
  done

  # Recover WORKTREE_PATH so the resumed change session re-attaches to its
  # isolated worktree rather than committing to the ambient checkout (#467).
  local worktree_path=""
  if [[ -n "$change_state_file" ]]; then
    worktree_path="$(jq -r '.worktree_path // ""' "$change_state_file" 2>/dev/null || true)"
  fi

  if [[ -n "$change_state_file" ]]; then
    # type:change resume — dispatch makato-change:orchestrate, NOT po-agent.
    cat > "$RESUME_SCRIPT" <<EOF
#!/usr/bin/env bash
# Auto-generated by context-handoff.sh on $now
# Resume makato-change:orchestrate for issue #$issue after a HALT-007B handoff.
# Idempotent: if workflow-state.json shows the run is already complete, this
# script exits 0 without re-dispatching.
set -euo pipefail

KEY="$KEY"
ISSUE="$issue"
WORKTREE_PATH="$worktree_path"

STATE_PHASE="\$( "$WS" read "\$KEY" "\$ISSUE" 2>/dev/null | jq -r '.current_phase // "null"')"
if [[ "\$STATE_PHASE" == "done" ]]; then
  echo "resume-\$KEY-\$ISSUE: run already complete (current_phase=done) — no-op" >&2
  exit 0
fi

exec env MAKATO_HEADLESS=1 WORKTREE_PATH="\$WORKTREE_PATH" "$CLAUDE_BIN" --dangerously-skip-permissions --resume "\$KEY" -p "Use the Skill tool to invoke the makato-change:orchestrate skill with args '\$KEY --autonomous'. Context: ISSUE_NUMBER=\$ISSUE ISSUE_KEY=\$KEY WORKTREE_PATH=\$WORKTREE_PATH REPO_ROOT=$REPO_ROOT. MAKATO_HEADLESS=1 is already exported. Resume from the current phase recorded in change-state — do NOT restart from analyze, and perform all edits/commits inside WORKTREE_PATH. Return the skill's final R1 envelope verbatim."
EOF
  else
    # Default (non-change issue) — po-agent resume, byte-for-byte unchanged.
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
STATE_PHASE="\$( "$WS" read "\$KEY" "\$ISSUE" 2>/dev/null | jq -r '.current_phase // "null"')"
if [[ "\$STATE_PHASE" == "done" ]]; then
  echo "resume-\$KEY-\$ISSUE: run already complete (current_phase=done) — no-op" >&2
  exit 0
fi

exec env MAKATO_HEADLESS=1 "$CLAUDE_BIN" --dangerously-skip-permissions --resume "\$KEY" -p "Use the Task tool to dispatch the makato-orchestrate:po-agent subagent to resume driving GitHub issue #\$ISSUE to a merged PR. The po-agent owns the outer loop, workflow-state, and all makato-build --autonomous dispatch; do not invoke makato-build or makato-plan skills directly from this session. Return the po-agent's final R1 envelope verbatim."
EOF
  fi
  chmod +x "$RESUME_SCRIPT"
}

# ---------------------------------------------------------------------------
# Fallback to HALT-007 (cost-control). Sets restart_failed=true,
# applies needs-human-review tag conceptually (kill-switch skill carries
# the actual gh CLI invocation), exits 1.
# ---------------------------------------------------------------------------
_halt_007_fallback() {
  local reason="$1"
  "$WS" patch "$KEY" "$ISSUE_NUMBER" '.restart_failed' 'true'
  _append_halt_audit "HALT-007" "$(jq -n \
    --arg reason "$reason" \
    '{trigger: "context-handoff-fallback", reason: $reason, retryable: false, origin: "human"}')"
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
  # Single state read; extract all fields from the same payload to avoid
  # separate `workflow-state.sh read` subprocess chains per check.
  local state
  state="$("$WS" read "$KEY" "$ISSUE_NUMBER")"
  local consumed baseline warn count summary resume_point
  consumed="$(jq -r '.budget_consumed_tokens'          <<<"$state")"
  # session_baseline_tokens is optional for in-flight state files predating
  # #281 — default to 0 so those runs evaluate against the cumulative total
  # exactly as before (no worse than pre-fix behaviour).
  baseline="$(jq -r '.session_baseline_tokens // 0'    <<<"$state")"
  warn="$(jq    -r '.context_warn_tokens'              <<<"$state")"
  count="$(jq   -r '.session_count'                    <<<"$state")"
  summary="$(jq -r '.session_summary // ""'            <<<"$state")"
  resume_point="$(jq -r '.resume_point // ""'          <<<"$state")"

  # HALT-007B is a per-SESSION context-window gate, not a cumulative-cost gate
  # (#281). Evaluate the context pressure accumulated since this session began
  # — the delta consumed-since-baseline — rather than the lifetime cumulative
  # total. Without this, a resumed session inherits a budget_consumed_tokens
  # already past the threshold and re-hands-off on its first boundary, storming
  # through MAKATO_MAX_HANDOFFS. The cumulative counter stays untouched so the
  # HALT-007 daily/per-task COST ceilings keep evaluating the true total.
  local session_delta=$(( consumed - baseline ))
  (( session_delta < 0 )) && session_delta=0

  # Below threshold — nothing to do.
  if (( session_delta < warn )); then
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

  # Bump session_count, set handoff_reason, and advance session_baseline_tokens
  # to the current cumulative consumption in a single state mutation so the file
  # is never observable with one field bumped and another unset. Advancing the
  # baseline is the #281 fix: the resumed session then measures its own context
  # pressure from zero (delta = consumed - baseline), instead of inheriting a
  # delta already past the threshold and re-handing-off immediately.
  local merged
  merged="$(jq --argjson c "$((count + 1))" \
    --argjson b "$consumed" \
    '. + {session_count: $c, handoff_reason: "context_ceiling", session_baseline_tokens: $b}' \
    <<<"$state")"
  "$WS" write "$KEY" "$ISSUE_NUMBER" "$merged"

  if [[ -z "$resume_point" || "$resume_point" == "null" ]]; then
    resume_point="unknown"
  fi

  _append_halt_audit "HALT-007B" "$(jq -n \
    --argjson consumed "$consumed" \
    --argjson baseline "$consumed" \
    --argjson delta "$session_delta" \
    --argjson warn "$warn" \
    --argjson session "$((count + 1))" \
    --arg resume "$resume_point" \
    '{
      budget_consumed_tokens: $consumed,
      session_baseline_tokens: $baseline,
      session_delta_tokens: $delta,
      context_warn_tokens: $warn,
      session_count: $session,
      resume_point: $resume,
      retryable: true,
      origin: "auto"
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
  #
  # #284: capture $! into spawned_pid and persist it to workflow-state BEFORE
  # disown, so the check-pid liveness watchdog can probe the subprocess with
  # `kill -0`. The compound `... & disown $!` one-liner discarded the PID —
  # a post-fork crash then vanished silently with no way to detect it. The
  # split keeps disown (SIGHUP protection) but records the PID first; the
  # window between fork and disown is a few shell ops and never sends SIGHUP.
  nohup bash "$RESUME_SCRIPT" >/dev/null 2>&1 &
  local spawned_pid=$!
  "$WS" patch "$KEY" "$ISSUE_NUMBER" '.spawned_pid' "$spawned_pid"
  disown "$spawned_pid" 2>/dev/null || true

  echo "context-handoff: HANDOFF (session_count=$((count + 1)), spawned_pid=$spawned_pid, resume script: $RESUME_SCRIPT)" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# check-pid — liveness watchdog for an in-flight HALT-007B handoff (#284).
#
# The HALT-007B self-restart forks a detached subprocess and exits the old
# session. Nothing supervised that subprocess: if it died after the fork
# (corrupt --resume session, resume-script bug, early crash), the issue was
# abandoned silently — handoff_reason stayed "context_ceiling", no PR, no
# label, no page. This watchdog closes that gap. The loop calls it once per
# poll tick for every state file with a pending handoff.
#
# Decision tree (mirrors the design in specs/284-…/design.md):
#   1. No pending handoff (handoff_reason != context_ceiling OR spawned_pid
#      null/absent) → exit 0. Nothing to supervise.
#   2. resume_ack present AND fresher than the latest HALT-007B audit entry →
#      the resumed session reached its resume path. Clear spawned_pid (so we
#      don't re-probe a long-dead PID on later ticks) → exit 0.
#      A stale ack (older than the handoff) is ignored — it belongs to a prior
#      handoff cycle.
#   3. PID is dead (`kill -0` fails) AND no fresh ack → the subprocess died
#      after fork. Fire the HALT-007 fallback immediately (no timeout wait).
#   4. PID alive, no fresh ack, handoff age < ACK_TIMEOUT → still booting.
#      exit 0 (the next tick re-checks).
#   5. PID alive, no fresh ack, handoff age >= ACK_TIMEOUT → the subprocess is
#      running but never reached the po-agent resume path. Fire the fallback.
#
# Exit codes: 0 = healthy / waiting / nothing pending; 1 = HALT-007 fallback.
# ---------------------------------------------------------------------------
_check_pid() {
  local state
  state="$("$WS" read "$KEY" "$ISSUE_NUMBER")"

  local handoff_reason spawned_pid resume_ack
  handoff_reason="$(jq -r '.handoff_reason // "null"' <<<"$state")"
  spawned_pid="$(jq   -r '.spawned_pid // "null"'    <<<"$state")"
  resume_ack="$(jq    -r '.resume_ack // "null"'     <<<"$state")"

  # (1) No pending handoff to supervise.
  if [[ "$handoff_reason" != "context_ceiling" || "$spawned_pid" == "null" || -z "$spawned_pid" ]]; then
    exit 0
  fi

  # Timestamp of the most recent HALT-007B audit entry — the moment the
  # handoff fired. Both the ack-freshness test and the age test key off it.
  local halt_ts halt_epoch
  halt_ts="$(jq -r '[.halt_audit[] | select(.code == "HALT-007B")] | last | .ts // ""' <<<"$state")"
  halt_epoch="$(_epoch_of_iso "$halt_ts")"

  # (2) Fresh ack → proof of life. Clear spawned_pid and pass.
  if [[ "$resume_ack" != "null" && -n "$resume_ack" ]]; then
    local ack_epoch
    ack_epoch="$(_epoch_of_iso "$resume_ack")"
    # Fresh when we can't compare (no halt_ts) OR ack is at/after the handoff.
    if [[ -z "$halt_epoch" || -z "$ack_epoch" ]] || (( ack_epoch >= halt_epoch )); then
      "$WS" patch "$KEY" "$ISSUE_NUMBER" '.spawned_pid' 'null'
      echo "context-handoff: check-pid #$ISSUE_NUMBER healthy (resume_ack=$resume_ack, pid $spawned_pid cleared)" >&2
      exit 0
    fi
    # else: stale ack from a prior cycle — fall through to liveness checks.
  fi

  # (3) Dead PID with no fresh ack → subprocess died after fork. Immediate fail.
  if ! kill -0 "$spawned_pid" 2>/dev/null; then
    _check_pid_fallback "resume subprocess pid $spawned_pid is dead and no resume_ack was written — HALT-007B restart died after fork"
  fi

  # (4)/(5) PID alive, no fresh ack — gate on handoff age vs ACK_TIMEOUT.
  local now_epoch age
  now_epoch="$(_epoch_of_iso "$(_now)")"
  if [[ -n "$halt_epoch" && -n "$now_epoch" ]]; then
    age=$(( now_epoch - halt_epoch ))
    (( age < 0 )) && age=0
    if (( age < ACK_TIMEOUT )); then
      echo "context-handoff: check-pid #$ISSUE_NUMBER waiting (pid $spawned_pid alive, ${age}s < ${ACK_TIMEOUT}s ack timeout)" >&2
      exit 0
    fi
    _check_pid_fallback "resume subprocess pid $spawned_pid alive but no resume_ack within ${ACK_TIMEOUT}s (handoff age ${age}s) — resumed session never reached the po-agent resume path"
  fi

  # No parseable handoff timestamp — cannot compute age. Be conservative:
  # the PID is alive, so assume it is still booting rather than false-firing.
  echo "context-handoff: check-pid #$ISSUE_NUMBER waiting (pid $spawned_pid alive, no parseable HALT-007B timestamp)" >&2
  exit 0
}

# ---------------------------------------------------------------------------
# check-pid fallback — the liveness watchdog's HALT-007 exit. Distinct from
# _halt_007_fallback (the in-session cost fallback) because the kill-switch
# poller that normally applies needs-human-review died with the old session:
# check-pid must apply the label itself. Routes to HALT-007, NOT HALT-007B —
# the subprocess did not survive, so automatic recovery failed and human
# intervention is needed (NEVER 9 is not violated — see halt-conditions.md).
# ---------------------------------------------------------------------------
_check_pid_fallback() {
  local reason="$1"
  local repo
  repo="$("$WS" read "$KEY" "$ISSUE_NUMBER" | jq -r '.repo // empty')"
  # Clear spawned_pid FIRST so subsequent check-pid calls short-circuit at
  # guard (1) (spawned_pid == null → nothing to supervise → exit 0) instead of
  # re-firing this fallback on every loop tick. Without this, each poll re-reads
  # handoff_reason=context_ceiling + a still-set spawned_pid, re-enters the
  # dead/timeout branch, and appends a duplicate HALT-007 audit entry + a
  # redundant gh label call — indefinitely, until an operator clears the state.
  # handoff_reason stays set (only the resumed po-agent clears it) — that is
  # correct; the pid is the re-entry key, not the reason.
  "$WS" patch "$KEY" "$ISSUE_NUMBER" '.spawned_pid' 'null'
  # MAKATO_HANDOFF_SKIP_LABEL=1 suppresses the gh call — used by the smoke
  # tests so the fallback path stays fully offline. Production leaves it unset.
  if [[ -n "$repo" && "${MAKATO_HANDOFF_SKIP_LABEL:-0}" != "1" ]]; then
    gh issue edit "$ISSUE_NUMBER" --repo "$repo" --add-label "needs-human-review" >/dev/null 2>&1 \
      || echo "context-handoff: WARN — could not apply needs-human-review to #$ISSUE_NUMBER (fallback continues)" >&2
  fi
  _halt_007_fallback "$reason"
}

case "$SUBCMD" in
  check)        _check ;;
  check-pid)    _check_pid ;;
  emit-resume)  _emit_resume ;;
  *)
    echo "context-handoff: unknown subcommand '$SUBCMD'. Valid: check|check-pid|emit-resume" >&2
    exit 1
    ;;
esac
