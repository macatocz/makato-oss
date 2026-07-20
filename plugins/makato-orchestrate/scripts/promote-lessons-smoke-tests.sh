#!/usr/bin/env bash
# Smoke tests for scripts/promote-lessons.sh.
#
# Run from the makato repo root:
#   plugins/makato-orchestrate/scripts/promote-lessons-smoke-tests.sh
#
# Scenarios:
#   T1: generalizable record from workflow-state is promoted
#   T2: local scope record is skipped
#   T3: duplicate bumps occurrences (no new line)
#   T4: change-lessons.jsonl source is read
#   T5: empty sources — script exits 0, procedural.jsonl untouched
#   T6: record with absent scope field is skipped
#   T7: multiple records — 2 generalizable + 1 local → exactly 2 in output
#
# Fully offline: uses a temp directory; no GitHub access, no git remote calls.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/makato-orchestrate/scripts/promote-lessons.sh"

SANDBOX="${CLAUDE_JOB_DIR:-/tmp}/promote-lessons-smoke-$$"
mkdir -p "$SANDBOX"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

fail() { echo "  FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

# ---------------------------------------------------------------------------
# _make_ws <dir> <issue> <lessons_json_array>
#   Write a minimal workflow-state-<issue>.json into <dir>/specs/test-<issue>/
# ---------------------------------------------------------------------------
_make_ws() {
  local sandbox_dir="$1" issue="$2" lessons_json="$3"
  local spec_dir="$sandbox_dir/specs/test-${issue}"
  mkdir -p "$spec_dir"
  printf '{"issue_number":%s,"lessons_learned":%s}\n' \
    "$issue" "$lessons_json" \
    > "$spec_dir/workflow-state-${issue}.json"
  echo "$spec_dir"
}

# ---------------------------------------------------------------------------
# T1: generalizable record from workflow-state is promoted
# ---------------------------------------------------------------------------
echo "=== T1: generalizable record promoted ==="
(
  D="$SANDBOX/t1"
  mkdir -p "$D"
  LESSON='[{"description":"Always use set -euo pipefail","tags":["shell"],"scope":"generalizable","cycle":1,"trigger":"review","ts":"2026-01-01T00:00:00Z","files_affected":[]}]'
  _make_ws "$D" 100 "$LESSON" > /dev/null
  MEM="$D/procedural.jsonl"
  MAKATO_PROMOTE_REPO_OVERRIDE="test/repo" \
    bash "$SCRIPT" 100 "$D/specs" "$MEM"
  [[ -f "$MEM" ]] || fail "T1: procedural.jsonl not created"
  COUNT=$(grep -c '"scope":"generalizable"' "$MEM" || echo 0)
  [[ "$COUNT" -eq 1 ]] || fail "T1: expected 1 record, got $COUNT"
  grep -q '"repo_sha"' "$MEM" || fail "T1: repo_sha missing"
  grep -q '"date"' "$MEM" || fail "T1: date missing"
  grep -q '"text":"Always use set -euo pipefail"' "$MEM" || fail "T1: text field missing or wrong"
)
pass "T1: generalizable record promoted"

# ---------------------------------------------------------------------------
# T2: local scope record is skipped
# ---------------------------------------------------------------------------
echo "=== T2: local scope skipped ==="
(
  D="$SANDBOX/t2"
  mkdir -p "$D"
  LESSON='[{"description":"This is a local note","tags":[],"scope":"local","cycle":1,"trigger":"review","ts":"2026-01-01T00:00:00Z","files_affected":[]}]'
  _make_ws "$D" 200 "$LESSON" > /dev/null
  MEM="$D/procedural.jsonl"
  MAKATO_PROMOTE_REPO_OVERRIDE="test/repo" \
    bash "$SCRIPT" 200 "$D/specs" "$MEM"
  # Either the file is not created or is empty (only touch-created)
  if [[ -f "$MEM" ]]; then
    CONTENT=$(grep -v '^$' "$MEM" || true)
    [[ -z "$CONTENT" ]] || fail "T2: expected empty file, got: $CONTENT"
  fi
)
pass "T2: local scope skipped"

# ---------------------------------------------------------------------------
# T3: duplicate bumps occurrences, no new line appended
# ---------------------------------------------------------------------------
echo "=== T3: duplicate bumps occurrences ==="
(
  D="$SANDBOX/t3"
  mkdir -p "$D"
  LESSON='[{"description":"Reuse existing helpers before writing new ones","tags":["design"],"scope":"generalizable","cycle":1,"trigger":"review","ts":"2026-01-01T00:00:00Z","files_affected":[]}]'
  _make_ws "$D" 300 "$LESSON" > /dev/null
  MEM="$D/procedural.jsonl"
  # First promotion
  MAKATO_PROMOTE_REPO_OVERRIDE="test/repo" \
    bash "$SCRIPT" 300 "$D/specs" "$MEM"
  [[ -f "$MEM" ]] || fail "T3: first run did not create file"
  LINES_AFTER_1=$(grep -c . "$MEM" || echo 0)
  [[ "$LINES_AFTER_1" -eq 1 ]] || fail "T3: expected 1 line after first run, got $LINES_AFTER_1"
  # Second promotion (same lesson)
  MAKATO_PROMOTE_REPO_OVERRIDE="test/repo" \
    bash "$SCRIPT" 300 "$D/specs" "$MEM"
  LINES_AFTER_2=$(grep -c . "$MEM" || echo 0)
  [[ "$LINES_AFTER_2" -eq 1 ]] || fail "T3: expected still 1 line after dedup, got $LINES_AFTER_2"
  OCC=$(python3 -c "import json; d=json.loads(open('$MEM').read().strip()); print(d['occurrences'])")
  [[ "$OCC" -eq 2 ]] || fail "T3: expected occurrences==2, got $OCC"
)
pass "T3: duplicate bumps occurrences"

# ---------------------------------------------------------------------------
# T4: change-lessons.jsonl source is read
# ---------------------------------------------------------------------------
echo "=== T4: change-lessons.jsonl source read ==="
(
  D="$SANDBOX/t4"
  mkdir -p "$D"
  spec_dir="$D/specs/test-400"
  mkdir -p "$spec_dir"
  # No workflow-state; only change-lessons.jsonl
  printf '{"text":"Always validate inputs at boundaries","tags":["validation"],"scope":"generalizable"}\n' \
    > "$spec_dir/change-lessons.jsonl"
  MEM="$D/procedural.jsonl"
  MAKATO_PROMOTE_REPO_OVERRIDE="test/repo" \
    bash "$SCRIPT" 400 "$D/specs" "$MEM"
  [[ -f "$MEM" ]] || fail "T4: procedural.jsonl not created"
  grep -q '"text":"Always validate inputs at boundaries"' "$MEM" || \
    fail "T4: change-lessons entry not promoted"
)
pass "T4: change-lessons.jsonl source read"

# ---------------------------------------------------------------------------
# T5: empty sources — script exits 0, procedural.jsonl has no records
# ---------------------------------------------------------------------------
echo "=== T5: empty sources no-op ==="
(
  D="$SANDBOX/t5"
  mkdir -p "$D/specs"
  MEM="$D/procedural.jsonl"
  # No spec folders matching issue 500 — script must exit 0
  MAKATO_PROMOTE_REPO_OVERRIDE="test/repo" \
    bash "$SCRIPT" 500 "$D/specs" "$MEM"
  # File may or may not exist; if it does it must be empty (no records promoted)
  if [[ -f "$MEM" ]]; then
    CONTENT=$(grep '"scope"' "$MEM" 2>/dev/null || true)
    [[ -z "$CONTENT" ]] || fail "T5: records written unexpectedly: $CONTENT"
  fi
)
pass "T5: empty sources — no-op, exit 0"

# ---------------------------------------------------------------------------
# T6: record with absent scope field is skipped
# ---------------------------------------------------------------------------
echo "=== T6: absent scope field skipped ==="
(
  D="$SANDBOX/t6"
  mkdir -p "$D"
  LESSON='[{"description":"A lesson with no scope field at all","tags":[],"cycle":1,"trigger":"review","ts":"2026-01-01T00:00:00Z","files_affected":[]}]'
  _make_ws "$D" 600 "$LESSON" > /dev/null
  MEM="$D/procedural.jsonl"
  MAKATO_PROMOTE_REPO_OVERRIDE="test/repo" \
    bash "$SCRIPT" 600 "$D/specs" "$MEM"
  if [[ -f "$MEM" ]]; then
    CONTENT=$(grep -v '^$' "$MEM" || true)
    [[ -z "$CONTENT" ]] || fail "T6: expected empty output, got: $CONTENT"
  fi
)
pass "T6: absent scope field skipped"

# ---------------------------------------------------------------------------
# T7: multiple records — 2 generalizable + 1 local → exactly 2 in output
# ---------------------------------------------------------------------------
echo "=== T7: multiple records — 2 generalizable + 1 local ==="
(
  D="$SANDBOX/t7"
  mkdir -p "$D"
  LESSONS='[
    {"description":"First generalizable lesson","tags":["a"],"scope":"generalizable","cycle":1,"trigger":"review","ts":"2026-01-01T00:00:00Z","files_affected":[]},
    {"description":"A local note to skip","tags":[],"scope":"local","cycle":1,"trigger":"review","ts":"2026-01-01T00:00:00Z","files_affected":[]},
    {"description":"Second generalizable lesson","tags":["b"],"scope":"generalizable","cycle":1,"trigger":"review","ts":"2026-01-01T00:00:00Z","files_affected":[]}
  ]'
  _make_ws "$D" 700 "$LESSONS" > /dev/null
  MEM="$D/procedural.jsonl"
  MAKATO_PROMOTE_REPO_OVERRIDE="test/repo" \
    bash "$SCRIPT" 700 "$D/specs" "$MEM"
  [[ -f "$MEM" ]] || fail "T7: procedural.jsonl not created"
  COUNT=$(grep -c '"scope":"generalizable"' "$MEM" || echo 0)
  [[ "$COUNT" -eq 2 ]] || fail "T7: expected 2 records, got $COUNT"
)
pass "T7: 2 generalizable promoted, 1 local skipped"

echo ""
echo "All promote-lessons-smoke-tests passed."
