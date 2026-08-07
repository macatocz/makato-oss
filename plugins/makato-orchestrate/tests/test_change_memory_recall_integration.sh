#!/usr/bin/env bash
# Integration smoke test: change-lane memory recall contract (#720).
#
# Verifies the full cross-plugin chain:
#   write-lessons.sh (makato-build)        — appends JSONL to specs/<key>/change-lessons.jsonl
#   promote-lessons.sh (makato-orchestrate) — lifts scope:generalizable records to .makato/memory/
#   workflow-state.sh recall-lessons        — surfaces promoted entries to a resumed po-agent
#
# Scenarios:
#   C1 — Happy path: change-lane key, scope=generalizable, tier=procedural
#        Full chain write → promote → recall; entry MUST appear in recall output.
#   C2 — Broken-seam: promote step is skipped between write and recall;
#        entry MUST NOT appear in recall output (test exits non-zero if it does).
#   C3 — Negative/gate: scope=local entry is written then promoted;
#        entry MUST NOT appear in .makato/memory/ or recall output after promotion.
#
# Exit code: 0 all pass; non-zero on the first failure (set -e propagation).
#
# Run from repo root:
#   bash plugins/makato-orchestrate/tests/test_change_memory_recall_integration.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WRITE_LESSONS="$REPO_ROOT/plugins/makato-build/shared/write-lessons.sh"
PROMOTE_LESSONS="$REPO_ROOT/plugins/makato-orchestrate/scripts/promote-lessons.sh"
WORKFLOW_STATE="$REPO_ROOT/plugins/makato-orchestrate/shared/workflow-state.sh"

# Confirm dependencies are present before doing anything else.
for _dep in "$WRITE_LESSONS" "$PROMOTE_LESSONS" "$WORKFLOW_STATE"; do
  if [[ ! -f "$_dep" ]]; then
    echo "FAIL: required script not found: $_dep" >&2
    exit 1
  fi
done

PASS=0
FAIL=0

_pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$(( FAIL + 1 )); }

# ---------------------------------------------------------------------------
# _mk_sandbox <key> <issue_number>
#   Create a minimal git repo that satisfies write-lessons.sh's resolver:
#     - Real git init with user config and an origin remote
#     - specs/<key>-720/ folder  (prefix-match convention for change-lane keys)
#     - .makato/memory/ directory with empty store files
#   Returns the absolute path to the sandbox root on stdout.
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
    # Use the key as the exact folder name so both resolvers agree:
    #   write-lessons.sh: exact-match fallback specs/<KEY>/ (no prefix-glob match)
    #   promote-lessons.sh: *-<ISSUE_NUMBER> glob matches e.g. "my-feature-720"
    # A suffix like "-fixture" would break the promote-lessons *-720 glob.
    mkdir -p "specs/${key}"
    mkdir -p ".makato/memory"
    : > ".makato/memory/procedural.jsonl"
    : > ".makato/memory/semantic.jsonl"
  )
  echo "$root"
}

_cleanup() {
  local sb="$1"
  [[ -n "$sb" ]] && rm -rf "$sb" || true
}

# ===========================================================================
# Scenario C1 — Happy path: write → promote → recall returns the entry
#
# The full chain must surface a change-lane generalizable lesson so the
# resumed po-agent's Step 2c recall (workflow-state.sh recall-lessons) can
# inject institutional memory into the next build dispatch.
# ===========================================================================
echo "=== Scenario C1: write → promote → recall returns the entry ==="

SB_C1=""
SB_C1="$(_mk_sandbox "my-feature-720")"
trap '_cleanup "$SB_C1"' EXIT

