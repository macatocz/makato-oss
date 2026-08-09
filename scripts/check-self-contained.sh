#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="${1:?Usage: check-self-contained.sh <skill-dir>}"
SKILL_DIR="${SKILL_DIR%/}"
SKILL_NAME="$(basename "$SKILL_DIR")"
PLUGIN_NAME="$(basename "$(dirname "$(dirname "$SKILL_DIR")")")"

ERRORS=0

while IFS= read -r -d '' file; do
  in_fence=0
  while IFS= read -r line; do
    # Skip fenced code blocks (``` … ```): code examples — a relative import
    # like `import … from '../fixtures'` or a shell `cd ../..` — are
    # illustrative snippets a consumer runs in their own repo, not paths the
    # skill itself resolves. Toggle on any line whose first non-space chars
    # are a ``` (or ~~~) fence marker (#730).
    if [[ "$line" =~ ^[[:space:]]*(\`\`\`|~~~) ]]; then
      in_fence=$((1 - in_fence))
      continue
    fi
    [[ "$in_fence" -eq 1 ]] && continue
    # Strip everything inside backticks (inline code) so prose mentioning
    # the symlink target like `shared` -> `../../shared` is allowed.
    stripped="$(echo "$line" | sed -E 's/`[^`]*`//g')"
    # Strip URL tokens (http/https) so illustrative example links such as
    # https://github.com/org/repo/.../issues/123 are not mistaken for
    # filesystem escaping paths (#730).
    stripped="$(echo "$stripped" | sed -E 's|https?://[^ ]*||g')"
    # Strip Markdown link targets `](target)` — a link to a sibling skill or
    # a shared reference (e.g. `[schema](../../shared/finding-schema.md)`) is
    # documentation cross-linking, not a runtime self-containment violation.
    # The link TEXT is already inside backticks and stripped above; here we
    # remove the parenthesised destination (#730).
    stripped="$(echo "$stripped" | sed -E 's|\]\([^)]*\)|]|g')"
    if echo "$stripped" | grep -qE '\.\./'; then
      echo "ERROR: [$PLUGIN_NAME/$SKILL_NAME] Escaping path in $(basename "$file"): $line"
      ERRORS=$((ERRORS + 1))
    fi
  done < "$file"
  # Scan markdown prose only — shell scripts (`cd "$SCRIPT_DIR/../../.."`),
  # JSON, and YAML are implementation artefacts, not self-containment
  # references, and their relative paths are legitimate (#730).
done < <(find "$SKILL_DIR" -type f -name "*.md" -print0)

if [ $ERRORS -eq 0 ]; then
  echo "Self-containment [$PLUGIN_NAME/$SKILL_NAME]: OK"
  exit 0
else
  echo "Self-containment [$PLUGIN_NAME/$SKILL_NAME]: $ERRORS error(s)"
  exit 1
fi
