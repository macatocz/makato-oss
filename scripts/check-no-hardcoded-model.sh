#!/usr/bin/env bash
# CI check: fail if any skill or agent markdown file contains hardcoded
# "model":"sonnet" or "model":"haiku" in a per-step log template.
# Session-start templates ARE allowed to set model — they're the source of truth.
# Everything else must rely on build-log.sh auto-injection (S4).
set -euo pipefail

FOUND=0

# Search skill and agent markdown files for hardcoded model in JSON templates
# Exclude session-start templates (those are the source of truth)
while IFS= read -r file; do
  # Look for "model":"haiku" or "model":"sonnet" patterns (with optional spaces)
  if grep -nE '"model"\s*:\s*"(haiku|sonnet)"' "$file" | grep -v 'session.*start' | grep -v 'step.*session' | grep -qv '^$'; then
    echo "FAIL: $file contains hardcoded model in non-session-start template:"
    grep -nE '"model"\s*:\s*"(haiku|sonnet)"' "$file" | grep -v 'session.*start' | grep -v 'step.*session'
    FOUND=1
  fi
done < <(find plugins -name "*.md" -path "*/skills/*" -o -name "*.md" -path "*/agents/*" | sort)

if [[ "$FOUND" -eq 0 ]]; then
  echo "OK: No hardcoded model names found in per-step log templates."
  exit 0
else
  echo ""
  echo "FAIL: Found hardcoded model names. Use build-log.sh auto-injection instead."
  echo "      Set model only in session-start log entries."
  exit 1
fi
