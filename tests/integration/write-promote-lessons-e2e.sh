#!/usr/bin/env bash
# End-to-end integration test for the write-lessons → promote-lessons seam (#716 / #494).
#
# This test exercises the full cross-plugin chain:
#   1. write-lessons.sh (makato-build)   — appends a JSONL lesson record to
#      specs/<key>/change-lessons.jsonl with tier and scope stamps.
#   2. promote-lessons.sh (makato-orchestrate) — lifts scope:generalizable records
#      into .makato/memory/ routing by tier:
#        tier==semantic  → .makato/memory/semantic.jsonl
#        tier==procedural (or absent) → .makato/memory/procedural.jsonl
#
# Shared JSONL record contract at the boundary (write-lessons → promote-lessons):
#
#   Field        Type     Required  Description
#   -----------  -------  --------  ----------------------------------------
#   ts           string   yes       ISO-8601 timestamp
#   tier         string   yes       "procedural" | "semantic"
#   scope        string   yes       "generalizable" | "local"
#   text         string   yes       lesson/fact body (same as `description`)
#   tags         array    no        comma-split CSV → JSON array
#   key          string   yes       story key (spec folder name)
#   repo         string   yes       owner/repo slug from git remote
#
#   Routing promise (enforced by promote-lessons.sh):
#     scope==generalizable AND tier==semantic   → semantic.jsonl
#     scope==generalizable AND tier==procedural → procedural.jsonl
#     scope==local                              → never promoted
#
# Scenarios:
#   A — tier:semantic routing: write-lessons writes tier=semantic, promote-lessons
#       routes it to semantic.jsonl and NOT to procedural.jsonl.
#       The test exits non-zero if mis-routing is detected (proving the gap is caught).
#   B — tier:procedural regression guard: write-lessons writes tier=procedural,
#       promote-lessons routes it to procedural.jsonl and NOT to semantic.jsonl.
#
# Exit code: 0 all pass; non-zero if any scenario fails.
#
# Run from repo root:
#   bash tests/integration/write-promote-lessons-e2e.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRITE_LESSONS="$REPO_ROOT/plugins/makato-build/shared/write-lessons.sh"
PROMOTE_LESSONS="$REPO_ROOT/plugins/makato-orchestrate/scripts/promote-lessons.sh"

PASS=0
FAIL=0

_pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$(( FAIL + 1 )); }

# ---------------------------------------------------------------------------
# Build a throwaway git sandbox with a specs/<key>-slug/ folder.
# write-lessons.sh uses git-common-dir to resolve the repo root, so we need a
# real git repo with an origin remote and a specs folder under it.
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
    # Create spec folder — write-lessons.sh matches specs/<key>-*/
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
# Scenario A — tier:semantic routing
#   write-lessons.sh writes tier=semantic, scope=generalizable.
#   promote-lessons.sh must route it to semantic.jsonl, NOT procedural.jsonl.
# ===========================================================================
echo "=== Scenario A: tier:semantic routes to semantic.jsonl ==="

SB_A=""
SB_A="$(_mk_sandbox "716-e2e-semantic")"
trap '_cleanup_sandbox "$SB_A"' EXIT