(
  cd "$SB_C1" || exit 1

  ISSUE_NUMBER="720"
  KEY="my-feature-720"
  LESSON_TEXT="change-lane recall integration: always call promote before recall"
  REPO_SLUG="macatocz/makato"

  # Step 1: write a generalizable procedural lesson via write-lessons.sh.
  # Change-lane key shape: <slug>-<N> (number-last).
  bash "$WRITE_LESSONS" "$KEY" procedural generalizable "$LESSON_TEXT" "change-lane,recall"
  EXIT_WL=$?
  if [[ $EXIT_WL -ne 0 ]]; then
    echo "  write-lessons.sh exited $EXIT_WL" >&2
    exit 1
  fi

  # Verify the change-lessons.jsonl was created in the spec folder.
  CL_FILE="specs/${KEY}/change-lessons.jsonl"
  if [[ ! -f "$CL_FILE" ]]; then
    echo "  change-lessons.jsonl not created at $CL_FILE" >&2
    exit 1
  fi
  if ! grep -q '"scope":"generalizable"' "$CL_FILE"; then
    echo "  written record missing scope:generalizable" >&2
    exit 1
  fi

  # Step 2: promote via promote-lessons.sh (explicit paths for hermeticity).
  MAKATO_PROMOTE_REPO_OVERRIDE="$REPO_SLUG" \
    bash "$PROMOTE_LESSONS" \
      "$ISSUE_NUMBER" \
      "$SB_C1/specs" \
      "$SB_C1/.makato/memory/procedural.jsonl" \
      "$SB_C1/.makato/memory/semantic.jsonl"
  EXIT_PL=$?
  if [[ $EXIT_PL -ne 0 ]]; then
    echo "  promote-lessons.sh exited $EXIT_PL" >&2
    exit 1
  fi

  # Assert: entry reached procedural.jsonl (tier=procedural routing).
  if ! grep -q '"scope":"generalizable"' "$SB_C1/.makato/memory/procedural.jsonl" 2>/dev/null; then
    echo "  BROKEN SEAM C1: generalizable entry was NOT promoted to procedural.jsonl" >&2
    exit 1
  fi

  # Step 3: recall via workflow-state.sh recall-lessons.
  # MAKATO_MEMORY_ROOT overrides the memory root so recall reads from the
  # sandbox's .makato/memory/ instead of the real repo's store.
  # KEY is unused by recall-lessons (it takes REPO as ARG2, but the script still
  # requires a KEY-shaped ARG2 for other subcommands — pass REPO directly).
  RECALL_OUT="$(
    MAKATO_MEMORY_ROOT="$SB_C1" \
    SPECS_DIR="$SB_C1/specs" \
    bash "$WORKFLOW_STATE" recall-lessons "$REPO_SLUG" 5
  )"

  # Assert: the promoted entry appears in recall output.
  if ! echo "$RECALL_OUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = any('$LESSON_TEXT' in (r.get('text','') or r.get('description','')) for r in data)
sys.exit(0 if found else 1)
"; then
    echo "  BROKEN SEAM C1: promoted entry NOT returned by recall-lessons" >&2
    echo "  recall output: $RECALL_OUT" >&2
    exit 1
  fi
) && _pass "C1: write → promote → recall returns the entry" \
  || _fail "C1: happy path broken (see above)"

trap - EXIT
_cleanup "$SB_C1"
SB_C1=""

# ===========================================================================
# Scenario C2 — Broken-seam: promote step is skipped
#
# When promote-lessons.sh is NOT called, the entry must NOT appear in recall.
# This proves the test is a genuine watchdog for the seam — not a tautology
# that would pass even if recall reads directly from change-lessons.jsonl.
# ===========================================================================
echo ""
echo "=== Scenario C2: promote step skipped — recall must NOT return the entry ==="

SB_C2=""
SB_C2="$(_mk_sandbox "my-feature-720")"
trap '_cleanup "$SB_C2"' EXIT

(
  cd "$SB_C2" || exit 1

  KEY="my-feature-720"
  LESSON_TEXT="change-lane recall integration: always call promote before recall"
  REPO_SLUG="macatocz/makato"

  # Step 1: write the lesson — same as C1.
  bash "$WRITE_LESSONS" "$KEY" procedural generalizable "$LESSON_TEXT" "change-lane,recall"
  EXIT_WL=$?
  if [[ $EXIT_WL -ne 0 ]]; then
    echo "  write-lessons.sh exited $EXIT_WL" >&2
    exit 1
  fi

  # Step 2: deliberately SKIP promote-lessons.sh.
  # The .makato/memory/procedural.jsonl was created empty by _mk_sandbox.

  # Step 3: recall — should return an empty array (no promoted entries).
  RECALL_OUT="$(
    MAKATO_MEMORY_ROOT="$SB_C2" \
    SPECS_DIR="$SB_C2/specs" \
    bash "$WORKFLOW_STATE" recall-lessons "$REPO_SLUG" 5
  )"

  # Assert: the entry does NOT appear in recall output (promote was skipped).
  if echo "$RECALL_OUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = any('$LESSON_TEXT' in (r.get('text','') or r.get('description','')) for r in data)
