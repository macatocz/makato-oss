#!/usr/bin/env bash
# Exercise tier routing, replay, and local-scope exclusion in real git fixtures.
# Generalizable capture invokes promotion immediately; explicit promotion below
# verifies that the merge/recovery replay remains safe.
# Run: bash tests/integration/write-promote-lessons-e2e.sh

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

if (
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
); then
  _pass "tier:semantic record routed to semantic.jsonl only"
else
  _fail "tier:semantic routing broken (see above)"
fi

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

if (
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
); then
  _pass "tier:procedural record routed to procedural.jsonl only"
else
  _fail "tier:procedural regression guard broken (see above)"
fi

trap - EXIT
_cleanup_sandbox "$SB_B"
SB_B=""


# ===========================================================================
# Scenario D — scope:local exclusion guard (#719)
#
# Writes a scope:local lesson via write-lessons.sh and asserts that
# promote-lessons.sh does NOT promote it into either .makato/memory/ file.
# Covers both tier values (procedural and semantic) to prove the exclusion is
# tier-independent.
#
# The test exits non-zero if promote-lessons.sh incorrectly promotes a
# scope:local record, proving the lifecycle boundary is enforced end-to-end.
# ===========================================================================
echo ""
echo "=== Scenario D: scope:local records are NOT promoted ==="

SB_D=""
SB_D="$(_mk_sandbox "719-e2e-local")"
trap '_cleanup_sandbox "$SB_D"' EXIT

if (
  cd "$SB_D" || exit 1

  # Use a unique sentinel value so the assertion cannot match pre-existing content.
  UNIQUE_TEXT="scope-local-exclusion-guard-719-$$"

  # Step 1a: write a tier=procedural, scope=local lesson.
  bash "$WRITE_LESSONS" "719-e2e-local" procedural local \
    "${UNIQUE_TEXT}-procedural" "e2e,local" 2>/dev/null
  EXIT_WL=$?
  if [[ $EXIT_WL -ne 0 ]]; then
    echo "  write-lessons.sh (procedural/local) exited $EXIT_WL" >&2
    exit 1
  fi

  # Step 1b: write a tier=semantic, scope=local lesson (same spec folder).
  bash "$WRITE_LESSONS" "719-e2e-local" semantic local \
    "${UNIQUE_TEXT}-semantic" "e2e,local" 2>/dev/null
  EXIT_WL=$?
  if [[ $EXIT_WL -ne 0 ]]; then
    echo "  write-lessons.sh (semantic/local) exited $EXIT_WL" >&2
    exit 1
  fi

  CL_FILE="specs/719-e2e-local-e2e-test/change-lessons.jsonl"
  if [[ ! -f "$CL_FILE" ]]; then
    echo "  change-lessons.jsonl not created at $CL_FILE" >&2
    exit 1
  fi

  # Verify both records were written with scope=local.
  if ! grep -q '"scope":"local"' "$CL_FILE"; then
    echo "  written records missing scope:local" >&2
    exit 1
  fi

  # Step 2: attempt promotion via promote-lessons.sh.
  MAKATO_PROMOTE_REPO_OVERRIDE="macatocz/makato" \
    bash "$PROMOTE_LESSONS" \
      "719" \
      "$SB_D/specs" \
      "$SB_D/.makato/memory/procedural.jsonl" \
      "$SB_D/.makato/memory/semantic.jsonl" 2>/dev/null
  EXIT_PL=$?
  if [[ $EXIT_PL -ne 0 ]]; then
    echo "  promote-lessons.sh exited $EXIT_PL" >&2
    exit 1
  fi

  # Assertion D-1: the unique text must NOT appear in procedural.jsonl.
  if grep -qF "$UNIQUE_TEXT" "$SB_D/.makato/memory/procedural.jsonl" 2>/dev/null; then
    echo "  BROKEN BOUNDARY: scope:local record was promoted to procedural.jsonl" >&2
    exit 1
  fi

  # Assertion D-2: the unique text must NOT appear in semantic.jsonl.
  if grep -qF "$UNIQUE_TEXT" "$SB_D/.makato/memory/semantic.jsonl" 2>/dev/null; then
    echo "  BROKEN BOUNDARY: scope:local record was promoted to semantic.jsonl" >&2
    exit 1
  fi
); then
  _pass "scope:local records are excluded from .makato/memory/ (both tiers)"
else
  _fail "scope:local exclusion broken (see above)"
fi

trap - EXIT
_cleanup_sandbox "$SB_D"
SB_D=""

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

exit "$FAIL"
