#!/usr/bin/env bash
# Smoke test for interactive-worktree.sh.
# Run from the makato-oss repo root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAKATO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WRAPPER="$SCRIPT_DIR/interactive-worktree.sh"
SHARED="$MAKATO_ROOT/plugins/makato-orchestrate/shared"
WS="$SHARED/workflow-state.sh"
WT="$SHARED/worktree.sh"
SANDBOX="$(mktemp -d -t makato-interactive-wt-XXXXXX)"

cleanup() {
  if [[ -d "$SANDBOX/repo/.git" ]]; then
    git -C "$SANDBOX/repo" worktree list --porcelain 2>/dev/null \
      | sed -n 's/^worktree //p' \
      | while IFS= read -r path; do
          [[ "$path" == "$SANDBOX/repo" ]] || git -C "$SANDBOX/repo" worktree remove --force "$path" 2>/dev/null || true
        done
  fi
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

mkdir -p "$SANDBOX/repo"
git -C "$SANDBOX/repo" init -q -b main
git -C "$SANDBOX/repo" config user.email smoke@example.com
git -C "$SANDBOX/repo" config user.name "smoke test"
printf 'seed\n' > "$SANDBOX/repo/README.md"
git -C "$SANDBOX/repo" add README.md
git -C "$SANDBOX/repo" commit -q -m seed

KEY="local-interactive-smoke"
ISSUE=9876
BRANCH="feat/interactive-smoke"
export MAKATO_REPO_NAME="owner/repo"
export MAKATO_WORKTREE_ROOT="$SANDBOX/repo/.claude/worktrees"
export MAKATO_WORKTREE_BASE_REF=main

cd "$SANDBOX/repo"
echo "T1: interactive bootstrap creates a worktree without switching main"
OUT="$($WRAPPER "$KEY" "$ISSUE" "$BRANCH")"
[[ "$(printf '%s\n' "$OUT" | sed -n '1p')" == "worktree_created" ]]
WORKTREE_PATH="$(printf '%s\n' "$OUT" | sed -n '2p')"
test -d "$WORKTREE_PATH"
[[ "$(git branch --show-current)" == "main" ]]
[[ "$(git -C "$WORKTREE_PATH" branch --show-current)" == "$BRANCH" ]]
"$WS" read "$KEY" "$ISSUE" | jq -e --arg path "$WORKTREE_PATH" '.worktree_path == $path' >/dev/null
echo "  passed"

echo "T2: repeated bootstrap resumes the same worktree"
OUT2="$($WRAPPER "$KEY" "$ISSUE" "$BRANCH")"
[[ "$(printf '%s\n' "$OUT2" | sed -n '1p')" == "worktree_resumed" ]]
[[ "$(printf '%s\n' "$OUT2" | sed -n '2p')" == "$WORKTREE_PATH" ]]
echo "  passed"

"$WT" cleanup "$KEY" "$ISSUE" >/dev/null
echo "All interactive worktree smoke tests passed."
