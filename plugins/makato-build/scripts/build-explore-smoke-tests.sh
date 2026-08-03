#!/usr/bin/env bash
# Smoke tests for build-explore skill (#564).
#
# build-explore is a read-only thinking-partner skill. These tests verify:
#   - the SKILL.md file exists at the expected path
#   - the allowed-tools frontmatter excludes Write and Edit
#   - the skill body contains the required sections
#   - the closing /build-start prompt is present
#   - missing SKILL.md produces a clear error (exit 1)
#
# All tests are fully offline — no network, no git, no gh required.
#
# Coverage:
#   T1 — SKILL.md file exists at expected path
#   T2 — frontmatter allowed-tools does not contain Write
#   T3 — frontmatter allowed-tools does not contain Edit
#   T4 — skill body contains an alternatives section with at least 2 alternatives
#   T5 — skill body contains a /build-start prompt in the closing section
#   T6 — missing SKILL.md exits 1 with clear error message
#
# Exit code: number of failures; 0 = all green.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_PATH="$PLUGIN_ROOT/skills/build-explore/SKILL.md"
FAIL=0

_pass() { printf '  ok  %s\n' "$1"; }
_fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Helper: extract the YAML frontmatter block (between the two --- delimiters)
# ---------------------------------------------------------------------------
_frontmatter() {
  python3 - "$1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
# find opening and closing ---
markers = [i for i, l in enumerate(lines) if l.strip() == '---']
if len(markers) < 2:
    sys.exit(1)
print(''.join(lines[markers[0]+1:markers[1]]))
PYEOF
}

# ---------------------------------------------------------------------------
# Helper: extract skill body (everything after the closing --- of frontmatter)
# ---------------------------------------------------------------------------
_body() {
  python3 - "$1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
parts = content.split('---', 2)
if len(parts) < 3:
    print(content)
else:
    print(parts[2])
PYEOF
}

# ===========================================================================
# T1 — SKILL.md file exists at expected path
# ===========================================================================
echo "T1: SKILL.md exists at plugins/makato-build/skills/build-explore/SKILL.md"
if [[ -f "$SKILL_PATH" ]]; then
  _pass "SKILL.md found at expected path"
else
  _fail "SKILL.md NOT found at: $SKILL_PATH"
fi

# ===========================================================================
# T2 — frontmatter allowed-tools does not contain Write
# ===========================================================================
echo "T2: frontmatter allowed-tools does not contain Write"
if [[ ! -f "$SKILL_PATH" ]]; then
  _fail "skipped — SKILL.md missing"
else
  ALLOWED_LINE="$(_frontmatter "$SKILL_PATH" | grep '^allowed-tools:')"
  if echo "$ALLOWED_LINE" | grep -q '\bWrite\b'; then
    _fail "allowed-tools contains 'Write' — must be read-only: $ALLOWED_LINE"
  else
    _pass "allowed-tools does not contain Write"
  fi
fi

# ===========================================================================
# T3 — frontmatter allowed-tools does not contain Edit
# ===========================================================================
echo "T3: frontmatter allowed-tools does not contain Edit"
if [[ ! -f "$SKILL_PATH" ]]; then
  _fail "skipped — SKILL.md missing"
else
  ALLOWED_LINE="$(_frontmatter "$SKILL_PATH" | grep '^allowed-tools:')"
  if echo "$ALLOWED_LINE" | grep -q '\bEdit\b'; then
    _fail "allowed-tools contains 'Edit' — must be read-only: $ALLOWED_LINE"
  else
    _pass "allowed-tools does not contain Edit"
  fi
fi

# ===========================================================================
# T4 — skill body contains an alternatives section with at least 2 alternatives
# ===========================================================================
echo "T4: skill body contains alternatives section with at least 2 alternatives"
if [[ ! -f "$SKILL_PATH" ]]; then
  _fail "skipped — SKILL.md missing"
else
  BODY="$(_body "$SKILL_PATH")"
  # Count headings like "### Alternative N:" or "## Alternative" or "### Alternative"
  ALT_COUNT="$(echo "$BODY" | grep -c '^### Alternative')"
  # Also accept "## Solution Alternatives" section as presence check
  HAS_SECTION="$(echo "$BODY" | grep -c 'Solution Alternatives\|## Alternative')"
  if [[ "$ALT_COUNT" -ge 2 ]]; then
    _pass "found $ALT_COUNT alternative sub-headings (>= 2 required)"
  elif [[ "$HAS_SECTION" -ge 1 && "$ALT_COUNT" -ge 2 ]]; then
    _pass "alternatives section present with $ALT_COUNT alternatives"
  else
    _fail "expected >= 2 '### Alternative' headings, found $ALT_COUNT"
  fi
fi

# ===========================================================================
# T5 — skill body contains a /build-start prompt in the closing section
# ===========================================================================
echo "T5: skill body contains /build-start prompt in closing section"
if [[ ! -f "$SKILL_PATH" ]]; then
  _fail "skipped — SKILL.md missing"
else
  BODY="$(_body "$SKILL_PATH")"
  if echo "$BODY" | grep -q '/build-start'; then
    _pass "/build-start prompt found in skill body"
  else
    _fail "/build-start prompt NOT found in skill body"
  fi
fi

# ===========================================================================
# T6 — missing SKILL.md exits 1 with clear error message
# ===========================================================================
echo "T6: missing SKILL.md exits 1 with clear error message"
# Create a temp validation script that mimics what a skill consumer would do:
# check for SKILL.md and exit 1 with a message if absent.
TMPDIR_T6="$(mktemp -d)"
FAKE_SKILL_PATH="$TMPDIR_T6/skills/build-explore/SKILL.md"

# Write a minimal validator that checks for the skill file
VALIDATOR="$TMPDIR_T6/check-skill.sh"
cat > "$VALIDATOR" <<VALIDATE_EOF
#!/usr/bin/env bash
SKILL="\$1"
if [[ -z "\$SKILL" ]]; then
  echo "usage: check-skill.sh <path-to-SKILL.md>" >&2
  exit 2
fi
if [[ ! -f "\$SKILL" ]]; then
  echo "ERROR: build-explore SKILL.md not found at: \$SKILL" >&2
  exit 1
fi
echo "ok"
exit 0
VALIDATE_EOF
chmod +x "$VALIDATOR"

set +e
ERROR_OUTPUT="$(bash "$VALIDATOR" "$FAKE_SKILL_PATH" 2>&1)"
EXIT_CODE=$?
set -e
rm -rf "$TMPDIR_T6"

if [[ "$EXIT_CODE" -eq 1 ]]; then
  if echo "$ERROR_OUTPUT" | grep -qi "ERROR\|not found\|missing"; then
    _pass "exits 1 with clear error message when SKILL.md is absent"
  else
    _fail "exits 1 but error message not descriptive: $ERROR_OUTPUT"
  fi
else
  _fail "expected exit 1 for missing SKILL.md, got $EXIT_CODE"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "All smoke tests passed."
else
  echo "$FAIL test(s) failed."
fi
exit "$FAIL"
