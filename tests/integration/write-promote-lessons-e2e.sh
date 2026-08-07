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
# ## Cross-plugin boundary contract
#
# The full lifecycle for a lesson from creation to long-term memory is:
#
# 1. GHA trigger — post-merge.yml fires when a PR is merged to the default branch.
#
#    The workflow is configured in plugins/makato-orchestrate/workflows/post-merge.yml.
#    It triggers on the `pull_request` event with `types: [closed]`. The job carries
#    an `if:` guard that limits execution to merges only and to the repo default branch:
#
#      if: >-
#        ${{ github.event.pull_request.merged == true &&
#            github.event.pull_request.base.ref == github.event.repository.default_branch }}
#
#    Both conditions are required — a PR closed without merging, or one merged to a
#    non-default branch, must NOT trigger the documentation-agent invocation.
#
# 2. documentation-agent invocation — the workflow's `Run documentation-agent` step
#    invokes `claude` with a prompt that references the documentation-agent.  The
#    exact command is:
#
#      claude --prompt "Post-merge: run documentation-agent for PR #${PR_NUMBER}"
#
#    The documentation-agent (makato-orchestrate) then drives CHANGELOG updates,
#    issue closure, board sync, and lesson promotion.
#
# 3. write-lessons.sh record schema — the JSONL record written to
#    specs/<key>-*/change-lessons.jsonl by write-lessons.sh (makato-build):
#
#   Field   Type    Required  Description
#   ------  ------  --------  --------------------------------------------------
#   ts      string  yes       ISO-8601 timestamp (written by write-lessons.sh)
#   tier    string  yes       "procedural" | "semantic"
#   scope   string  yes       "generalizable" | "local"
#   text    string  yes       lesson/fact body (also present as `description`)
#   tags    array   no        JSON array (default: [])
#   key     string  yes       story key — identifies the source spec folder
#   repo    string  yes       "owner/repo" slug from git remote origin
#
# 4. promote-lessons.sh promotion contract — lifts scope:generalizable records from
#    change-lessons.jsonl (and workflow-state-<N>.json .lessons_learned[]) into
#    .makato/memory/ with tier-based routing:
#
#    Routing promise (enforced by promote-lessons.sh):
#      scope==generalizable AND tier==semantic    → .makato/memory/semantic.jsonl
#      scope==generalizable AND tier==procedural  → .makato/memory/procedural.jsonl
#      scope==local                               → NEVER promoted (per-issue only)
#      tier absent or unrecognised               → .makato/memory/procedural.jsonl
#
#    The scope:local exclusion is a hard boundary: a record written with
#    scope:local by write-lessons.sh must not appear in either .makato/memory/ file
#    after promote-lessons.sh runs, regardless of its tier value.
#
# Scenarios:
#   A — tier:semantic routing: write-lessons writes tier=semantic, promote-lessons
#       routes it to semantic.jsonl and NOT to procedural.jsonl.
#       The test exits non-zero if mis-routing is detected (proving the gap is caught).
#   B — tier:procedural regression guard: write-lessons writes tier=procedural,
#       promote-lessons routes it to procedural.jsonl and NOT to semantic.jsonl.
#   C — post-merge.yml GHA trigger leg: structural assertions on the workflow YAML —
#       verifies the `on.pull_request.types` list contains `closed`, the `if:` guard
#       references `merged == true` and `base.ref`, and the run step invokes `claude`
#       with a prompt referencing `documentation-agent`. Static test, no live runner.
#   D — scope:local exclusion guard: write-lessons writes scope:local, promote-lessons
#       must NOT promote it into either .makato/memory/ file.
#
# Exit code: 0 all pass; non-zero if any scenario fails.
#
# Run from repo root:
#   bash tests/integration/write-promote-lessons-e2e.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRITE_LESSONS="$REPO_ROOT/plugins/makato-build/shared/write-lessons.sh"
PROMOTE_LESSONS="$REPO_ROOT/plugins/makato-orchestrate/scripts/promote-lessons.sh"
POST_MERGE_YML="$REPO_ROOT/plugins/makato-orchestrate/workflows/post-merge.yml"

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
# Scenario C — post-merge.yml GHA trigger leg (#719)
#
# Static structural test — no live GHA runner required. Parses
# plugins/makato-orchestrate/workflows/post-merge.yml and asserts:
#   C-1  on.pull_request.types contains "closed"
#   C-2  the job-level if: condition references "merged == true"
#   C-3  the job-level if: condition references "base.ref"
#   C-4  the run: step invokes "claude" with a prompt referencing "documentation-agent"
#
# The test exits non-zero when any assertion fails, proving the structural
# guard catches a broken post-merge trigger seam.
# ===========================================================================
echo ""
echo "=== Scenario C: post-merge.yml GHA trigger structural assertions ==="

(
  if [[ ! -f "$POST_MERGE_YML" ]]; then
    echo "  post-merge.yml not found at $POST_MERGE_YML" >&2
    exit 1
  fi

  YML_CONTENT="$(<"$POST_MERGE_YML")"

  # C-1: on.pull_request.types must contain "closed"
  # The YAML list entry is "- closed" (with possible surrounding whitespace).
  if ! printf '%s\n' "$YML_CONTENT" | grep -qE '^\s*-\s*closed\s*$'; then
    echo "  C-1 FAIL: on.pull_request.types does not contain 'closed'" >&2
    echo "    This means the workflow will not fire when a PR is merged." >&2
    exit 1
  fi
  echo "  C-1 pass: on.pull_request.types contains 'closed'"

  # C-2: the if: condition must reference "merged == true"
  # This guards against triggering on plain closes (not merges).
  if ! printf '%s\n' "$YML_CONTENT" | grep -q 'merged == true'; then
    echo "  C-2 FAIL: job if: condition does not reference 'merged == true'" >&2
    echo "    Without this guard the workflow fires on every PR close, not just merges." >&2
    exit 1
  fi
  echo "  C-2 pass: if: condition contains 'merged == true'"

  # C-3: the if: condition must reference "base.ref"
  # This scopes the workflow to default-branch merges only.
  if ! printf '%s\n' "$YML_CONTENT" | grep -q 'base\.ref'; then
    echo "  C-3 FAIL: job if: condition does not reference 'base.ref'" >&2
    echo "    Without this guard the workflow fires on merges to any branch." >&2
    exit 1
  fi
  echo "  C-3 pass: if: condition contains 'base.ref'"

  # C-4: a run: step must invoke "claude" with a prompt that references "documentation-agent"
  # This proves the documentation-agent dispatch is wired up in the workflow.
  if ! printf '%s\n' "$YML_CONTENT" | grep -q 'documentation-agent'; then
    echo "  C-4 FAIL: no run: step references 'documentation-agent'" >&2
    echo "    The workflow must invoke claude with a prompt referencing documentation-agent." >&2
    exit 1
  fi
  echo "  C-4 pass: run step references 'documentation-agent'"
) && _pass "post-merge.yml GHA trigger structure is correct" \
  || _fail "post-merge.yml GHA trigger leg broken (see above)"

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

(
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
) && _pass "scope:local records are excluded from .makato/memory/ (both tiers)" \
  || _fail "scope:local exclusion broken (see above)"

trap - EXIT
_cleanup_sandbox "$SB_D"
SB_D=""

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

exit "$FAIL"
