#!/usr/bin/env bash
# resolve-append-only-conflict.sh — union-merge a single conflicted append-only
# file inside an in-progress git merge, so BOTH sides' additions survive.
#
# The resolve-pr-conflict skill's blunt `merge -X ours` fallback silently
# discards the target branch's hunks on any conflicting region. For an
# *append-only* file — a CHANGELOG where each branch prepends its own release
# block, an AUTHORS list, a JSONL audit log — that is data loss, not a
# resolution: main's changelog entry vanishes and `-X ours` never even reports
# a conflict. The correct resolution for these files is a 3-way *union* merge
# (git's built-in `union` driver): keep every line from both sides, in order,
# dropping only the conflict markers.
#
# This is the executable reference implementation of resolve-pr-conflict.md
# § "Step 4 — Partitioned resolution: union for append-only, ours for the rest".
# The skill shells out to it so the union logic is deterministic and
# unit-testable rather than re-derived by the model each run.
#
# Usage:
#   resolve-append-only-conflict.sh <file-path>
#
#   file-path   path (relative to the repo/worktree root) of a conflicted file.
#               MUST be a currently-unmerged path (has entries in `git ls-files
#               -u`). Run from inside the worktree, mid-merge.
#
# Behaviour:
#   - Reads the three merge stages: :1 (merge base — absent for an add/add
#     conflict), :2 (ours / current branch), :3 (theirs / merged-in branch).
#   - Runs `git merge-file -p --union` over ours/base/theirs. --union keeps both
#     sides of every conflicting hunk with no markers; non-conflicting hunks
#     merge normally. An absent base is treated as empty (add/add union).
#   - Writes the union result back to the working-tree file and `git add`s it,
#     clearing the unmerged state for that path.
#
# Output:
#   - A one-line JSON summary is written to stdout:
#       {"path":"...","resolved":true,"strategy":"union","had_base":true|false,
#        "markers_remaining":0}
#
# Exit codes:
#   0  file union-resolved and staged
#   1  usage error, path not unmerged, or union left conflict markers
set -euo pipefail

FILE="${1:?usage: resolve-append-only-conflict.sh <file-path>}"

# Must be an unmerged path — refuse to touch anything that is not actively
# conflicted, so a caller bug cannot clobber a clean file.
if ! git ls-files -u -- "$FILE" | grep -q .; then
  echo "resolve-append-only-conflict: not an unmerged path: $FILE" >&2
  exit 1
fi

TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

OURS="$TMPDIR_LOCAL/ours"
BASE="$TMPDIR_LOCAL/base"
THEIRS="$TMPDIR_LOCAL/theirs"

# Stage 2 = ours, stage 3 = theirs, stage 1 = base. For an add/add conflict
# stage 1 is absent; `git show :1:` fails, so fall back to an empty base file
# (union of ours+theirs against nothing keeps every line from both).
git show ":2:$FILE" > "$OURS" 2>/dev/null || : > "$OURS"
git show ":3:$FILE" > "$THEIRS" 2>/dev/null || : > "$THEIRS"
HAD_BASE=true
git show ":1:$FILE" > "$BASE" 2>/dev/null || { : > "$BASE"; HAD_BASE=false; }

# `git merge-file -p` writes the merged result to stdout and does NOT modify
# its inputs. --union suppresses markers by keeping both hunks. Exit status is
# the count of remaining conflicts; with --union it is always 0.
UNION_OUT="$TMPDIR_LOCAL/union"
git merge-file -p --union "$OURS" "$BASE" "$THEIRS" > "$UNION_OUT"

MARKERS="$(grep -c -E '^(<<<<<<<|=======|>>>>>>>)' "$UNION_OUT" || true)"
if [[ "$MARKERS" -ne 0 ]]; then
  echo "resolve-append-only-conflict: union left $MARKERS conflict marker(s) in $FILE" >&2
  exit 1
fi

# Overwrite the working-tree file and clear the unmerged state.
cp "$UNION_OUT" "$FILE"
git add -- "$FILE"

printf '{"path":%s,"resolved":true,"strategy":"union","had_base":%s,"markers_remaining":0}\n' \
  "$(printf '%s' "$FILE" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
  "$HAD_BASE"
