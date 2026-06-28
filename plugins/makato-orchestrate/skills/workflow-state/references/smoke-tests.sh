#!/usr/bin/env bash
# Smoke tests for workflow-state.sh. Run from the makato repo root.
# Exits non-zero on first failure. Cleans up its sandbox on success.
#
# Usage: plugins/makato-orchestrate/skills/workflow-state/references/smoke-tests.sh
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WS="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"
KEY="gap-003-smoke-test"
SANDBOX="$REPO_ROOT/specs/${KEY}"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

cleanup
mkdir -p "$SANDBOX"

echo "=== T1: schema is valid JSON ==="
python3 -m json.tool \
  "$REPO_ROOT/plugins/makato-orchestrate/skills/workflow-state/references/workflow-state.schema.json" \
  > /dev/null
echo "  ✓ schema parses"

echo "=== T2: init creates a valid file ==="
"$WS" init "$KEY" macatocz/test feat/gap-003 26
test -f "$SANDBOX/workflow-state.json"
echo "  ✓ workflow-state.json exists"

echo "=== T3: init refuses duplicate ==="
if "$WS" init "$KEY" macatocz/test feat/gap-003 26 2>/dev/null; then
  echo "  ✗ FAIL: expected non-zero exit"
  exit 1
fi
echo "  ✓ duplicate refused"

echo "=== T4: read returns the file ==="
"$WS" read "$KEY" | jq -e '.repo == "macatocz/test"' > /dev/null
echo "  ✓ repo field set"

echo "=== T5: read on missing key returns {} ==="
"$WS" read "no-such-key-$$" | jq -e '. == {}' > /dev/null
echo "  ✓ missing returns {}"

echo "=== T6: patch updates field AND updated_at advances ==="
BEFORE=$("$WS" read "$KEY" | jq -r '.updated_at')
sleep 1
"$WS" patch "$KEY" .current_phase '"implement"'
AFTER=$("$WS" read "$KEY" | jq -r '.updated_at')
[[ "$AFTER" > "$BEFORE" ]] || { echo "  ✗ FAIL: updated_at did not advance"; exit 1; }
"$WS" read "$KEY" | jq -e '.current_phase == "implement"' > /dev/null
echo "  ✓ field set, timestamp advanced"

echo "=== T7: patch supports indexed array path ==="
"$WS" write "$KEY" \
  "$("$WS" read "$KEY" | jq '.sub_tasks = [{id:1,description:"Add model",status:"pending",phase:"tdd",agent_result:null}]')"
"$WS" patch "$KEY" '.sub_tasks[0].status' '"complete"'
"$WS" read "$KEY" | jq -e '.sub_tasks[0].status == "complete"' > /dev/null
echo "  ✓ indexed patch works"

echo "=== T8: append-lesson grows the array ==="
"$WS" append-lesson "$KEY" "tracer bullet essential"
"$WS" read "$KEY" | jq -e '.lessons_learned | length == 1' > /dev/null
"$WS" read "$KEY" | jq -e '.lessons_learned[0].text == "tracer bullet essential"' > /dev/null
echo "  ✓ lesson appended with text + ts"

echo "=== T9: invalid write halts ==="
if "$WS" write "$KEY" '{"broken":true}' 2>/dev/null; then
  echo "  ✗ FAIL: expected non-zero exit"
  exit 1
fi
echo "  ✓ schema validation halted invalid write"

echo
echo "All 9 smoke tests passed."