sys.exit(0 if found else 1)
" 2>/dev/null; then
    echo "  BROKEN SEAM C2: entry appeared in recall WITHOUT promotion — seam is bypassed" >&2
    echo "  recall output: $RECALL_OUT" >&2
    exit 1
  fi
) && _pass "C2: skipping promote means recall returns nothing (seam is real)" \
  || _fail "C2: broken-seam check failed (see above)"

trap - EXIT
_cleanup "$SB_C2"
SB_C2=""

# ===========================================================================
# Scenario C3 — Negative/gate: scope=local entry must not be promoted
#
# The promotion gate in promote-lessons.sh skips entries where scope != "generalizable".
# A scope=local entry must not appear in .makato/memory/ or in recall output after promotion.
# ===========================================================================
echo ""
echo "=== Scenario C3: scope=local entry not promoted (gate is real) ==="

SB_C3=""
SB_C3="$(_mk_sandbox "my-local-feature-720")"
trap '_cleanup "$SB_C3"' EXIT

(
  cd "$SB_C3" || exit 1

  ISSUE_NUMBER="720"
  KEY="my-local-feature-720"
  LOCAL_TEXT="this local lesson should stay per-issue only and never be promoted"
  REPO_SLUG="macatocz/makato"

  # Step 1: write a scope=local lesson — the promotion gate must reject it.
  bash "$WRITE_LESSONS" "$KEY" procedural local "$LOCAL_TEXT" "local,private"
  EXIT_WL=$?
  if [[ $EXIT_WL -ne 0 ]]; then
    echo "  write-lessons.sh exited $EXIT_WL" >&2
    exit 1
  fi

  # Verify the record was written with scope=local.
  CL_FILE="specs/${KEY}/change-lessons.jsonl"
  if [[ ! -f "$CL_FILE" ]]; then
    echo "  change-lessons.jsonl not created at $CL_FILE" >&2
    exit 1
  fi
  if ! grep -q '"scope":"local"' "$CL_FILE"; then
    echo "  written record missing scope:local" >&2
    exit 1
  fi

  # Step 2: run promote-lessons.sh — it should silently skip the local entry.
  MAKATO_PROMOTE_REPO_OVERRIDE="$REPO_SLUG" \
    bash "$PROMOTE_LESSONS" \
      "$ISSUE_NUMBER" \
      "$SB_C3/specs" \
      "$SB_C3/.makato/memory/procedural.jsonl" \
      "$SB_C3/.makato/memory/semantic.jsonl"
  EXIT_PL=$?
  if [[ $EXIT_PL -ne 0 ]]; then
    echo "  promote-lessons.sh exited $EXIT_PL" >&2
    exit 1
  fi

  # Assert: scope=local entry must NOT appear in procedural.jsonl.
  if grep -q '"scope":"local"' "$SB_C3/.makato/memory/procedural.jsonl" 2>/dev/null; then
    echo "  GATE FAILURE C3: scope=local entry was promoted to procedural.jsonl" >&2
    exit 1
  fi

  # Assert: scope=local entry must NOT appear in semantic.jsonl.
  if grep -q '"scope":"local"' "$SB_C3/.makato/memory/semantic.jsonl" 2>/dev/null; then
    echo "  GATE FAILURE C3: scope=local entry was promoted to semantic.jsonl" >&2
    exit 1
  fi

  # Step 3: recall must also return nothing for this local entry.
  RECALL_OUT="$(
    MAKATO_MEMORY_ROOT="$SB_C3" \
    SPECS_DIR="$SB_C3/specs" \
    bash "$WORKFLOW_STATE" recall-lessons "$REPO_SLUG" 5
  )"

  if echo "$RECALL_OUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = any('$LOCAL_TEXT' in (r.get('text','') or r.get('description','')) for r in data)
sys.exit(0 if found else 1)
" 2>/dev/null; then
    echo "  GATE FAILURE C3: scope=local entry appeared in recall output" >&2
    echo "  recall output: $RECALL_OUT" >&2
    exit 1
  fi
) && _pass "C3: scope=local entry not promoted and not recalled (gate is real)" \
  || _fail "C3: negative gate check failed (see above)"

trap - EXIT
_cleanup "$SB_C3"
SB_C3=""

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

exit "$FAIL"
