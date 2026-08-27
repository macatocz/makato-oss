#!/usr/bin/env bash
# progress-comment.sh — maintain ONE human-readable "live" progress comment on
# the GitHub issue a PO-agent run is driving (issue #… autonomous narration).
#
# WHY THIS EXISTS
# ---------------
# The PO-agent already writes a machine audit trail to specs/<key>-*/*.jsonl,
# but specs/ is gitignored — only the operator sees it, locally. Anyone
# watching the issue on GitHub sees nothing about what the autonomous run is
# doing. This helper mirrors the START / DONE lifecycle of every skill the
# PO-agent dispatches into a single, continuously-edited issue comment, in
# plain English so a non-expert can follow along. Every entry begins with a
# timestamp.
#
# DESIGN
# ------
# - ONE live comment. Its numeric id lives in workflow-state.json under
#   .progress_comment_id (the ONLY new state field). The comment body itself is
#   the source of truth for the narration; state holds just the id, so the
#   narration survives a resume / context-handoff — a fresh session reads the id
#   and re-fetches the body from GitHub before appending.
# - Best-effort, NEVER fatal. Any gh / state failure logs a WARN to stderr,
#   emits a `progress-comment` JSONL row with status "warn", and exits 0. This
#   layer must never block a run or trip a HALT.
# - State is still mutated ONLY through workflow-state.sh. Both the loop's
#   structural pre-dispatch guard and the PO-agent use this helper as a thin
#   caller, so no second workflow-state writer is introduced.
#
# USAGE
#   progress-comment.sh start <KEY> <ISSUE> <REPO> \
#       --skill <s> --agent <a> --input <i> --goal <g>
#   progress-comment.sh done  <KEY> <ISSUE> <REPO> \
#       --skill <s> --result <r> --summary <sum>
#   progress-comment.sh note  <KEY> <ISSUE> <REPO> --text <t>
#
# ENVIRONMENT
#   MAKATO_PROGRESS_COMMENT_DISABLE=1  Disable entirely (no gh, no state write,
#                                      no JSONL). Silent no-op, exit 0.
#   MAKATO_PC_MAX_BODY                 Char threshold before starting a fresh
#                                      follow-up comment (default 60000; GitHub
#                                      hard limit is 65536).
#   MAKATO_PC_GH_STUB                  Test-only: directory backing a fake gh.
#                                      create/get/update operate on files there
#                                      instead of calling the real gh CLI.
#   MAKATO_PC_GH_FAIL                  Test-only: set to 1 to make every fake-gh
#                                      operation fail (exercises best-effort).
set -euo pipefail

SUB="${1:-}"
KEY="${2:-}"
ISSUE="${3:-}"
REPO="${4:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_STATE="$SCRIPT_DIR/workflow-state.sh"
BUILD_LOG="$SCRIPT_DIR/../../makato-build/shared/build-log.sh"

MAX_BODY="${MAKATO_PC_MAX_BODY:-60000}"

# ---------------------------------------------------------------------------
# ISO-8601 timestamp with milliseconds (UTC). Python over `date +%N` because %N
# is broken on macOS — matches workflow-state.sh / loop.sh house style.
# ---------------------------------------------------------------------------
_now() {
  python3 -c "from datetime import datetime, timezone
n = datetime.now(timezone.utc)
print(n.strftime('%Y-%m-%dT%H:%M:%S.') + f'{n.microsecond // 1000:03d}Z')"
}

# Short HH:MM:SS clock for the per-entry prefix (the human-facing timestamp).
_clock() {
  python3 -c "from datetime import datetime, timezone
print(datetime.now(timezone.utc).strftime('%H:%M:%S'))"
}

# ---------------------------------------------------------------------------
# JSONL audit — best-effort, mirrors the machine trail. Never fails the caller.
# ---------------------------------------------------------------------------
_log() {
  local status="$1" event="$2" detail="$3"
  [[ -x "$BUILD_LOG" ]] || return 0
  local ts entry
  ts="$(_now)"
  entry="$(jq -cn \
    --arg ts "$ts" --argjson issue "${ISSUE:-0}" \
    --arg status "$status" --arg event "$event" --arg detail "$detail" \
    '{ts:$ts, skill:"progress-comment", issue:$issue, step:"progress-comment",
      status:$status, data:{event:$event, detail:$detail}}' 2>/dev/null)" || return 0
  bash "$BUILD_LOG" "$KEY" "$entry" >/dev/null 2>&1 || true
}

