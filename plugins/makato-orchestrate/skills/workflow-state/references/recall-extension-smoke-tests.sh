#!/usr/bin/env bash
# Smoke tests for recall-lessons extension (#470):
#   T59 — AC-2 backward-compat 2-arg call
#   T60 — AC-1 bundle filter excludes non-matching
#   T61 — AC-1 ordering: scope asc, occurrences DESC
#   T62 — AC-3 no memory store returns []
#   T63 — AC-4 malformed JSONL line skipped
#   T64 — T5 semantic.jsonl lessons appear in recall
#
# Run from any directory inside the makato worktree.
# Exits non-zero on first failure. Cleans up on EXIT.
set -euo pipefail

# workflow-state.sh resolves REPO_ROOT via git-common-dir so it always points
# to the main checkout regardless of whether we're in a worktree.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$SCRIPT_DIR/../../../shared/workflow-state.sh"
# REPO_ROOT must also be the main checkout for specs/ and .makato/
GIT_COMMON="$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir)"
REPO_ROOT="$(cd "$GIT_COMMON/.." && pwd)"

KEY="470-recall-ext-smoke"
SANDBOX="$REPO_ROOT/specs/${KEY}"
MEMORY_DIR="$REPO_ROOT/.makato/memory"

cleanup() {
  rm -rf "$SANDBOX"
  # Restore committed store backups
  [[ -f "$MEMORY_DIR/semantic.jsonl.bak" ]] && mv "$MEMORY_DIR/semantic.jsonl.bak" "$MEMORY_DIR/semantic.jsonl" || true
  [[ -f "$MEMORY_DIR/procedural.jsonl.bak" ]] && mv "$MEMORY_DIR/procedural.jsonl.bak" "$MEMORY_DIR/procedural.jsonl" || true
  [[ -d "${MEMORY_DIR}.hidden" ]] && mv "${MEMORY_DIR}.hidden" "$MEMORY_DIR" || true
}
trap cleanup EXIT

cleanup
mkdir -p "$SANDBOX"

# Backup committed store
cp "$MEMORY_DIR/semantic.jsonl" "$MEMORY_DIR/semantic.jsonl.bak"
cp "$MEMORY_DIR/procedural.jsonl" "$MEMORY_DIR/procedural.jsonl.bak"

# --- Seed workflow-state with lessons for filter tests ---
"$WS" init "$KEY" macatocz/makato feat/470-test 9001

# Seed python-bundle lesson (generalizable scope, occurrences 3)
"$WS" append-lesson "$KEY" 9001 0 ci_failure "python-specific ci pattern"
python3 -c "
import json, pathlib
p = pathlib.Path('$SANDBOX/workflow-state-9001.json')
s = json.loads(p.read_text())
s['lessons_learned'][0]['bundle'] = 'python'
s['lessons_learned'][0]['scope'] = 'generalizable'
s['lessons_learned'][0]['occurrences'] = 3
p.write_text(json.dumps(s, indent=2))
"

# Seed infra-only lesson (local scope, occurrences 1)
"$WS" append-lesson "$KEY" 9001 0 halt "infra-only pattern"
python3 -c "
import json, pathlib
p = pathlib.Path('$SANDBOX/workflow-state-9001.json')
s = json.loads(p.read_text())
s['lessons_learned'][1]['bundle'] = 'infra'
s['lessons_learned'][1]['scope'] = 'local'
s['lessons_learned'][1]['occurrences'] = 1
p.write_text(json.dumps(s, indent=2))
"

echo "=== T59: AC-2 — 2-arg backward-compat call returns all repo lessons ==="
RESULT=$("$WS" recall-lessons macatocz/makato 5)
echo "$RESULT" | jq -e 'type == "array"' > /dev/null || { echo "  ✗ FAIL: result not array"; exit 1; }
PY=$(echo "$RESULT" | jq '[.[] | select(.description == "python-specific ci pattern")] | length')
INFRA=$(echo "$RESULT" | jq '[.[] | select(.description == "infra-only pattern")] | length')
[[ "$PY" -ge 1 ]] || { echo "  ✗ FAIL: python lesson missing from unfiltered recall"; exit 1; }
[[ "$INFRA" -ge 1 ]] || { echo "  ✗ FAIL: infra lesson missing from unfiltered recall"; exit 1; }
echo "  ✓ 2-arg call returns all repo lessons (backward-compat preserved)"

echo "=== T60: AC-1 — --bundles python excludes infra-only lesson ==="
RESULT=$("$WS" recall-lessons macatocz/makato 5 --bundles python)
PY=$(echo "$RESULT" | jq '[.[] | select(.description == "python-specific ci pattern")] | length')
INFRA=$(echo "$RESULT" | jq '[.[] | select(.description == "infra-only pattern")] | length')
[[ "$PY" -ge 1 ]] || { echo "  ✗ FAIL: python lesson missing from bundle-filtered recall"; exit 1; }
[[ "$INFRA" == "0" ]] || { echo "  ✗ FAIL: infra lesson leaked into python-filtered recall"; exit 1; }
echo "  ✓ --bundles python filters out infra-only lesson"

