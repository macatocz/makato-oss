#!/usr/bin/env bash
# Smoke test for interactive-worktree.sh.
# Run from the makato-oss repo root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAKATO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WRAPPER="$SCRIPT_DIR/interactive-worktree.sh"
CHECK="$SCRIPT_DIR/check-build-worktree.sh"
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
git init -q --bare "$SANDBOX/origin.git"
git -C "$SANDBOX/repo" remote add origin "$SANDBOX/origin.git"
git -C "$SANDBOX/repo" push -q origin main

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

echo "T3: the build worktree must be isolated and clean"
bash "$CHECK" "$WORKTREE_PATH"
if bash "$CHECK" "$SANDBOX/repo" >/dev/null 2>&1; then
  echo "main checkout was accepted" >&2
  exit 1
fi
printf 'untracked\n' >"$WORKTREE_PATH/local-change"
if bash "$CHECK" "$WORKTREE_PATH" >/dev/null 2>&1; then
  echo "dirty worktree was accepted" >&2
  exit 1
fi
rm "$WORKTREE_PATH/local-change"
printf 'modified\n' >"$WORKTREE_PATH/README.md"
if bash "$CHECK" "$WORKTREE_PATH" >/dev/null 2>&1; then
  echo "modified worktree was accepted" >&2
  exit 1
fi
git -C "$WORKTREE_PATH" restore README.md
bash "$CHECK" "$WORKTREE_PATH"
"$WT" cleanup "$KEY" "$ISSUE" >/dev/null
echo "  passed"

echo "T4: a dirty detached deployment uses the remote default, not its stale HEAD"
printf 'new base\n' >README.md
git add README.md
git commit -q -m 'new base'
git push -q origin main:development
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/development
git checkout -q --detach HEAD^
printf 'live deployment\n' >README.md
unset MAKATO_WORKTREE_BASE_REF
OUT="$($WRAPPER local-detached-smoke 9877 feat/detached-smoke)"
DETACHED_WORKTREE="$(printf '%s\n' "$OUT" | sed -n '2p')"
[[ "$(git -C "$DETACHED_WORKTREE" rev-parse HEAD)" == "$(git rev-parse refs/remotes/origin/development)" ]]
[[ "$(cat README.md)" == 'live deployment' ]]
bash "$CHECK" "$DETACHED_WORKTREE"
printf 'changed\n' >"$DETACHED_WORKTREE/README.md"
if bash "$CHECK" "$DETACHED_WORKTREE" >/dev/null 2>&1; then
  echo "dirty resumed worktree was accepted" >&2
  exit 1
fi
echo "  passed"
echo "All interactive worktree smoke tests passed."
