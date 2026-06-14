#!/usr/bin/env bash
set -euo pipefail

PLUGIN_DIR="${1:?Usage: check-plugin-structure.sh <plugin-dir>}"
PLUGIN_DIR="${PLUGIN_DIR%/}"
PLUGIN_NAME="$(basename "$PLUGIN_DIR")"

ERRORS=0

REQUIRED_FILES=(
  ".claude-plugin/plugin.json"
  "CLAUDE.md"
  "AGENTS.md"
  "CHANGELOG.md"
  "README.md"
)

for file in "${REQUIRED_FILES[@]}"; do
  if [ ! -f "$PLUGIN_DIR/$file" ]; then
    echo "ERROR: [$PLUGIN_NAME] Missing required file: $file"
    ERRORS=$((ERRORS + 1))
  fi
done

if [ -f "$PLUGIN_DIR/.claude-plugin/plugin.json" ]; then
  if ! python3 -c "import json; json.load(open('$PLUGIN_DIR/.claude-plugin/plugin.json'))" 2>/dev/null; then
    echo "ERROR: [$PLUGIN_NAME] plugin.json is not valid JSON"
    ERRORS=$((ERRORS + 1))
  fi

  FORBIDDEN_KEYS=("skills" "agents" "hooks")
  for key in "${FORBIDDEN_KEYS[@]}"; do
    if python3 -c "import json; d=json.load(open('$PLUGIN_DIR/.claude-plugin/plugin.json')); exit(0 if '$key' in d else 1)" 2>/dev/null; then
      echo "ERROR: [$PLUGIN_NAME] plugin.json must not contain \"$key\" array (auto-loaded from directory structure)"
      ERRORS=$((ERRORS + 1))
    fi
  done
fi

if [ -f "$PLUGIN_DIR/AGENTS.md" ]; then
  line_count=$(wc -l < "$PLUGIN_DIR/AGENTS.md")
  if [ "$line_count" -gt 200 ]; then
    echo "ERROR: [$PLUGIN_NAME] AGENTS.md exceeds 200 lines ($line_count lines)"
    ERRORS=$((ERRORS + 1))
  fi
fi

if [ $ERRORS -eq 0 ]; then
  echo "Plugin structure [$PLUGIN_NAME]: OK"
  exit 0
else
  echo "Plugin structure [$PLUGIN_NAME]: $ERRORS error(s)"
  exit 1
fi
