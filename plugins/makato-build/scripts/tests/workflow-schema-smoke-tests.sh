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
#   T2 — absent schema returns built-in artifacts and execution defaults
#   T3 — custom unregistered skill remains supported with inherited settings
#   T4 — direct cycle exits 1 with cycle-detection error
#   T5 — transitive cycle exits 1 with full cycle path
#   T6 — empty schema exits 1 with parse error
#   T7 — execution-only local schema retains default artifacts
#   T8 — custom qualified skills and sections following artifacts are handled
#   T9 — invalid execution settings exit 1 with a useful error
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
rows = [json.loads(l) for l in sys.stdin.read().splitlines() if l.strip()]
custom = next((row for row in rows if row['id'] == 'security-scan'), None)
sys.exit(0 if custom and custom['role'] == 'DEFAULT' and custom['effort'] == 'inherit' else 1)
" 2>/dev/null; then
    _pass "extra artifact remains supported and receives inherited execution defaults"
  else
    _fail "custom artifact missing or has incorrect execution defaults"
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
# T7 — execution-only schema retains built-in artifacts and applies defaults
# ===========================================================================
echo "T7: execution-only schema retains default artifacts"
SB="$(_mk_sandbox)"
DEFAULT_OUTPUT="$(bash "$LOADER" "$SB" 2>/dev/null)"
DEFAULT_EXIT=$?
_mk_schema "$SB" "version: \"1.0\"
skill_execution:
  defaults:
    role: PLAN
    effort: high"
OUTPUT="$(bash "$LOADER" "$SB" 2>/dev/null)"
EXIT_CODE=$?
rm -rf "$SB"
if [[ "$EXIT_CODE" == "0" && "$DEFAULT_EXIT" == "0" ]] && printf '%s\n---\n%s\n' "$DEFAULT_OUTPUT" "$OUTPUT" | python3 -c "
import json, sys
base, configured = sys.stdin.read().split('\\n---\\n')
parse = lambda text: [json.loads(line) for line in text.splitlines() if line.strip()]
defaults, actual = parse(base), parse(configured)
sys.exit(0 if {x['id'] for x in defaults} == {x['id'] for x in actual}
         and all(x['role'] == 'PLAN' and x['effort'] == 'high' for x in actual) else 1)
" 2>/dev/null; then
  _pass "execution-only override keeps default artifact IDs and resolves skill defaults"
else
  _fail "execution-only schema lost default artifacts or failed to apply role/effort"
fi

# ===========================================================================
# T8 — qualified custom skill override after artifacts stays separate
# ===========================================================================
echo "T8: custom skill and sections after artifacts"
SB="$(_mk_sandbox)"
_mk_schema "$SB" "version: \"1.0\"
artifacts:
  - id: custom-security
    skill: my-plugin:security-audit
    required: true
    description: \"Original artifact description\"
skill_execution:
  defaults:
    role: PLAN
    effort: high
  skills:
    \"my-plugin:security-audit\":
      role: REVIEW
      effort: off"
OUTPUT="$(bash "$LOADER" "$SB" 2>/dev/null)"
EXIT_CODE=$?
rm -rf "$SB"
if [[ "$EXIT_CODE" == "0" ]] && echo "$OUTPUT" | python3 -c "
import json, sys
rows = [json.loads(line) for line in sys.stdin if line.strip()]
sys.exit(0 if len(rows) == 1 and rows[0]['skill'] == 'my-plugin:security-audit'
         and rows[0]['description'] == 'Original artifact description'
         and rows[0]['role'] == 'REVIEW' and rows[0]['effort'] == 'off' else 1)
" 2>/dev/null; then
  _pass "custom qualified skill resolves its own settings without altering artifact data"
else
  _fail "custom skill or post-artifact execution section was not handled correctly"
fi

# ===========================================================================
# T9 — invalid execution settings return a useful loader error
# ===========================================================================
echo "T9: invalid execution setting exits 1 with an error"
SB="$(_mk_sandbox)"
_mk_schema "$SB" "version: \"1.0\"
skill_execution:
  defaults:
    role: PLAN
    effort: impossible
artifacts:
  - id: refine
    skill: build-refine
    required: true"
set +e
STDERR_OUT="$(bash "$LOADER" "$SB" 2>&1 >/dev/null)"
EXIT_CODE=$?
set -e
rm -rf "$SB"
if [[ "$EXIT_CODE" == "1" ]] && echo "$STDERR_OUT" | grep -qi "effort\\|execution"; then
  _pass "invalid execution config exits 1 with a field-specific message"
else
  _fail "expected execution setting error, got exit $EXIT_CODE: $STDERR_OUT"
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
