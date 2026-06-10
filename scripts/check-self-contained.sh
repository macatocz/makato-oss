#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="${1:?Usage: check-self-contained.sh <skill-dir>}"
SKILL_DIR="${SKILL_DIR%/}"
SKILL_NAME="$(basename "$SKILL_DIR")"
PLUGIN_NAME="$(basename "$(dirname "$(dirname "$SKILL_DIR")")")"

ERRORS=0

while IFS= read -r -d '' file; do
  while IFS= read -r line; do
    # Strip everything inside backticks (inline code) so prose mentioning
    # the symlink target like `shared` -> `../../shared` is allowed.
    stripped="$(echo "$line" | sed -E 's/`[^`]*`//g')"
    if echo "$stripped" | grep -qE '\.\./'; then
      echo "ERROR: [$PLUGIN_NAME/$SKILL_NAME] Escaping path in $(basename "$file"): $line"
      ERRORS=$((ERRORS + 1))
    fi
  done < "$file"
done < <(find "$SKILL_DIR" -type f -print0)

if [ $ERRORS -eq 0 ]; then
  echo "Self-containment [$PLUGIN_NAME/$SKILL_NAME]: OK"
  exit 0
else
  echo "Self-containment [$PLUGIN_NAME/$SKILL_NAME]: $ERRORS error(s)"
  exit 1
fi
