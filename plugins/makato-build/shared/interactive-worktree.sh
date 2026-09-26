#!/usr/bin/env bash
# Create or resume the per-session worktree for an interactive build skill.
#
# Usage: interactive-worktree.sh KEY [ISSUE_NUMBER] [BRANCH]
#
# ISSUE_NUMBER is optional for local-only work. Ticket keys use their first
# numeric component; local keys receive a deterministic synthetic number so
# the shared per-issue state/worktree contract still applies.
#
# The orchestrate worktree helper remains the single implementation of the
# lifecycle and state invariant. This wrapper only resolves the installed
# sibling plugin, initialises state when needed, and selects a safe base ref.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KEY="${1:?key required}"
ISSUE_NUMBER="${2:-}"
BRANCH="${3:-}"
REPO_ROOT="$(git rev-parse --show-toplevel)"

if [[ -z "$ISSUE_NUMBER" ]]; then
  ISSUE_NUMBER="$(printf '%s' "$KEY" | sed -nE 's/^[^0-9]*([0-9]+).*/\1/p')"
fi
if [[ -z "$ISSUE_NUMBER" ]]; then
  ISSUE_NUMBER="$(printf '%s' "$KEY" | cksum | awk '{print ($1 % 2147483646) + 1}')"
fi

COMMON_DIR="$(git rev-parse --git-common-dir)"
if [[ "$COMMON_DIR" != /* ]]; then
  COMMON_DIR="$REPO_ROOT/$COMMON_DIR"
fi
MAIN_ROOT="$(cd "$COMMON_DIR/.." && pwd)"
if [[ "$REPO_ROOT" != "$MAIN_ROOT" ]]; then
  printf 'worktree_resumed\n%s\n' "$REPO_ROOT"
  exit 0
fi

_resolve_repo_name() {
  local remote raw
  if [[ -n "${MAKATO_REPO_NAME:-}" ]]; then
    printf '%s\n' "$MAKATO_REPO_NAME"
    return 0
  fi

  if command -v gh >/dev/null 2>&1; then
    raw="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    if [[ -n "$raw" ]]; then
      printf '%s\n' "$raw"
      return 0
    fi
  fi

  remote="$(git config --get remote.origin.url 2>/dev/null || true)"
  remote="${remote%.git}"
  if [[ "$remote" == git@*:* ]]; then
    remote="${remote#*:}"
  elif [[ "$remote" == *github.com/* ]]; then
    remote="${remote#*github.com/}"
  elif [[ "$remote" == ssh://*/* ]]; then
    remote="${remote#ssh://*/}"
  fi
  if [[ -n "$remote" && "$remote" != */* ]]; then
    remote=""
  fi
  printf '%s\n' "${remote:-$(basename "$REPO_ROOT")}" | tr -cd '[:alnum:]_./-\n'
}

_resolve_shared() {
  local candidate
  if [[ -n "${MAKATO_ORCHESTRATE_SHARED:-}" ]]; then
    printf '%s\n' "$MAKATO_ORCHESTRATE_SHARED"
    return 0
  fi
  for candidate in \
    "$REPO_ROOT/plugins/makato-orchestrate/shared" \
    "$SCRIPT_DIR/../../makato-orchestrate/shared" \
    "${CLAUDE_PLUGIN_ROOT:-}/../makato-orchestrate/shared" \
    "${MAKATO_PLUGIN_ROOT:-}/../makato-orchestrate/shared" \
    "$HOME/.omp/plugins/cache/plugins/"*makato-orchestrate*/shared \
    "$HOME/.claude/plugins/cache/plugins/"*makato-orchestrate*/shared; do
    if [[ -x "$candidate/worktree.sh" && -x "$candidate/workflow-state.sh" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "interactive-worktree: cannot locate makato-orchestrate/shared; set MAKATO_ORCHESTRATE_SHARED" >&2
  return 1
}
_safe_key="$(printf '%s' "$KEY" | tr '[:upper:]# /' '[:lower:]---' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
if [[ -z "$BRANCH" ]]; then
  BRANCH="feat/${_safe_key}-build"
fi

SHARED="$(_resolve_shared)"
STATE_HELPER="$SHARED/workflow-state.sh"
WORKTREE_HELPER="$SHARED/worktree.sh"
REPO_NAME="$(_resolve_repo_name)"

STATE_JSON="$($STATE_HELPER read "$KEY" "$ISSUE_NUMBER" 2>/dev/null || printf '{}')"
if [[ "$(jq -r '.repo // empty' <<<"$STATE_JSON")" == "" ]]; then
  "$STATE_HELPER" init "$KEY" "$REPO_NAME" "$BRANCH" "$ISSUE_NUMBER" >&2
fi

CURRENT_BRANCH="$(git branch --show-current)"
BASE_REF="${MAKATO_WORKTREE_BASE_REF:-}"
if [[ -z "$BASE_REF" && "$CURRENT_BRANCH" != "main" && "$CURRENT_BRANCH" != "master" ]]; then
  BASE_REF="HEAD"
fi

if git show-ref --verify --quiet "refs/heads/$BRANCH" ||
  git ls-remote --exit-code origin "$BRANCH" >/dev/null 2>&1; then
  WORKTREE_OUTPUT="$($WORKTREE_HELPER create "$KEY" "$ISSUE_NUMBER" "$REPO_NAME" "$BRANCH")"
elif [[ -n "$BASE_REF" ]]; then
  WORKTREE_OUTPUT="$(MAKATO_WORKTREE_BASE_REF="$BASE_REF" "$WORKTREE_HELPER" create --new-branch "$KEY" "$ISSUE_NUMBER" "$REPO_NAME" "$BRANCH")"
else
  WORKTREE_OUTPUT="$($WORKTREE_HELPER create --new-branch "$KEY" "$ISSUE_NUMBER" "$REPO_NAME" "$BRANCH")"
fi

WORKTREE_PATH="$(printf '%s\n' "$WORKTREE_OUTPUT" | tail -n 1)"
if [[ -z "$WORKTREE_PATH" || ! -d "$WORKTREE_PATH" || "$WORKTREE_PATH" == "$REPO_ROOT" ]]; then
  echo "interactive-worktree: helper returned an invalid worktree path: ${WORKTREE_PATH:-<empty>}" >&2
  exit 1
fi

printf '%s\n' "$WORKTREE_OUTPUT"
