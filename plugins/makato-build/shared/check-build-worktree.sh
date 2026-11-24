#!/usr/bin/env bash
# Check the actual build checkout, not the main checkout it was created from.
set -euo pipefail

worktree="${1:?worktree path required}"
root="$(git -C "$worktree" rev-parse --show-toplevel)"
git_dir="$(git -C "$root" rev-parse --absolute-git-dir)"
common_dir="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)"
if [[ "$(realpath "$worktree")" != "$(realpath "$root")" || "$(realpath "$git_dir")" == "$(realpath "$common_dir")" ]]; then
  echo "build-start: refusing to use the main checkout as the build worktree" >&2
  exit 1
fi
branch="$(git -C "$root" branch --show-current)"
if [[ -z "$branch" || "$branch" == main || "$branch" == master ]]; then
  echo "build-start: build worktree must be on a feature branch" >&2
  exit 1
fi
status="$(git -C "$root" status --porcelain --untracked-files=all)"
while IFS= read -r line; do
  [[ -z "$line" || "$line" == '?? .loop-owner.pid' ]] && continue
  echo "build-start: build worktree is dirty: $root" >&2
  echo "Run git -C \"$root\" status and preserve or commit its changes before starting." >&2
  exit 1
done <<< "$status"
