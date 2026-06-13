#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="${1:?Usage: check-skill-frontmatter.sh <skill-dir>}"
SKILL_DIR="${SKILL_DIR%/}"
SKILL_NAME="$(basename "$SKILL_DIR")"
PLUGIN_NAME="$(basename "$(dirname "$(dirname "$SKILL_DIR")")")"

SKILL_FILE="$SKILL_DIR/SKILL.md"

if [ ! -f "$SKILL_FILE" ]; then
  echo "ERROR: [$PLUGIN_NAME/$SKILL_NAME] Missing SKILL.md"
  exit 1
fi

ERRORS=0

if ! head -1 "$SKILL_FILE" | grep -q '^---$'; then
  echo "ERROR: [$PLUGIN_NAME/$SKILL_NAME] SKILL.md missing frontmatter (no opening ---)"
  exit 1
fi

FRONTMATTER=$(sed -n '/^---$/,/^---$/p' "$SKILL_FILE" | sed '1d;$d')

REQUIRED_FIELDS=("name" "description" "version")

for field in "${REQUIRED_FIELDS[@]}"; do
  if ! grep -q "^${field}:" <<< "$FRONTMATTER"; then
    echo "ERROR: [$PLUGIN_NAME/$SKILL_NAME] Missing frontmatter field: $field"
    ERRORS=$((ERRORS + 1))
  fi
done

if grep -q '^version:' <<< "$FRONTMATTER"; then
  version=$(grep '^version:' <<< "$FRONTMATTER" | sed 's/version:[[:space:]]*//' | tr -d '"' | tr -d "'")
  if ! grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' <<< "$version"; then
    echo "ERROR: [$PLUGIN_NAME/$SKILL_NAME] Version not valid semver: $version"
    ERRORS=$((ERRORS + 1))
  fi
fi

if [ $ERRORS -eq 0 ]; then
  echo "Skill frontmatter [$PLUGIN_NAME/$SKILL_NAME]: OK"
  exit 0
else
  echo "Skill frontmatter [$PLUGIN_NAME/$SKILL_NAME]: $ERRORS error(s)"
  exit 1
fi
