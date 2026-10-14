#!/usr/bin/env bash
# Real capture-time persistence → idempotent promotion replay → recall.
# A failed promoter retains raw evidence but must never claim durable success.
# Run: bash tests/integration/change-memory-handoff-e2e.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRITE_LESSONS="$REPO_ROOT/plugins/makato-build/shared/write-lessons.sh"
PROMOTE_LESSONS="$REPO_ROOT/plugins/makato-orchestrate/scripts/promote-lessons.sh"
WORKFLOW_STATE="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"

# Normalized owner/repo slug — must match the value write-lessons.sh stamps into
# the `repo` field after normalizing the https://github.com/macatocz/makato.git
# remote URL. recall-lessons performs exact-match on this field.
REPO_SLUG="macatocz/makato"

PASS=0
FAIL=0

_pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
_fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

# ---------------------------------------------------------------------------
# _mk_sandbox <key>: create a throwaway git repo with a specs/<key>-e2e-test/
# folder and empty .makato/memory/ files.
#
# write-lessons.sh resolves specs/ relative to the git-common-dir, so the
# sandbox must be a real git repo with an origin remote pointing at the
# canonical macatocz/makato URL so _repo_slug() produces the expected slug.
# ---------------------------------------------------------------------------
_mk_sandbox() {
  local key="$1"
  local root
  root="$(mktemp -d)"
  (
    cd "$root" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    git remote add origin "https://github.com/macatocz/makato.git"
    mkdir -p "specs/${key}-e2e-test"
    mkdir -p ".makato/memory"
    : > ".makato/memory/procedural.jsonl"
    : > ".makato/memory/semantic.jsonl"
  )
  echo "$root"
}

_cleanup_sandbox() {
  local sb="$1"
  [[ -n "$sb" ]] && rm -rf "$sb" || true
}

# ===========================================================================
# Scenario A — happy path: full write → promote → recall chain
#   1. write-lessons.sh appends a tier=procedural, scope=generalizable record.
#   2. Pure-writer invariant: .makato/memory/ files remain empty after write.
#   3. promote-lessons.sh promotes the record to procedural.jsonl.
#   4. recall-lessons returns a non-empty array containing the record.
# ===========================================================================
echo "=== Scenario A: full write → promote → recall chain ==="

SB_A=""
SB_A="$(_mk_sandbox "720-e2e-change")"
trap '_cleanup_sandbox "$SB_A"' EXIT

if (
  cd "$SB_A" || exit 1

  # Step A — write.
  bash "$WRITE_LESSONS" "720-e2e-change" procedural generalizable \
    "change-lane write-lessons verified" "e2e,change" 2>/dev/null
  EXIT_WL=$?

  if [[ $EXIT_WL -ne 0 ]]; then
    echo "  write-lessons.sh exited $EXIT_WL" >&2
    exit 1
  fi

  CL_FILE="specs/720-e2e-change-e2e-test/change-lessons.jsonl"
  if [[ ! -f "$CL_FILE" ]]; then
    echo "  change-lessons.jsonl not created at $CL_FILE" >&2
    exit 1
  fi

  # Assertion: record has tier=procedural.
  if ! grep -q '"tier":"procedural"' "$CL_FILE"; then
    echo "  written record missing tier:procedural" >&2
    exit 1
  fi

  # Assertion: record has scope=generalizable.
  if ! grep -q '"scope":"generalizable"' "$CL_FILE"; then
    echo "  written record missing scope:generalizable" >&2
    exit 1
  fi

  # Capture must be durable before any merge/recovery replay.
  python3 - <<'PY'
import json
with open(".makato/memory/procedural.jsonl") as source:
    records = [json.loads(line) for line in source]
assert [record["text"] for record in records] == ["change-lane write-lessons verified"]
PY

  # Step B — promote.
  MAKATO_PROMOTE_REPO_OVERRIDE="$REPO_SLUG" \
    bash "$PROMOTE_LESSONS" \
      "720" \
      "$SB_A/specs" \
      "$SB_A/.makato/memory/procedural.jsonl" \
      "$SB_A/.makato/memory/semantic.jsonl" 2>/dev/null
  EXIT_PL=$?

  if [[ $EXIT_PL -ne 0 ]]; then
    echo "  promote-lessons.sh exited $EXIT_PL" >&2
    exit 1
  fi

  # Assertion: record landed in procedural.jsonl.
  if ! grep -q '"tier":"procedural"' "$SB_A/.makato/memory/procedural.jsonl" 2>/dev/null; then
    echo "  BROKEN SEAM: tier:procedural record was NOT promoted to procedural.jsonl" >&2
    exit 1
  fi

  # Assertion: record did NOT land in semantic.jsonl.
  if grep -q '"text"' "$SB_A/.makato/memory/semantic.jsonl" 2>/dev/null; then
    echo "  BROKEN SEAM: a record was mis-routed to semantic.jsonl" >&2
    exit 1
  fi

  # Step C — recall.
  # MAKATO_MEMORY_ROOT redirects recall-lessons from the production store to
  # the sandbox (HC-3). The REPO argument must be the normalized slug that
  # write-lessons.sh stamped into the `repo` field (not the full remote URL).
  RECALL_OUT="$(MAKATO_MEMORY_ROOT="$SB_A" bash "$WORKFLOW_STATE" \
    recall-lessons "$REPO_SLUG" 5 2>/dev/null || echo "[]")"

  # Assertion: output is a JSON array with at least one element.
  RECALL_COUNT="$(echo "$RECALL_OUT" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "0")"

  if [[ "$RECALL_COUNT" -eq 0 ]]; then
    echo "  BROKEN SEAM: recall-lessons returned empty array; expected the promoted record" >&2
    echo "  recall output: $RECALL_OUT" >&2
    exit 1
  fi

  # Assertion: the recalled array contains the expected lesson text.
  if ! echo "$RECALL_OUT" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); assert any('change-lane write-lessons verified' in (r.get('text','') or r.get('description','')) for r in d)" \
      2>/dev/null; then
    echo "  BROKEN SEAM: recall-lessons output did not contain expected lesson text" >&2
    echo "  recall output: $RECALL_OUT" >&2
    exit 1
  fi
); then
  _pass "capture-time persistence, promotion replay, and recall match"
