#!/usr/bin/env bash
# provision-persistent-volume.sh — idempotent bootstrap for the persistent-volume
# layout that non-regenerable makato state lives on (issue #8).
#
# Creates three subdirectories under MAKATO_PERSISTENT_VOLUME_ROOT and prints a
# per-path "created" or "confirmed" summary line.  Designed to be called:
#   - standalone:              provision-persistent-volume.sh
#   - systemd ExecStartPre:    ExecStartPre=/path/to/provision-persistent-volume.sh
#   - launchd ProgramArguments entry (before loop-supervisor.sh)
#
# Environment:
#   MAKATO_PERSISTENT_VOLUME_ROOT  Volume root  (default: ~/.makato-pv)
#   MAKATO_PV_WORKFLOW_STATE_DIR   workflow-state subdir  (default: <root>/workflow-state)
#   MAKATO_PV_WORKTREES_DIR        worktrees subdir       (default: <root>/worktrees)
#
# Exit codes:
#   0 — all paths confirmed/created
#   1 — a directory could not be created (mkdir failure printed to stderr)

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
_expand() {
  # Expand a single leading ~ to $HOME; leave everything else untouched.
  local p="$1"
  [[ "$p" == "~/"* ]] && p="$HOME/${p:2}"
  [[ "$p" == "~" ]]   && p="$HOME"
  printf '%s' "$p"
}

PV_ROOT="$(_expand "${MAKATO_PERSISTENT_VOLUME_ROOT:-~/.makato-pv}")"
WF_DIR="$(_expand  "${MAKATO_PV_WORKFLOW_STATE_DIR:-${PV_ROOT}/workflow-state}")"
WT_DIR="$(_expand  "${MAKATO_PV_WORKTREES_DIR:-${PV_ROOT}/worktrees}")"
BR_DIR="${PV_ROOT}/branches"

# ---------------------------------------------------------------------------
# Idempotent mkdir helper — prints "created" or "confirmed" per path.
# ---------------------------------------------------------------------------
_ensure_dir() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    printf '  confirmed  %s\n' "$dir"
  else
    if mkdir -p "$dir"; then
      printf '  created    %s\n' "$dir"
    else
      printf 'provision-persistent-volume: ERROR — cannot create %s\n' "$dir" >&2
      return 1
    fi
  fi
}

# ---------------------------------------------------------------------------
# Provision
# ---------------------------------------------------------------------------
printf 'provision-persistent-volume: root=%s\n' "$PV_ROOT"
_ensure_dir "$WF_DIR"
_ensure_dir "$WT_DIR"
_ensure_dir "$BR_DIR"
printf 'provision-persistent-volume: done\n'
