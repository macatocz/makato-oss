#!/usr/bin/env bash
# validate-agents-hard-constraints.sh — pre-commit hook that enforces a
# '## Hard Constraints' section near the top of every plugin AGENTS.md.
#
# Rules enforced:
#   1. Every staged AGENTS.md must contain a '## Hard Constraints' heading.
#   2. That heading must appear on or before line 30.
#
# Exit codes:
#   0 — all staged AGENTS.md files pass, or no AGENTS.md files are staged.
#   1 — at least one staged AGENTS.md is missing the section or has it too late.
#
# Usage (called by pre-commit with staged file paths as arguments):
#   validate-agents-hard-constraints.sh [FILE...]
#
# Pre-commit passes only files matching the hook's 'files' pattern (AGENTS.md),
# so no basename filtering is needed here.
set -euo pipefail

FAILED=0

for file in "$@"; do
  if [[ ! -f "$file" ]]; then
    # Deleted file — skip.
    continue
  fi

  # Find the line number of the first '## Hard Constraints' heading.
  line_num="$(grep -nE '^##[[:space:]]+Hard Constraints[[:space:]]*$' "$file" | head -1 | cut -d: -f1 || true)"

  if [[ -z "$line_num" ]]; then
    echo "FAIL: $file — missing '## Hard Constraints' section" >&2
    FAILED=1
    continue
  fi

  if [[ "$line_num" -gt 30 ]]; then
    echo "FAIL: $file — '## Hard Constraints' found at line $line_num (must be on or before line 30)" >&2
    FAILED=1
    continue
  fi
done

if [[ "$FAILED" -eq 1 ]]; then
  echo "" >&2
  echo "Each plugin AGENTS.md must open with a '## Hard Constraints' section" >&2
  echo "before line 30.  Add the section and re-stage the file." >&2
  exit 1
fi

exit 0