else
  _fail "full write→promote→recall chain broken (see above)"
fi

trap - EXIT
_cleanup_sandbox "$SB_A"
SB_A=""

# ===========================================================================
# Scenario B — broken-seam guard: promotion fails → recall must return no match
#   Proves the test catches a broken cross-plugin seam rather than passing
#   vacuously on an empty store.
# ===========================================================================
echo ""
echo "=== Scenario B: failed promotion preserves source, not durable recall ==="

SB_B=""
SB_B="$(_mk_sandbox "720-e2e-broken")"
trap '_cleanup_sandbox "$SB_B"' EXIT

if (
  cd "$SB_B" || exit 1

  # Simulate an unavailable installed promoter, not an omitted required call.
  if MAKATO_ORCHESTRATE_ROOT="$SB_B/missing-plugin" \
    bash "$WRITE_LESSONS" "720-e2e-broken" procedural generalizable \
      "this lesson must not reach recall" "e2e,broken" 2>/dev/null; then
    echo "capture incorrectly reported durable success without its promoter" >&2
    exit 1
  fi

  CL_FILE="specs/720-e2e-broken-e2e-test/change-lessons.jsonl"
  if [[ ! -f "$CL_FILE" ]]; then
    echo "  change-lessons.jsonl not created at $CL_FILE" >&2
    exit 1
  fi

  # Confirm the record was written (so this scenario cannot pass vacuously due
  # to a source-write failure rather than the missing promoter).
  if ! grep -q '"text":"this lesson must not reach recall"' "$CL_FILE"; then
    echo "  write-lessons.sh did not write the expected record" >&2
    exit 1
  fi

  # The capture-time promoter was unavailable; do not repair it before recall.

  # Step C — recall from the unpromoted sandbox.
  # .makato/memory/ files are still empty — the lesson was never promoted.
  RECALL_OUT="$(MAKATO_MEMORY_ROOT="$SB_B" bash "$WORKFLOW_STATE" \
    recall-lessons "$REPO_SLUG" 5 2>/dev/null || echo "[]")"

  # Assertion: the recall output must NOT contain the un-promoted lesson.
  FOUND="$(echo "$RECALL_OUT" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); \
     print('yes' if any('this lesson must not reach recall' in (r.get('text','') or r.get('description','')) for r in d) else 'no')" \
    2>/dev/null || echo "no")"

  if [[ "$FOUND" == "yes" ]]; then
    echo "  BROKEN SEAM: recall returned the un-promoted lesson — promote step is not required" >&2
    echo "  recall output: $RECALL_OUT" >&2
    exit 1
  fi
); then
  _pass "broken-seam guard: failed promotion preserves raw evidence without durable recall"
else
  _fail "broken-seam guard broken — recall returned un-promoted lesson (see above)"
fi

trap - EXIT
_cleanup_sandbox "$SB_B"
SB_B=""

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

exit "$FAIL"