_warn() {
  echo "progress-comment: WARN — $1" >&2
  _log warn "${2:-error}" "$1"
}

# ---------------------------------------------------------------------------
# gh abstraction. Real path uses the gh CLI; test path (MAKATO_PC_GH_STUB set)
# backs each operation with a flat file so smoke tests run fully offline.
# Each function echoes on success and returns non-zero on failure.
# ---------------------------------------------------------------------------
_gh_create() {
  # stdin: body. echo: new comment id.
  local body; body="$(cat)"
  if [[ -n "${MAKATO_PC_GH_STUB:-}" ]]; then
    [[ "${MAKATO_PC_GH_FAIL:-}" == "1" ]] && return 1
    local counter id
    counter="$MAKATO_PC_GH_STUB/.counter"
    id=$(( $(cat "$counter" 2>/dev/null || echo 1000) + 1 ))
    echo "$id" > "$counter"
    printf '%s' "$body" > "$MAKATO_PC_GH_STUB/comment-$id.md"
    echo "$id"
    return 0
  fi
  printf '%s' "$body" | gh api "repos/$REPO/issues/$ISSUE/comments" \
    -F body=@- --jq '.id' 2>/dev/null
}

_gh_get_body() {
  # $1: comment id. echo: current body.
  local id="$1"
  if [[ -n "${MAKATO_PC_GH_STUB:-}" ]]; then
    [[ "${MAKATO_PC_GH_FAIL:-}" == "1" ]] && return 1
    [[ -f "$MAKATO_PC_GH_STUB/comment-$id.md" ]] || return 1
    cat "$MAKATO_PC_GH_STUB/comment-$id.md"
    return 0
  fi
  gh api "repos/$REPO/issues/comments/$id" --jq '.body' 2>/dev/null
}

_gh_update() {
  # $1: comment id; stdin: full new body. echo: id on success.
  local id="$1" body; body="$(cat)"
  if [[ -n "${MAKATO_PC_GH_STUB:-}" ]]; then
    [[ "${MAKATO_PC_GH_FAIL:-}" == "1" ]] && return 1
    [[ -f "$MAKATO_PC_GH_STUB/comment-$id.md" ]] || return 1
    printf '%s' "$body" > "$MAKATO_PC_GH_STUB/comment-$id.md"
    echo "$id"
    return 0
  fi
  printf '%s' "$body" | gh api --method PATCH \
    "repos/$REPO/issues/comments/$id" -F body=@- --jq '.id' >/dev/null 2>&1 \
    && echo "$id"
}

# ---------------------------------------------------------------------------
# State access — read/write .progress_comment_id via workflow-state.sh only.
# ---------------------------------------------------------------------------
_read_comment_id() {
  [[ -x "$WORKFLOW_STATE" ]] || { echo ""; return 0; }
  bash "$WORKFLOW_STATE" read "$KEY" "$ISSUE" 2>/dev/null \
    | jq -r '.progress_comment_id // empty' 2>/dev/null || echo ""
}

_save_comment_id() {
  local id="$1"
  [[ -x "$WORKFLOW_STATE" ]] || return 0
  bash "$WORKFLOW_STATE" patch "$KEY" "$ISSUE" .progress_comment_id "$id" \
    >/dev/null 2>&1 || _warn "could not persist progress_comment_id=$id to state" save-id
}

# ---------------------------------------------------------------------------
# The header written once when the live comment is first created.
# ---------------------------------------------------------------------------
_header() {
  printf '### 🤖 Autonomous progress (issue #%s)\n\n' "$ISSUE"
  printf '_This comment is updated continuously by the autonomous agent. Every entry begins with a timestamp._\n'
}

