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

cd "$WORKTREE_PATH"
echo "T3: current worktree resumes only for its registered issue"
OUT3="$("$WRAPPER" "$KEY" "$ISSUE" "$BRANCH")"
[[ "$(printf '%s\n' "$OUT3" | sed -n '1p')" == "worktree_resumed" ]]
[[ "$(printf '%s\n' "$OUT3" | sed -n '2p')" == "$WORKTREE_PATH" ]]
echo "  passed"

echo "T4: another issue cannot claim this current worktree"
FOREIGN_KEY="local-interactive-foreign"
if "$WRAPPER" "$FOREIGN_KEY" "$ISSUE" "$BRANCH" > /dev/null 2>"$SANDBOX/foreign.stderr"; then
  echo "  failed: foreign issue reused current worktree"
  exit 1
fi
grep -q "workflow state does not own it" "$SANDBOX/foreign.stderr"
[[ ! -d "$SANDBOX/repo/specs/$FOREIGN_KEY" ]]
echo "  passed"

echo "T5: wrong branch and dirty current worktrees are rejected"
WRONG_BRANCH="feat/interactive-wrong"
git switch -q -c "$WRONG_BRANCH"
if "$WRAPPER" "$KEY" "$ISSUE" "$BRANCH" > /dev/null 2>"$SANDBOX/wrong-branch.stderr"; then
  echo "  failed: wrong branch was reused"
  exit 1
fi
grep -q "workflow state owns '$BRANCH'" "$SANDBOX/wrong-branch.stderr"
git switch -q "$BRANCH"
git -C "$SANDBOX/repo" branch -D "$WRONG_BRANCH" >/dev/null
printf 'leftover\n' > "$WORKTREE_PATH/.resume-dirty"
if "$WRAPPER" "$KEY" "$ISSUE" "$BRANCH" > /dev/null 2>"$SANDBOX/dirty.stderr"; then
  echo "  failed: dirty current worktree was reused"
  exit 1
fi
rm -f "$WORKTREE_PATH/.resume-dirty"
grep -q "refusing dirty current worktree" "$SANDBOX/dirty.stderr"
echo "  passed"

echo "T6: status-command failure is not treated as a clean worktree"
REAL_GIT="$(command -v git)"
GIT_SHIM_DIR="$SANDBOX/git-status-fail-bin"
mkdir -p "$GIT_SHIM_DIR"
cat >"$GIT_SHIM_DIR/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-C" && "\$2" == "$WORKTREE_PATH" && "\$3" == "status" ]]; then
  exit 128
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GIT_SHIM_DIR/git"
if PATH="$GIT_SHIM_DIR:$PATH" "$WRAPPER" "$KEY" "$ISSUE" "$BRANCH" > /dev/null 2>"$SANDBOX/status-failed.stderr"; then
  echo "  failed: status failure was treated as clean"
  exit 1
fi
rm -rf "$GIT_SHIM_DIR"
grep -q "could not verify current worktree cleanliness" "$SANDBOX/status-failed.stderr"
echo "  passed"

cd "$SANDBOX/repo"
"$WT" cleanup "$KEY" "$ISSUE" >/dev/null
echo "All interactive worktree smoke tests passed."