echo "=== T61: AC-1 — ordering: generalizable scope before local ==="
# Add a second python lesson with scope:local, occurrences:5 (higher than first)
"$WS" append-lesson "$KEY" 9001 1 ci_failure "python local pattern"
python3 -c "
import json, pathlib
p = pathlib.Path('$SANDBOX/workflow-state-9001.json')
s = json.loads(p.read_text())
s['lessons_learned'][-1]['bundle'] = 'python'
s['lessons_learned'][-1]['scope'] = 'local'
s['lessons_learned'][-1]['occurrences'] = 5
p.write_text(json.dumps(s, indent=2))
"
RESULT=$("$WS" recall-lessons macatocz/makato 10 --bundles python)
# scope asc: generalizable (g < l alphabetically) must come before local
FIRST_SCOPE=$(echo "$RESULT" | jq -r 'map(select(.bundle == "python")) | .[0].scope // "unknown"')
[[ "$FIRST_SCOPE" == "generalizable" ]] || { echo "  ✗ FAIL: scope sort wrong, expected generalizable first, got $FIRST_SCOPE"; exit 1; }
echo "  ✓ generalizable scope sorts before local (scope asc)"

echo "=== T62: AC-3 — [] returned when .makato/memory/ does not exist ==="
# AC-3: "Given .makato/memory/ does not exist, when recall runs for that repo,
# then it exits 0 and returns an empty lesson set."
# Use a repo name that has no workflow-state files at all, so the only possible
# source is the committed store — which we hide. Confirms no-store → [].
mv "$MEMORY_DIR" "${MEMORY_DIR}.hidden"
RESULT=$("$WS" recall-lessons macatocz/makato-no-such-repo 5) || true
mv "${MEMORY_DIR}.hidden" "$MEMORY_DIR"
echo "$RESULT" | jq -e '. == []' > /dev/null || { echo "  ✗ FAIL: expected [], got: $RESULT"; exit 1; }
echo "  ✓ [] when .makato/memory/ absent and no workflow-state lessons for repo"

echo "=== T63: AC-4 — malformed JSONL line skipped, readable lessons returned ==="
# Three lines: good, bad, good
printf '%s\n%s\n%s\n' \
  '{"ts":"2026-07-19T00:00:00.000Z","repo":"macatocz/makato","bundle":"python","scope":"generalizable","occurrences":2,"description":"first readable","trigger":"ci_failure","cycle":0,"files_affected":[]}' \
  'THIS IS NOT JSON --- malformed' \
  '{"ts":"2026-07-19T01:00:00.000Z","repo":"macatocz/makato","bundle":"python","scope":"generalizable","occurrences":1,"description":"second readable","trigger":"halt","cycle":0,"files_affected":[]}' \
  > "$MEMORY_DIR/procedural.jsonl"
RESULT=$("$WS" recall-lessons macatocz/makato 10)
FR=$(echo "$RESULT" | jq '[.[] | select(.description == "first readable")] | length')
SR=$(echo "$RESULT" | jq '[.[] | select(.description == "second readable")] | length')
[[ "$FR" == "1" ]] || { echo "  ✗ FAIL: first readable lesson missing (got $FR)"; exit 1; }
[[ "$SR" == "1" ]] || { echo "  ✗ FAIL: second readable lesson missing (got $SR)"; exit 1; }
# Restore procedural.jsonl
> "$MEMORY_DIR/procedural.jsonl"
echo "  ✓ malformed JSONL line skipped, 2 readable lessons returned"

echo "=== T64: T5 — semantic.jsonl entries appear in recall ==="
printf '%s\n' \
  '{"ts":"2026-07-19T10:00:00.000Z","repo":"macatocz/makato","bundle":"infra","scope":"generalizable","occurrences":1,"description":"committed semantic lesson","trigger":"halt","cycle":0,"files_affected":[]}' \
  > "$MEMORY_DIR/semantic.jsonl"
RESULT=$("$WS" recall-lessons macatocz/makato 10)
SEM=$(echo "$RESULT" | jq '[.[] | select(.description == "committed semantic lesson")] | length')
[[ "$SEM" == "1" ]] || { echo "  ✗ FAIL: semantic.jsonl lesson not in recall (got $SEM)"; exit 1; }
> "$MEMORY_DIR/semantic.jsonl"
echo "  ✓ .makato/memory/semantic.jsonl lessons appear in recall"

echo
echo "All 6 recall-extension smoke tests (T59-T64) passed."
