#!/usr/bin/env bash
# Smoke tests for scripts/manage-stores.sh (#565 — cross-repo store management).
#
# Run from the makato repo root:
#   plugins/makato-plan/scripts/manage-stores-smoke-tests.sh
#
# Scenarios:
#   T1: missing args exits 1 with usage message
#   T2: unknown command exits 1 with informative error
#   T3: register appends entry to empty stores[]
#   T4: register on missing config.json creates file with empty stores[] then adds entry
#   T5: register updates existing entry in-place without duplicating
#   T6: list outputs id, repo, description for each entry, one per line
#   T7: remove deletes matching entry; remaining entries are unchanged
#   T8: remove nonexistent id exits 1 with informative error
#   T9: JSON is valid after each mutation (python3 -m json.tool)
#   T10: register with two pre-existing stores leaves both intact
#
# Fully offline: all inputs written to a temp sandbox; no real .claude/config.json mutated.
# Mirrors mark-ac-checkboxes-smoke-tests.sh conventions.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/makato-plan/scripts/manage-stores.sh"

SANDBOX="${CLAUDE_JOB_DIR:-/tmp}/manage-stores-smoke-$$"
mkdir -p "$SANDBOX"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

fail() { echo "  FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

# ── helpers ──────────────────────────────────────────────────────────────────

CONFIG="$SANDBOX/.claude/config.json"

reset_config_empty() {
  mkdir -p "$SANDBOX/.claude"
  cat > "$CONFIG" << 'EOF'
{
  "project": "fixture-project",
  "stores": []
}
EOF
}

reset_config_one_store() {
  mkdir -p "$SANDBOX/.claude"
  cat > "$CONFIG" << 'EOF'
{
  "project": "fixture-project",
  "stores": [
    {
      "id": "platform",
      "repo": "macatocz/platform",
      "description": "Platform repo"
    }
  ]
}
EOF
}

reset_config_two_stores() {
  mkdir -p "$SANDBOX/.claude"
  cat > "$CONFIG" << 'EOF'
{
  "project": "fixture-project",
  "stores": [
    {
      "id": "platform",
      "repo": "macatocz/platform",
      "description": "Platform repo"
    },
    {
      "id": "infra",
      "repo": "macatocz/infra",
      "description": "Infrastructure repo"
    }
  ]
}
EOF
}

assert_valid_json() {
  python3 -m json.tool "$CONFIG" > /dev/null 2>&1 \
    || fail "$1: config.json is not valid JSON after mutation"
}

# ── T1: missing args exits 1 ─────────────────────────────────────────────────
echo "=== T1: missing args exits 1 ==="
if MANAGE_STORES_CONFIG="$CONFIG" "$SCRIPT" 2>/dev/null; then
  fail "T1: expected non-zero exit on missing args"
fi
pass "T1: missing args rejected"

# ── T2: unknown command exits 1 ──────────────────────────────────────────────
echo "=== T2: unknown command exits 1 ==="
reset_config_empty
if MANAGE_STORES_CONFIG="$CONFIG" "$SCRIPT" frobnicate 2>/dev/null; then
  fail "T2: expected non-zero exit on unknown command"
fi
pass "T2: unknown command rejected"

# ── T3: register appends entry to empty stores[] ─────────────────────────────
echo "=== T3: register appends entry to empty stores[] ==="
reset_config_empty
MANAGE_STORES_CONFIG="$CONFIG" "$SCRIPT" register platform macatocz/platform "Platform repo" \
  || fail "T3: register exited non-zero"
assert_valid_json "T3"
python3 - "$CONFIG" << 'PY' || fail "T3: entry not found in stores[]"
import json, sys
data = json.load(open(sys.argv[1]))
stores = data.get("stores", [])
assert len(stores) == 1, f"expected 1 store, got {len(stores)}"
assert stores[0]["id"] == "platform", f"id mismatch: {stores[0]}"
assert stores[0]["repo"] == "macatocz/platform", f"repo mismatch: {stores[0]}"
assert stores[0]["description"] == "Platform repo", f"description mismatch: {stores[0]}"
PY
pass "T3: register appends entry to empty stores[]"

# ── T4: missing config.json created with empty stores[] on first register ─────
echo "=== T4: missing config.json created on first register ==="
rm -rf "$SANDBOX/.claude"
mkdir -p "$SANDBOX/.claude"
MANAGE_STORES_CONFIG="$CONFIG" "$SCRIPT" register newstore macatocz/newrepo "New repo" \
  || fail "T4: register exited non-zero"
[ -f "$CONFIG" ] || fail "T4: config.json not created"
assert_valid_json "T4"
python3 - "$CONFIG" << 'PY' || fail "T4: entry not found after creation"
import json, sys
data = json.load(open(sys.argv[1]))
assert "stores" in data, "stores key missing"
stores = data["stores"]
assert len(stores) == 1, f"expected 1 store, got {len(stores)}"
assert stores[0]["id"] == "newstore"
PY
pass "T4: missing config.json created with entry on first register"

# ── T5: register updates existing entry in-place without duplicating ──────────
echo "=== T5: register updates existing entry in-place ==="
reset_config_one_store
MANAGE_STORES_CONFIG="$CONFIG" "$SCRIPT" register platform macatocz/platform-v2 "Platform v2" \
  || fail "T5: register exited non-zero"
assert_valid_json "T5"
python3 - "$CONFIG" << 'PY' || fail "T5: entry not updated correctly"
import json, sys
data = json.load(open(sys.argv[1]))
stores = data.get("stores", [])
assert len(stores) == 1, f"expected 1 store (no dup), got {len(stores)}"
assert stores[0]["repo"] == "macatocz/platform-v2", f"repo not updated: {stores[0]}"
assert stores[0]["description"] == "Platform v2", f"description not updated: {stores[0]}"
PY
pass "T5: register updates existing entry in-place without duplicating"

# ── T6: list outputs id, repo, description for each entry ────────────────────
echo "=== T6: list outputs id, repo, description ==="
reset_config_two_stores
OUT="$(MANAGE_STORES_CONFIG="$CONFIG" "$SCRIPT" list)"
echo "$OUT" | grep -q "platform" || fail "T6: 'platform' not in list output"
echo "$OUT" | grep -q "macatocz/platform" || fail "T6: platform repo not in list output"
echo "$OUT" | grep -q "Platform repo" || fail "T6: platform description not in list output"
echo "$OUT" | grep -q "infra" || fail "T6: 'infra' not in list output"
echo "$OUT" | grep -q "macatocz/infra" || fail "T6: infra repo not in list output"
pass "T6: list outputs all entries with id, repo, description"

# ── T7: remove deletes matching entry; remaining entries unchanged ─────────────
echo "=== T7: remove deletes matching entry ==="
reset_config_two_stores
MANAGE_STORES_CONFIG="$CONFIG" "$SCRIPT" remove platform \
  || fail "T7: remove exited non-zero"
assert_valid_json "T7"
python3 - "$CONFIG" << 'PY' || fail "T7: stores not correct after remove"
import json, sys
data = json.load(open(sys.argv[1]))
stores = data.get("stores", [])
ids = [s["id"] for s in stores]
assert "platform" not in ids, f"platform still present after remove: {ids}"
assert "infra" in ids, f"infra missing after remove: {ids}"
assert len(stores) == 1, f"expected 1 remaining store, got {len(stores)}"
PY
pass "T7: remove deletes matching entry; remaining entries unchanged"

# ── T8: remove nonexistent id exits 1 with informative error ─────────────────
echo "=== T8: remove nonexistent exits 1 ==="
reset_config_empty
ERR_OUT="$(MANAGE_STORES_CONFIG="$CONFIG" "$SCRIPT" remove nonexistent 2>&1)" \
  && fail "T8: expected non-zero exit on missing id" || true
echo "$ERR_OUT" | grep -qi "nonexistent\|not found\|no store" \
  || fail "T8: error message not informative: $ERR_OUT"
pass "T8: remove nonexistent exits 1 with informative error"

# ── T9: JSON valid after each mutation (integration round-trip) ───────────────
echo "=== T9: JSON valid after each mutation ==="
reset_config_empty
MANAGE_STORES_CONFIG="$CONFIG" "$SCRIPT" register alpha acme/alpha "Alpha store" \
  || fail "T9 register1: exited non-zero"
assert_valid_json "T9 after first register"
MANAGE_STORES_CONFIG="$CONFIG" "$SCRIPT" register beta acme/beta "Beta store" \
  || fail "T9 register2: exited non-zero"
assert_valid_json "T9 after second register"
MANAGE_STORES_CONFIG="$CONFIG" "$SCRIPT" register alpha acme/alpha-v2 "Alpha v2" \
  || fail "T9 update: exited non-zero"
assert_valid_json "T9 after update"
MANAGE_STORES_CONFIG="$CONFIG" "$SCRIPT" remove beta \
  || fail "T9 remove: exited non-zero"
assert_valid_json "T9 after remove"
python3 - "$CONFIG" << 'PY' || fail "T9: final state incorrect"
import json, sys
data = json.load(open(sys.argv[1]))
stores = data["stores"]
ids = [s["id"] for s in stores]
assert "alpha" in ids, f"alpha missing: {ids}"
assert "beta" not in ids, f"beta still present: {ids}"
assert len(stores) == 1, f"expected 1 store, got {len(stores)}"
PY
pass "T9: JSON valid after every mutation in round-trip sequence"

# ── T10: register with two pre-existing stores leaves both intact ─────────────
echo "=== T10: register adds third store; pre-existing two intact ==="
reset_config_two_stores
MANAGE_STORES_CONFIG="$CONFIG" "$SCRIPT" register docs macatocz/docs "Docs repo" \
  || fail "T10: register exited non-zero"
assert_valid_json "T10"
python3 - "$CONFIG" << 'PY' || fail "T10: stores not correct"
import json, sys
data = json.load(open(sys.argv[1]))
stores = data.get("stores", [])
ids = [s["id"] for s in stores]
assert len(stores) == 3, f"expected 3 stores, got {len(stores)}: {ids}"
assert "platform" in ids
assert "infra" in ids
assert "docs" in ids
PY
pass "T10: register adds third store; pre-existing two stores intact"

# ── done ─────────────────────────────────────────────────────────────────────
echo ""
echo "All manage-stores smoke tests passed."
