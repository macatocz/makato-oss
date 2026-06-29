#!/usr/bin/env bash
# Append a JSONL entry to the spec folder's build.jsonl.
# Resolves the spec folder by prefix-matching specs/<key>-*/ (makato-plan naming convention).
# Usage: build-log.sh <key> '<json-object>'
#
# Worktree-awareness (#85): the JSONL audit trail lives in the MAIN checkout's
# specs/ directory, NOT in a per-run git worktree. specs/ is gitignored, so a
# fresh `git worktree add` creates a worktree without any specs/ content. If
# this script ran with `git rev-parse --show-toplevel` (CWD-relative) from
# inside a worktree, every JSONL entry would land in `<worktree>/specs/<key>/`
# — a directory that nobody else reads, splitting the audit trail across
# disconnected files. The fix derives REPO_ROOT from the COMMON git directory
# (`git rev-parse --git-common-dir`), which always points at the main repo's
# `.git` regardless of where the caller is running from. The worktree's `.git`
# is a *file* containing a `gitdir:` pointer to the common dir; only the main
# checkout has `.git` as a directory.
set -euo pipefail

KEY="${1:?key required}"
ENTRY="${2:?json entry required}"

# Resolve to the MAIN checkout's repo root. From a worktree,
# `git rev-parse --git-common-dir` echoes the main repo's `.git`; its parent is
# the main checkout. From the main checkout the same call echoes `.git` and the
# parent is the checkout itself — behaviour is identical for non-worktree callers.
GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$GIT_COMMON_DIR" ]]; then
  # `--git-common-dir` may be relative to CWD; absolutise via the parent dir.
  REPO_ROOT="$(cd "$GIT_COMMON_DIR/.." && pwd)"
else
  # Outside a git repo entirely — degrade to the legacy behaviour so the
  # script never crashes in test fixtures or scratch dirs.
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
SPECS_DIR="$REPO_ROOT/specs"

# Resolve spec folder: find the first directory matching specs/<key>-*/
SPEC_FOLDER=""
if [[ -d "$SPECS_DIR" ]]; then
  SPEC_FOLDER="$(find "$SPECS_DIR" -maxdepth 1 -type d -name "${KEY}-*" | head -1)"
fi

# Fall back to local-work path (no slug suffix)
if [[ -z "$SPEC_FOLDER" ]] && [[ -d "$SPECS_DIR/$KEY" ]]; then
  SPEC_FOLDER="$SPECS_DIR/$KEY"
fi

# If still not found, create a placeholder directory so logging never fails
if [[ -z "$SPEC_FOLDER" ]]; then
  SPEC_FOLDER="$SPECS_DIR/$KEY"
fi

LOG_FILE="$SPEC_FOLDER/build.jsonl"
mkdir -p "$(dirname "$LOG_FILE")"
printf '%s\n' "$ENTRY" >> "$LOG_FILE"
