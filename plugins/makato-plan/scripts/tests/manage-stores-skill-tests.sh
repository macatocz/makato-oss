#!/usr/bin/env bash
# manage-stores-skill-tests.sh — offline assertions for the manage-stores SKILL.md (#565)
#
# Run from the makato repo root:
#   plugins/makato-plan/scripts/manage-stores-skill-tests.sh
#
# Assertions:
#   T1: SKILL.md exists and is non-empty
#   T2: SKILL.md has valid YAML frontmatter (--- delimited block at top)
#   T3: SKILL.md mentions the 'register' sub-command
#   T4: SKILL.md mentions the 'list' sub-command
#   T5: SKILL.md mentions the 'remove' sub-command
#   T6: SKILL.md references manage-stores.sh
#
# Fully offline: only reads the SKILL.md file.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_FILE="$REPO_ROOT/plugins/makato-plan/skills/manage-stores/SKILL.md"

fail() { echo "  FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

# ── T1: file exists and is non-empty ─────────────────────────────────────────
echo "=== T1: SKILL.md exists and is non-empty ==="
[ -f "$SKILL_FILE" ] || fail "T1: $SKILL_FILE does not exist"
[ -s "$SKILL_FILE" ] || fail "T1: $SKILL_FILE is empty"
pass "T1: SKILL.md exists and is non-empty"

# ── T2: valid YAML frontmatter (--- delimited block) ─────────────────────────
echo "=== T2: SKILL.md has valid YAML frontmatter ==="
# First line must be ---
head -1 "$SKILL_FILE" | grep -q "^---" \
  || fail "T2: SKILL.md does not start with YAML frontmatter (---)"
# Must have a closing ---
tail -n +2 "$SKILL_FILE" | grep -q "^---" \
  || fail "T2: SKILL.md frontmatter is not closed with ---"
# Must contain 'name:' in frontmatter
python3 - "$SKILL_FILE" << 'PY' || fail "T2: frontmatter missing 'name' field"
import sys

content = open(sys.argv[1]).read()
lines = content.splitlines()

# Extract frontmatter between first and second ---
if lines[0].strip() != "---":
    print("no opening ---", file=sys.stderr); sys.exit(1)

end_idx = None
for i, line in enumerate(lines[1:], start=1):
    if line.strip() == "---":
        end_idx = i
        break

if end_idx is None:
    print("no closing ---", file=sys.stderr); sys.exit(1)

fm_block = "\n".join(lines[1:end_idx])
assert "name:" in fm_block, "frontmatter missing 'name' field"
assert "description:" in fm_block, "frontmatter missing 'description' field"
PY
pass "T2: SKILL.md has valid YAML frontmatter with name and description"

# ── T3: 'register' sub-command mentioned ─────────────────────────────────────
echo "=== T3: SKILL.md mentions 'register' sub-command ==="
grep -qi "register" "$SKILL_FILE" \
  || fail "T3: 'register' sub-command not mentioned in SKILL.md"
pass "T3: 'register' sub-command mentioned"

# ── T4: 'list' sub-command mentioned ─────────────────────────────────────────
echo "=== T4: SKILL.md mentions 'list' sub-command ==="
grep -qi "\blist\b" "$SKILL_FILE" \
  || fail "T4: 'list' sub-command not mentioned in SKILL.md"
pass "T4: 'list' sub-command mentioned"

# ── T5: 'remove' sub-command mentioned ───────────────────────────────────────
echo "=== T5: SKILL.md mentions 'remove' sub-command ==="
grep -qi "remove" "$SKILL_FILE" \
  || fail "T5: 'remove' sub-command not mentioned in SKILL.md"
pass "T5: 'remove' sub-command mentioned"

# ── T6: manage-stores.sh referenced ──────────────────────────────────────────
echo "=== T6: SKILL.md references manage-stores.sh ==="
grep -q "manage-stores.sh" "$SKILL_FILE" \
  || fail "T6: manage-stores.sh not referenced in SKILL.md"
pass "T6: manage-stores.sh referenced"

# ── done ─────────────────────────────────────────────────────────────────────
echo ""
echo "All manage-stores SKILL.md tests passed."
