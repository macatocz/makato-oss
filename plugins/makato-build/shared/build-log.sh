#!/usr/bin/env bash
# Append a JSONL entry (or batch of entries) to the spec folder's build.jsonl.
# Resolves the spec folder by prefix-matching specs/<key>-*/ (makato-plan naming convention).
#
# Usage:
#   build-log.sh <key> '<json-object>'        # single entry (legacy)
#   build-log.sh <key> --batch < entries.ndjson  # batch mode (#118): NDJSON on stdin
#
# Batch mode reads newline-delimited JSON entries from stdin and appends all of
# them in one shell invocation. Skills that emit 3-5 log rows per step can flush
# in one fork-exec instead of one per row — material at scale: a 10-task
# autonomous run across 12 skills was 50-150 fork-execs pre-#118.
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
ENTRY_OR_FLAG="${2:?json entry or --batch flag required}"

# Optional --trace-id <hex> flag: when present, the actual entry/flag is shifted
# to position 4, and TRACE_ID carries the 64-char sha256 hex digest that will be
# merged into each logged object. Fully backward-compatible — callers that omit
# --trace-id behave identically to before.
TRACE_ID=""
if [[ "$ENTRY_OR_FLAG" == "--trace-id" ]]; then
  TRACE_ID="${3:?--trace-id requires a hex value}"
  ENTRY_OR_FLAG="${4:?json entry or --batch flag required after --trace-id}"
fi

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

# Batch mode: read NDJSON entries from stdin, append them all. Lines that are
# blank or do not parse as JSON are skipped silently (the audit trail must not
# fail because a caller emitted a stray newline). This preserves the "logging
# never crashes" invariant the legacy single-entry mode also guarantees.
if [[ "$ENTRY_OR_FLAG" == "--batch" ]]; then
  while IFS= read -r line; do
    # Skip blank lines.
    [[ -z "$line" ]] && continue
    # Skip lines that don't parse as JSON objects. `jq -e .` exits non-zero on
    # parse failure; redirect stderr so a malformed line doesn't pollute the
    # caller's stderr.
    if ! jq -e . >/dev/null 2>&1 <<<"$line"; then
      continue
    fi
    # Merge issue_trace_id when --trace-id was supplied.
    if [[ -n "$TRACE_ID" ]]; then
      line="$(jq --arg tid "$TRACE_ID" '. + {issue_trace_id: $tid}' <<<"$line")"
    fi
    printf '%s\n' "$line" >> "$LOG_FILE"
  done
  exit 0
fi

# Single-entry mode: merge issue_trace_id when --trace-id was supplied.
if [[ -n "$TRACE_ID" ]]; then
  ENTRY_OR_FLAG="$(jq --arg tid "$TRACE_ID" '. + {issue_trace_id: $tid}' <<<"$ENTRY_OR_FLAG")"
fi
printf '%s\n' "$ENTRY_OR_FLAG" >> "$LOG_FILE"