(
  cd "$SB_A" || exit 1

  # Step 1: write a tier=semantic, scope=generalizable lesson via write-lessons.sh.
  # write-lessons.sh resolves specs/ relative to the git-common-dir (this sandbox root).
  bash "$WRITE_LESSONS" "716-e2e-semantic" semantic generalizable \
    "promote-lessons routes tier=semantic to semantic.jsonl" "e2e,routing" 2>/dev/null
  EXIT_WL=$?

  if [[ $EXIT_WL -ne 0 ]]; then
    echo "  write-lessons.sh exited $EXIT_WL" >&2
    exit 1
  fi

  CL_FILE="specs/716-e2e-semantic-e2e-test/change-lessons.jsonl"
  if [[ ! -f "$CL_FILE" ]]; then
    echo "  change-lessons.jsonl not created at $CL_FILE" >&2
    exit 1
  fi

  # Verify the written record has tier=semantic.
  if ! grep -q '"tier":"semantic"' "$CL_FILE"; then
    echo "  written record missing tier:semantic" >&2
    exit 1
  fi

  # Step 2: promote the lesson via promote-lessons.sh.
  # Pass explicit paths so the test is fully hermetic.
  MAKATO_PROMOTE_REPO_OVERRIDE="macatocz/makato" \
    bash "$PROMOTE_LESSONS" \
      "716" \
      "$SB_A/specs" \
      "$SB_A/.makato/memory/procedural.jsonl" \
      "$SB_A/.makato/memory/semantic.jsonl" 2>/dev/null
  EXIT_PL=$?

  if [[ $EXIT_PL -ne 0 ]]; then
    echo "  promote-lessons.sh exited $EXIT_PL" >&2
    exit 1
  fi

  # Assertion A-1: record landed in semantic.jsonl.
  if ! grep -q '"tier":"semantic"' "$SB_A/.makato/memory/semantic.jsonl" 2>/dev/null; then
    echo "  BROKEN SEAM: tier:semantic record was NOT routed to semantic.jsonl" >&2
    exit 1
  fi

  # Assertion A-2: record did NOT land in procedural.jsonl.
  # (If a tier:semantic record appears in procedural.jsonl the seam is broken.)
  if grep -q '"tier":"semantic"' "$SB_A/.makato/memory/procedural.jsonl" 2>/dev/null; then
    echo "  BROKEN SEAM: tier:semantic record was mis-routed to procedural.jsonl" >&2
    exit 1
  fi
) && _pass "tier:semantic record routed to semantic.jsonl only" \
  || _fail "tier:semantic routing broken (see above)"

trap - EXIT
_cleanup_sandbox "$SB_A"
SB_A=""

# ===========================================================================
# Scenario B — tier:procedural regression guard
#   write-lessons.sh writes tier=procedural, scope=generalizable.
#   promote-lessons.sh must route it to procedural.jsonl, NOT semantic.jsonl.
# ===========================================================================
echo ""
echo "=== Scenario B: tier:procedural routes to procedural.jsonl ==="

SB_B=""
SB_B="$(_mk_sandbox "716-e2e-procedural")"
trap '_cleanup_sandbox "$SB_B"' EXIT

(
  cd "$SB_B" || exit 1

  # Step 1: write a tier=procedural, scope=generalizable lesson.
  bash "$WRITE_LESSONS" "716-e2e-procedural" procedural generalizable \
    "promote-lessons routes tier=procedural to procedural.jsonl" "e2e,routing" 2>/dev/null
  EXIT_WL=$?

  if [[ $EXIT_WL -ne 0 ]]; then
    echo "  write-lessons.sh exited $EXIT_WL" >&2
    exit 1
  fi

  CL_FILE="specs/716-e2e-procedural-e2e-test/change-lessons.jsonl"
  if [[ ! -f "$CL_FILE" ]]; then
    echo "  change-lessons.jsonl not created at $CL_FILE" >&2
    exit 1
  fi

  # Verify the written record has tier=procedural.
  if ! grep -q '"tier":"procedural"' "$CL_FILE"; then
    echo "  written record missing tier:procedural" >&2
    exit 1
  fi

  # Step 2: promote via promote-lessons.sh.
  MAKATO_PROMOTE_REPO_OVERRIDE="macatocz/makato" \
    bash "$PROMOTE_LESSONS" \
      "716" \
      "$SB_B/specs" \
      "$SB_B/.makato/memory/procedural.jsonl" \
      "$SB_B/.makato/memory/semantic.jsonl" 2>/dev/null
  EXIT_PL=$?

  if [[ $EXIT_PL -ne 0 ]]; then
    echo "  promote-lessons.sh exited $EXIT_PL" >&2
    exit 1
  fi

  # Assertion B-1: record landed in procedural.jsonl.
  if ! grep -q '"tier":"procedural"' "$SB_B/.makato/memory/procedural.jsonl" 2>/dev/null; then
    echo "  REGRESSION: tier:procedural record was NOT routed to procedural.jsonl" >&2
    exit 1
  fi

  # Assertion B-2: record did NOT land in semantic.jsonl.
  if grep -q '"tier":"procedural"' "$SB_B/.makato/memory/semantic.jsonl" 2>/dev/null; then
    echo "  REGRESSION: tier:procedural record was mis-routed to semantic.jsonl" >&2
    exit 1
  fi
) && _pass "tier:procedural record routed to procedural.jsonl only" \
  || _fail "tier:procedural regression guard broken (see above)"

trap - EXIT
_cleanup_sandbox "$SB_B"
SB_B=""

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

exit "$FAIL"
