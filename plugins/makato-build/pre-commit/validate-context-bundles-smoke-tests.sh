#!/usr/bin/env bash
# Smoke tests for plugins/makato-build/pre-commit/validate-context-bundles.sh (#324).
#
# Exercises every HALT-006 condition the gate must catch plus the happy-path
# and no-files-to-check cases. Pure bash + temp files — no network, no gh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/validate-context-bundles.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

_pass() { printf '  ✓ %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  ✗ %s\n' "$1"; fail=$((fail + 1)); }

check() {
  local label="$1" want_exit="$2" file="$3"
  local rc
  set +e
  bash "$GATE" "$file" >/dev/null 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq "$want_exit" ]; then
    _pass "$label (exit $rc)"
  else
    _fail "$label: expected exit $want_exit, got $rc"
  fi
}

# --- T1: valid canonical config → exit 0 -----------------------------------
echo "T1: canonical config with default bundle"
cat > "$TMP/valid.yml" <<'YAML'
version: "1.0"
bundles:
  - name: python
    globs: ["**/*.py"]
    rules: ["rules/python.md"]
  - name: default
    globs: ["**/*"]
    rules: ["rules/default.md"]
YAML
check "T1 valid config" 0 "$TMP/valid.yml"

# --- T2: missing default bundle → exit 1 ------------------------------------
echo "T2: config missing default bundle"
cat > "$TMP/no-default.yml" <<'YAML'
version: "1.0"
bundles:
  - name: python
    globs: ["**/*.py"]
    rules: ["rules/python.md"]
YAML
check "T2 missing default" 1 "$TMP/no-default.yml"

# --- T3: duplicate bundle name → exit 1 -------------------------------------
echo "T3: config with duplicate bundle name"
cat > "$TMP/dup-name.yml" <<'YAML'
version: "1.0"
bundles:
  - name: python
    globs: ["**/*.py"]
    rules: ["rules/A.md"]
  - name: python
    globs: ["**/*.py"]
    rules: ["rules/B.md"]
  - name: default
    globs: ["**/*"]
    rules: ["rules/default.md"]
YAML
check "T3 duplicate name" 1 "$TMP/dup-name.yml"

# --- T4: bundle missing name field → exit 1 ----------------------------------
echo "T4: config with bundle entry missing name field"
cat > "$TMP/no-name.yml" <<'YAML'
version: "1.0"
bundles:
  - globs: ["**/*.py"]
    rules: ["rules/python.md"]
  - name: default
    globs: ["**/*"]
    rules: ["rules/default.md"]
YAML
check "T4 missing name field" 1 "$TMP/no-name.yml"

# --- T5: no files to check → exit 0 -----------------------------------------
echo "T5: no files argument (no staged files context)"
# Pass no arguments at all — the script must exit 0 immediately.
# We simulate this by directly calling with zero extra args (not via git).
# Since git diff --cached finds nothing outside a repo commit, we rely on
# the argument-less path. Run from the TMP dir (no git repo) so git diff
# returns nothing and files=() → early exit 0.
rc=0
set +e
(cd "$TMP" && bash "$GATE") >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  _pass "T5 no staged files → exit 0"
else
  _fail "T5 no staged files: expected exit 0, got $rc"
fi

# --- T6: non-existent file path → exit 2 -------------------------------------
echo "T6: non-existent file path"
check "T6 missing file" 2 "$TMP/does-not-exist.yml"

# --- T7: production context-bundles.yml passes --------------------------------
echo "T7: production config/context-bundles.yml"
PROD_CONFIG="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)/plugins/makato-build/config/context-bundles.yml"
if [ -f "$PROD_CONFIG" ]; then
  check "T7 production config" 0 "$PROD_CONFIG"
else
  _pass "T7 production config not found — skipped"
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All $pass validate-context-bundles smoke tests passed."
  exit 0
else
  echo "$fail/$((pass + fail)) validate-context-bundles smoke test(s) failed."
  exit 1
fi
