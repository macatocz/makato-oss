#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ERRORS=0

for plugin_dir in "$REPO_ROOT"/plugins/*/; do
  if [ -d "$plugin_dir" ]; then
    plugin_name="$(basename "$plugin_dir")"
    if ! echo "$plugin_name" | grep -qE '^makato-[a-z][a-z0-9-]*$'; then
      echo "ERROR: Plugin name doesn't match pattern 'makato-<kebab-case>': $plugin_name"
      ERRORS=$((ERRORS + 1))
    fi
  fi
done

for skill_dir in "$REPO_ROOT"/plugins/*/skills/*/; do
  if [ -d "$skill_dir" ]; then
    skill_name="$(basename "$skill_dir")"
    if ! echo "$skill_name" | grep -qE '^[a-z][a-z0-9-]*$'; then
      echo "ERROR: Skill name doesn't match kebab-case: $skill_name"
      ERRORS=$((ERRORS + 1))
    fi
  fi
done

if [ $ERRORS -eq 0 ]; then
  echo "Naming conventions: OK"
  exit 0
else
  echo "Naming conventions: $ERRORS error(s)"
  exit 1
fi
