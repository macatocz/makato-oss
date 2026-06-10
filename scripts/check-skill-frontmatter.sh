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

python3_errors=$(python3 - "$SKILL_FILE" "$SKILL_NAME" <<'PYEOF'
import re, sys
import yaml

skill_file, dir_name = sys.argv[1], sys.argv[2]
content = open(skill_file).read()

end_idx = content.find('\n---', 4)
if end_idx == -1:
    print("ERROR: no closing --- in frontmatter")
    sys.exit(0)

try:
    fm = yaml.safe_load(content[4:end_idx]) or {}
except yaml.YAMLError as e:
    print(f"ERROR: YAML parse error: {e}")
    sys.exit(0)

# name: required, agentskills.io syntax rules
name = str(fm.get('name', ''))
if not name or name == 'None':
    print("ERROR: Missing frontmatter field: name")
else:
    if len(name) > 64:
        print(f"ERROR: name exceeds 64 characters ({len(name)}): {name}")
    if not re.fullmatch(r'[a-z0-9]([a-z0-9-]*[a-z0-9])?', name):
        print(f"ERROR: name must be lowercase letters/numbers/hyphens, not start/end with hyphen: {name}")
    elif '--' in name:
        print(f"ERROR: name must not contain consecutive hyphens: {name}")
    if name != dir_name:
        print(f"ERROR: name '{name}' does not match directory name '{dir_name}'")

# description: required, max 1024 chars
desc = str(fm.get('description', ''))
if not desc or desc == 'None':
    print("ERROR: Missing frontmatter field: description")
elif len(desc) > 1024:
    print(f"ERROR: description exceeds 1024 characters ({len(desc)} chars)")

# allowed-tools: optional; if present must be a space-separated string (not a list or mapping)
allowed = fm.get('allowed-tools')
if allowed is not None and not isinstance(allowed, str):
    print("ERROR: allowed-tools must be a space-separated string, not a list or mapping")

# metadata.version and metadata.last_updated: required
meta = fm.get('metadata')
if meta is None:
    print("ERROR: Missing metadata block (requires metadata.version and metadata.last_updated)")
elif not isinstance(meta, dict):
    print("ERROR: metadata must be a key-value mapping")
else:
    if 'version' not in meta:
        print("ERROR: Missing metadata.version")
    if 'last_updated' not in meta:
        print("ERROR: Missing metadata.last_updated")
PYEOF
)

if [ -n "$python3_errors" ]; then
  while IFS= read -r line; do
    echo "[$PLUGIN_NAME/$SKILL_NAME] $line"
    ERRORS=$((ERRORS + 1))
  done <<< "$python3_errors"
fi

if [ $ERRORS -eq 0 ]; then
  echo "Skill frontmatter [$PLUGIN_NAME/$SKILL_NAME]: OK"
  exit 0
else
  echo "Skill frontmatter [$PLUGIN_NAME/$SKILL_NAME]: $ERRORS error(s)"
  exit 1
fi
