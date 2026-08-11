#!/usr/bin/env bash
# cross-platform-audit.sh — assert zero unguarded macOS-only tool calls in
# the makato-orchestrate runtime path (loop.sh, loop-halt-watch.sh, functions.sh).
#
# A call is "guarded" when a Darwin/uname guard pattern appears within the
# preceding 20 lines in the same file. Uses a single awk pass per tool per
# file — no per-line subprocess forks, runs in under one second on large files.
#
# macOS-only tools checked: osascript, pbcopy, pbpaste, plutil, launchctl
# ("open" and "say" are intentionally omitted: "open" is also a Linux command,
# and "say" appears as a substring of common words in comments.)
#
# Usage:
#   plugins/makato-orchestrate/scripts/tests/cross-platform-audit.sh [REPO_ROOT]
#
# Exit codes:
#   0 — clean: all occurrences are guarded (or absent)
#   1 — one or more unguarded calls found; offending lines printed to stdout
#   2 — usage / missing file error
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${1:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")}"

if [[ -z "$REPO_ROOT" ]]; then
  echo "cross-platform-audit: ERROR — cannot derive REPO_ROOT" >&2
  exit 2
fi

SCRIPTS_DIR="$REPO_ROOT/plugins/makato-orchestrate/scripts"

# Runtime-path files to audit
AUDIT_FILES=(
  "$SCRIPTS_DIR/loop.sh"
  "$SCRIPTS_DIR/loop-halt-watch.sh"
  "$SCRIPTS_DIR/functions.sh"
)

# macOS-only tools (word-boundary checked in awk via \b…\b regex)
DARWIN_TOOLS=(osascript pbcopy pbpaste plutil launchctl)

# Guard pattern: any line containing "uname", "Darwin", or "DARWIN" within
# the 20 lines preceding a tool call marks that call as guarded.
GUARD_PATTERN='uname|Darwin|DARWIN'

# Window size: how many preceding lines to look back for a guard
WINDOW=20

overall_fail=0
declare -a ALL_OFFENDING=()

# Single-pass awk audit per tool per file.
# Strategy: maintain a circular buffer of the last WINDOW lines and a
# "lines_guarded_until" watermark. When a guard line is seen at line N,
# set watermark = N + WINDOW. A tool call at line M is guarded iff M <= watermark.
# This avoids per-line grep forks entirely.
audit_tool_in_file() {
  local tool="$1" file="$2"
  awk -v tool="$tool" -v guard_pat="$GUARD_PATTERN" -v win="$WINDOW" '
  BEGIN { guarded_until = 0; fail = 0 }
  # Skip blank lines and comment-only lines.
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*$/ { next }
  # Update guard watermark when this line contains a guard pattern.
  $0 ~ guard_pat { if (NR + win > guarded_until) guarded_until = NR + win }
  # Check for the tool as a substring (tool names are unique; no word-boundary needed).
  index($0, tool) > 0 && (NR > guarded_until) {
    print "UNGUARDED:" FILENAME ":" NR ": " $0
    fail = 1
  }
  END { exit fail }
  ' "$file"
}

for FILE in "${AUDIT_FILES[@]}"; do
  if [[ ! -f "$FILE" ]]; then
    echo "cross-platform-audit: ERROR — file not found: $FILE" >&2
    exit 2
  fi
  for tool in "${DARWIN_TOOLS[@]}"; do
    while IFS= read -r offending; do
      ALL_OFFENDING+=("$offending")
      overall_fail=1
    done < <(audit_tool_in_file "$tool" "$FILE" 2>/dev/null || true)
  done
done

if [[ "$overall_fail" -eq 0 ]]; then
  echo "cross-platform-audit: PASS — zero unguarded macOS-only tool calls in runtime path"
  exit 0
else
  echo "cross-platform-audit: FAIL — ${#ALL_OFFENDING[@]} unguarded macOS-only tool call(s) found:"
  for line in "${ALL_OFFENDING[@]}"; do
    echo "  $line"
  done
  exit 1
fi