# ---------------------------------------------------------------------------
# Core: append $ENTRY_BLOCK to the live comment, creating it (with header) when
# no id exists yet, or starting a fresh follow-up comment when the body would
# exceed MAX_BODY. Always best-effort.
# ENTRY_BLOCK is passed as $1.
# ---------------------------------------------------------------------------
_publish() {
  local entry="$1"
  local id new_id current combined

  id="$(_read_comment_id)"

  # No live comment yet → create one with the header + this first entry.
  if [[ -z "$id" ]]; then
    new_id="$(printf '%s\n\n%s\n' "$(_header)" "$entry" | _gh_create)" || {
      _warn "failed to create progress comment on issue #$ISSUE" create
      return 0
    }
    _save_comment_id "$new_id"
    _log ok create "created live comment id=$new_id"
    return 0
  fi

  # Live comment exists → fetch current body and append. If the fetch fails we
  # would rather start a fresh follow-up comment than silently drop the entry.
  current="$(_gh_get_body "$id")" || {
    _warn "could not fetch comment id=$id — starting a fresh follow-up comment" refetch
    new_id="$(printf '%s\n\n%s\n' "$(_header)" "$entry" | _gh_create)" || {
      _warn "fallback create also failed on issue #$ISSUE" create
      return 0
    }
    _save_comment_id "$new_id"
    _log warn refetch-fallback "started follow-up comment id=$new_id"
    return 0
  }

  combined="$(printf '%s\n%s\n' "$current" "$entry")"

  # Comment nearing GitHub's 65536-char ceiling → roll over to a fresh comment.
  if (( ${#combined} > MAX_BODY )); then
    new_id="$(printf '%s\n\n_(continued from the previous comment)_\n\n%s\n' \
      "$(_header)" "$entry" | _gh_create)" || {
      _warn "rollover create failed on issue #$ISSUE" create
      return 0
    }
    _save_comment_id "$new_id"
    _log ok rollover "rolled over to follow-up comment id=$new_id (prev $id full)"
    return 0
  fi

  printf '%s' "$combined" | _gh_update "$id" >/dev/null || {
    _warn "failed to update comment id=$id on issue #$ISSUE" update
    return 0
  }
  _log ok append "appended entry to comment id=$id"
}

# ---------------------------------------------------------------------------
# Flag parsing for the three subcommands (shift past the 4 positionals first).
# ---------------------------------------------------------------------------
_require_positionals() {
  if [[ -z "$KEY" || -z "$ISSUE" || -z "$REPO" ]]; then
    echo "progress-comment: usage: $SUB <KEY> <ISSUE> <REPO> [flags]" >&2
    exit 2
  fi
}

# Early opt-out — a full, silent no-op.
if [[ "${MAKATO_PROGRESS_COMMENT_DISABLE:-}" == "1" ]]; then
  exit 0
fi

case "$SUB" in
  start)
    _require_positionals
    shift 4 || true
    SKILL="" AGENT="" INPUT="" GOAL=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --skill) SKILL="$2"; shift 2 ;;
        --agent) AGENT="$2"; shift 2 ;;
        --input) INPUT="$2"; shift 2 ;;
        --goal)  GOAL="$2";  shift 2 ;;
        *) shift ;;
      esac
    done
    CLOCK="$(_clock)"
    AGENT_LINE="po-agent"
    [[ -n "$AGENT" ]] && AGENT_LINE="po-agent → $AGENT"
    ENTRY="$(printf -- '- %s | START: %s\n  input: %s\n  agent: %s\n  GOAL: %s' \
      "$CLOCK" "${SKILL:-not specified}" "${INPUT:-not specified}" "$AGENT_LINE" "${GOAL:-not specified}")"
    _publish "$ENTRY"
    ;;

  done)
    _require_positionals
    shift 4 || true
    SKILL="" RESULT="" SUMMARY=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --skill)   SKILL="$2";   shift 2 ;;
        --result)  RESULT="$2";  shift 2 ;;
        --summary) SUMMARY="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    CLOCK="$(_clock)"
    ENTRY="$(printf -- '- %s | DONE: %s\n  result: %s\n  summary: %s' \
      "$CLOCK" "${SKILL:-not specified}" "${RESULT:-not specified}" "${SUMMARY:-not specified}")"
    _publish "$ENTRY"
    ;;

  note)
    _require_positionals
    shift 4 || true
    TEXT=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --text) TEXT="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    CLOCK="$(_clock)"
    ENTRY="$(printf -- '- %s | %s' "$CLOCK" "${TEXT:-not specified}")"
    _publish "$ENTRY"
    ;;

  *)
    echo "progress-comment: unknown subcommand '$SUB' (expected start|done|note)" >&2
    exit 2
    ;;
esac

exit 0
