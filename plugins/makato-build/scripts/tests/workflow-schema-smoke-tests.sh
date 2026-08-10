#!/usr/bin/env bash
# Smoke tests for workflow-schema-loader.sh (#563).
#
# workflow-schema-loader.sh resolves the workflow schema from either
# .claude/workflow-schema.yml (custom) or the built-in default, validates the
# artifact DAG for cycles, and prints an ordered JSON-per-line artifact list.
#
# All tests are fully offline — they use temp directories with fixture YAML
# files. No network, no git, no gh required.
#
# Coverage:
#   T1 — missing args exits 2 (usage error)
#   T2 — schema file absent → returns built-in default artifact list (exit 0)
#   T3 — valid custom schema with extra artifact → list contains the extra step
#   T4 — schema with a direct cycle → exits 1 with cycle-detection error
#   T5 — schema with a transitive cycle → exits 1 with full cycle path in error
#   T6 — empty schema file → exits 1 with parse error (not a crash)
#
# Exit code: number of failures; 0 = all green.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOADER="$SCRIPT_DIR/../workflow-schema-loader.sh"
FAIL=0

_pass() { printf '  ok  %s\n' "$1"; }
_fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Guard: loader must exist
# ---------------------------------------------------------------------------
if [[ ! -f "$LOADER" ]]; then
  printf 'FATAL: cannot find workflow-schema-loader.sh at %s\n' "$LOADER" >&2
  exit 99
fi

# ---------------------------------------------------------------------------
# Helper: create a temp sandbox with an optional .claude/workflow-schema.yml
# ---------------------------------------------------------------------------
_mk_sandbox() {
  local root
  root="$(mktemp -d)"
  mkdir -p "$root/.claude"
  echo "$root"
}

_mk_schema() {
  local sandbox="$1"
  local content="$2"
  printf '%s\n' "$content" > "$sandbox/.claude/workflow-schema.yml"
}

# ===========================================================================
# T1 — missing args exits 2
# ===========================================================================
echo "T1: missing args exits 2"
set +e
bash "$LOADER" 2>/dev/null
EXIT_CODE=$?
set -e
if [[ "$EXIT_CODE" == "2" ]]; then
  _pass "exit code 2 on missing args"
else
  _fail "expected exit 2, got $EXIT_CODE"
fi

# ===========================================================================
# T2 — schema absent → built-in default artifact list (exit 0)
# ===========================================================================
echo "T2: schema absent → built-in default (exit 0)"
SB="$(_mk_sandbox)"
set +e
OUTPUT="$(bash "$LOADER" "$SB" 2>/dev/null)"
EXIT_CODE=$?
set -e
rm -rf "$SB"
if [[ "$EXIT_CODE" == "0" ]]; then
  # Must contain at least: refine, verify, push-to-git (default pipeline IDs)
  if echo "$OUTPUT" | python3 -c "
import sys, json
lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
ids = [json.loads(l)['id'] for l in lines]
required = {'refine', 'verify', 'push-to-git', 'create-pr', 'sensors'}
missing = required - set(ids)
sys.exit(1 if missing else 0)
" 2>/dev/null; then
    _pass "default artifact list contains all expected IDs"
  else
    _fail "default artifact list missing expected IDs — got: $(echo "$OUTPUT" | python3 -c "import sys,json; [print(json.loads(l)['id']) for l in sys.stdin if l.strip()]" 2>/dev/null | tr '\n' ' ')"
  fi
else
  _fail "expected exit 0 for absent schema, got $EXIT_CODE"
fi

# ===========================================================================
# T3 — valid custom schema with extra artifact → list contains extra step
# ===========================================================================
echo "T3: valid custom schema with extra artifact"
SB="$(_mk_sandbox)"
_mk_schema "$SB" "version: \"1.0\"
artifacts:
  - id: refine
    skill: build-refine
    required: true
  - id: implement-tdd
    skill: build-implement-tdd
    required: false
    after: [refine]
  - id: security-scan
    skill: security-audit
    required: true
    description: \"Custom security scan\"
    after: [implement-tdd]
  - id: verify
    skill: build-verify
    required: true
    after: [security-scan]"
