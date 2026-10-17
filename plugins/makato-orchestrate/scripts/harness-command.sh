#!/usr/bin/env bash
# harness-command.sh — shared harness-neutral command adapter (Task 3,
# local-openai-gpt-macos-compatibility).
#
# Single seam that every autonomous dispatch, watchdog restart, resume, and
# terminal-result site in loop.sh / functions.sh / context-handoff.sh uses to
# build the permission flag + argument vector for the configured coding-agent
# harness. Before this adapter existed, every call site hardcoded `--yolo`
# (post-#Task-1 rename) with no supported path back to Claude Code's
# `--dangerously-skip-permissions` flag — this file restores that second path
# as an explicit, opt-in mode instead of re-introducing a Claude-only
# fallback.
#
# Supported harnesses:
#   omp    (default) — OMP CLI, permission flag `--yolo`.
#   claude           — Claude Code CLI, permission flag `--dangerously-skip-permissions`.
#
# Mode selection is EXPLICIT ONLY — never inferred from the binary name/path.
# MAKATO_HARNESS_MODE=claude opts into the Claude Code adapter; anything else
# (unset, "omp", or any other value) resolves to the OMP adapter. This is
# what keeps "no selection of Claude when OMP is configured" true: a caller
# cannot accidentally land on the Claude-only flag just because
# MAKATO_HARNESS_BIN happens to contain the word "claude" — only the
# dedicated MAKATO_HARNESS_MODE switch does that.
#
# Usage (sourced — the normal path from loop.sh/functions.sh/context-handoff.sh):
#   source harness-command.sh
#   _harness_mode                                   → prints "omp" | "claude"
#   _harness_permission_flag                        → prints "--yolo" | "--dangerously-skip-permissions"
#   _harness_dispatch_args <prompt> [<resume_session_id>]
#       Populates the global array HARNESS_DISPATCH_ARGS with the full
#       argument vector (permission flag, optional `--resume <id>`, `-p
#       <prompt>`) ready to pass to `"$CLAUDE_BIN" "${HARNESS_DISPATCH_ARGS[@]}"`.
#
# Usage (standalone CLI — shell-stub unit tests exercise this path so command
# construction can be asserted WITHOUT invoking a real model):
#   harness-command.sh mode
#   harness-command.sh permission-flag
#   harness-command.sh dispatch-args <prompt> [<resume_session_id>]
#       Prints each resolved argument on its own line.
#
# Env:
#   MAKATO_HARNESS_BIN   — harness binary name/path (default: omp). Read by
#                          callers to invoke the resolved binary; this file
#                          does not need it directly, only the mode/flag.
#   MAKATO_HARNESS_MODE  — explicit mode override: omp|claude (default: omp).

set -uo pipefail

# ---------------------------------------------------------------------------
# _harness_mode — resolve the active harness mode. Explicit-only: no
# inference from MAKATO_HARNESS_BIN's name/path.
# ---------------------------------------------------------------------------
_harness_mode() {
  case "${MAKATO_HARNESS_MODE:-omp}" in
    claude) printf '%s\n' "claude" ;;
    *) printf '%s\n' "omp" ;;
  esac
}

# ---------------------------------------------------------------------------
# _harness_permission_flag — the single permission flag for the active mode.
#   omp    → --yolo
#   claude → --dangerously-skip-permissions
# ---------------------------------------------------------------------------
_harness_permission_flag() {
  if [[ "$(_harness_mode)" == "claude" ]]; then
    printf '%s\n' "--dangerously-skip-permissions"
  else
    printf '%s\n' "--yolo"
  fi
}

# ---------------------------------------------------------------------------
# _harness_dispatch_args <prompt> [<resume_session_id>]
# Populates the global array HARNESS_DISPATCH_ARGS with the full argument
# vector for a dispatch/resume invocation:
#   <permission-flag> [--resume <resume_session_id>] -p <prompt>
# Both supported harnesses accept `--resume <session_id>` and `-p <prompt>`
# identically, so a single arg-vector shape covers normal dispatch, watchdog
# restart, and stall-resume re-entry.
# ---------------------------------------------------------------------------
_harness_dispatch_args() {
  local prompt="${1:?_harness_dispatch_args: prompt required}"
  local resume_sid="${2:-}"
  local flag
  flag="$(_harness_permission_flag)"
  HARNESS_DISPATCH_ARGS=("$flag")
  if [[ -n "$resume_sid" ]]; then
    HARNESS_DISPATCH_ARGS+=(--resume "$resume_sid")
  fi
  HARNESS_DISPATCH_ARGS+=(-p "$prompt")
}

# ---------------------------------------------------------------------------
# _harness_po_agent_verification_clause — sentence appended to every top-level
# po-agent dispatch prompt (fresh dispatch, stall resume, HALT-007B resume).
# OMP renders a Task call's `context` into the child's system prompt, the same
# level as its generic "skip builds/tests mid-flight" and subagent hand-off
# guidance; skill text alone loses to that guidance (#141). The paragraph lives
# in config/verification-ownership.md so every prompt carries identical text.
# ---------------------------------------------------------------------------
_HARNESS_VERIFICATION_OWNERSHIP_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/verification-ownership.md"

_harness_po_agent_verification_clause() {
  local paragraph
  paragraph="$(<"$_HARNESS_VERIFICATION_OWNERSHIP_FILE")" || return 1
  printf '%s' "Put this paragraph verbatim in the po-agent's Task context (at the top of its prompt when the Task tool has no context field): ${paragraph}"
}

# ---------------------------------------------------------------------------
# Standalone CLI — only active when this file is executed directly (not
# sourced). Lets shell-stub unit tests assert command construction without
# invoking a real model.
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    mode)
      _harness_mode
      ;;
    permission-flag)
      _harness_permission_flag
      ;;
    dispatch-args)
      prompt="${2:-}"
      resume_sid="${3:-}"
      _harness_dispatch_args "$prompt" "$resume_sid"
      printf '%s\n' "${HARNESS_DISPATCH_ARGS[@]}"
      ;;
    *)
      echo "usage: harness-command.sh mode|permission-flag|dispatch-args <prompt> [resume_session_id]" >&2
      exit 1
      ;;
  esac
fi