set +e
OUTPUT="$(bash "$LOADER" "$SB" 2>/dev/null)"
EXIT_CODE=$?
set -e
rm -rf "$SB"
if [[ "$EXIT_CODE" == "0" ]]; then
  if echo "$OUTPUT" | python3 -c "
import sys, json
lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
ids = [json.loads(l)['id'] for l in lines]
sys.exit(0 if 'security-scan' in ids else 1)
" 2>/dev/null; then
    _pass "extra artifact 'security-scan' present in resolved list"
  else
    _fail "extra artifact 'security-scan' NOT found in resolved list"
  fi
else
  _fail "expected exit 0 for valid custom schema, got $EXIT_CODE"
fi

# ===========================================================================
# T4 — direct cycle A→B→A → exits 1 with cycle-detection error
# ===========================================================================
echo "T4: direct cycle → exits 1 with cycle error"
SB="$(_mk_sandbox)"
_mk_schema "$SB" "version: \"1.0\"
artifacts:
  - id: step-a
    skill: build-refine
    required: true
    after: [step-b]
  - id: step-b
    skill: build-verify
    required: true
    after: [step-a]"
set +e
STDERR_OUT="$(bash "$LOADER" "$SB" 2>&1 >/dev/null)"
EXIT_CODE=$?
set -e
rm -rf "$SB"
if [[ "$EXIT_CODE" == "1" ]]; then
  if echo "$STDERR_OUT" | grep -qi "cycle"; then
    _pass "exits 1 with cycle-detection error message"
  else
    _fail "exits 1 but no 'cycle' keyword in stderr: $STDERR_OUT"
  fi
else
  _fail "expected exit 1 for direct cycle, got $EXIT_CODE"
fi

# ===========================================================================
# T5 — transitive cycle A→C→B→A → exits 1 with full cycle path
# ===========================================================================
echo "T5: transitive cycle → exits 1 with full cycle path"
SB="$(_mk_sandbox)"
_mk_schema "$SB" "version: \"1.0\"
artifacts:
  - id: step-a
    skill: build-refine
    required: true
    after: [step-c]
  - id: step-b
    skill: build-verify
    required: true
    after: [step-a]
  - id: step-c
    skill: build-sensors
    required: true
    after: [step-b]"
set +e
STDERR_OUT="$(bash "$LOADER" "$SB" 2>&1 >/dev/null)"
EXIT_CODE=$?
set -e
rm -rf "$SB"
if [[ "$EXIT_CODE" == "1" ]]; then
  # The cycle path must contain at least 3 of the 3 node IDs
  NODES_FOUND=0
  for node in step-a step-b step-c; do
    echo "$STDERR_OUT" | grep -q "$node" && NODES_FOUND=$((NODES_FOUND + 1))
  done
  if [[ "$NODES_FOUND" -ge 3 ]]; then
    _pass "exits 1 with full cycle path containing all node IDs"
  else
    _fail "cycle path incomplete — only $NODES_FOUND/3 node IDs in: $STDERR_OUT"
  fi
else
  _fail "expected exit 1 for transitive cycle, got $EXIT_CODE"
fi

# ===========================================================================
# T6 — empty schema file → exits 1 with parse error (not a crash)
# ===========================================================================
echo "T6: empty schema file → exits 1 with parse error"
SB="$(_mk_sandbox)"
touch "$SB/.claude/workflow-schema.yml"   # empty file, 0 bytes
set +e
STDERR_OUT="$(bash "$LOADER" "$SB" 2>&1 >/dev/null)"
EXIT_CODE=$?
set -e
rm -rf "$SB"
if [[ "$EXIT_CODE" == "1" ]]; then
  if echo "$STDERR_OUT" | grep -qi "parse error\|empty"; then
    _pass "exits 1 with descriptive parse/empty error"
  else
    _fail "exits 1 but no 'parse error' or 'empty' in stderr: $STDERR_OUT"
  fi
else
  _fail "expected exit 1 for empty schema, got $EXIT_CODE"
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
