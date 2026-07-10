#!/usr/bin/env bash
# Smoke tests for scripts/validate-plan-body.sh — the lightweight planning
# lane promotion guard (#212).
#
# Verifies the deterministic contract seed-issue relies on: a plan is "valid"
# (promotable to Ready) only when BOTH `## Tasks` and `## Acceptance criteria`
# carry real, non-placeholder content. Every reason code is exercised, plus
# the two spec scenarios that matter most: the HALT-006 seed stub fails, and a
# real light-planner plan passes.
#
# Pure bash + awk/grep — no gh, no network, no agent.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
GUARD="$REPO_ROOT/plugins/makato-orchestrate/scripts/validate-plan-body.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# check <expected-stdout> <expected-exit> <plan-file-or-empty>
check() {
  local expected="$1" want_exit="$2" plan="$3"
  local got rc
  set +e
  got="$(bash "$GUARD" "$plan" 2>/dev/null)"
  rc=$?
  set -e
  if [ "$got" = "$expected" ] && [ "$rc" -eq "$want_exit" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s → %s (exit %d)\n' "${TEST_NAME:-test}" "$got" "$rc"
  else
    fail=$((fail + 1))
    printf '  ✗ %s: expected [%s] exit %d, got [%s] exit %d\n' \
      "${TEST_NAME:-test}" "$expected" "$want_exit" "$got" "$rc"
  fi
}

# write_plan <file> <heredoc-body-on-stdin>
write_plan() { cat > "$1"; }

# --- T1: missing file ------------------------------------------------------
TEST_NAME="T1 non-existent path → invalid missing-file"
check "invalid missing-file" 1 "$TMP/does-not-exist.md"

# --- T2: no argument -------------------------------------------------------
TEST_NAME="T2 empty argument → invalid missing-file"
check "invalid missing-file" 1 ""

# --- T3: HALT-006 seed-issue stub (the canonical thin plan) ----------------
# This is the exact stub seed-issue Step 8 writes today. It MUST fail so the
# board stays at Todo until light-planner materializes a real plan.
TEST_NAME="T3 seed-issue HALT-006 stub → invalid (no Tasks heading)"
write_plan "$TMP/stub.md" <<'EOF'
# Plan: Some feature

> Auto-seeded by seed-issue v1.1.0 on 2026-07-10. Replace this stub with a
> full plan before the PO-agent starts.

## Issue

[#212](https://github.com/macatocz/makato/issues/212)

## Acceptance criteria

_To be filled in. The PO-agent will HALT with HALT-006 (MISSING_SPEC) if
this file contains only the stub text above._
EOF
check "invalid no-tasks-heading" 1 "$TMP/stub.md"

# --- T4: real light-planner plan (the happy path) --------------------------
TEST_NAME="T4 full light-planner plan → valid ok"
write_plan "$TMP/good.md" <<'EOF'
# Implementation Plan: 212-light-planner

## Story
**Key:** 212-light-planner

## Tasks

1. Author the light-planner agent AGENT.md.
2. Wire it into seed-issue via the Task tool.
3. Add the promotion guard.

## Acceptance criteria

- seed-issue on a plan-tier:light issue writes a full plan.md.
- The board is promoted to Ready only after both sections are non-empty.
- plan-tier:full issues follow the unchanged full-cycle path.
EOF
check "valid ok" 0 "$TMP/good.md"

# --- T5: Tasks heading present but body empty ------------------------------
TEST_NAME="T5 empty Tasks section → invalid empty-tasks"
write_plan "$TMP/empty-tasks.md" <<'EOF'
# Plan

## Tasks

## Acceptance criteria

- A real criterion.
EOF
check "invalid empty-tasks" 1 "$TMP/empty-tasks.md"

# --- T6: Tasks present, Acceptance criteria heading absent -----------------
TEST_NAME="T6 no Acceptance heading → invalid no-acceptance-heading"
write_plan "$TMP/no-ac.md" <<'EOF'
# Plan

## Tasks

1. Do the thing.
EOF
check "invalid no-acceptance-heading" 1 "$TMP/no-ac.md"

# --- T7: Acceptance heading present but empty ------------------------------
TEST_NAME="T7 empty Acceptance section → invalid empty-acceptance"
write_plan "$TMP/empty-ac.md" <<'EOF'
# Plan

## Tasks

1. Do the thing.

## Acceptance criteria

EOF
check "invalid empty-acceptance" 1 "$TMP/empty-ac.md"

# --- T8: Acceptance section with only the seed placeholder stub ------------
# The italic `_To be filled in…_` line must NOT count as content — this is the
# subtle failure the guard exists to catch (heading present, looks filled,
# but it's still the stub).
TEST_NAME="T8 Acceptance = placeholder stub only → invalid empty-acceptance"
write_plan "$TMP/placeholder-ac.md" <<'EOF'
# Plan

## Tasks

1. Do the thing.

## Acceptance criteria

_To be filled in. The PO-agent will HALT with HALT-006._
EOF
check "invalid empty-acceptance" 1 "$TMP/placeholder-ac.md"

# --- T9: Tasks section with only an HTML comment ---------------------------
TEST_NAME="T9 Tasks = HTML comment only → invalid empty-tasks"
write_plan "$TMP/comment-tasks.md" <<'EOF'
# Plan

## Tasks

<!-- TODO: the planner will fill this in -->

## Acceptance criteria

- A real criterion.
EOF
check "invalid empty-tasks" 1 "$TMP/comment-tasks.md"

# --- T10: template tokens (<tasks>) do NOT count as content ----------------
TEST_NAME="T10 Tasks = unfilled template token → invalid empty-tasks"
write_plan "$TMP/token-tasks.md" <<'EOF'
# Plan

## Tasks

<tasks>

## Acceptance criteria

- A real criterion.
EOF
check "invalid empty-tasks" 1 "$TMP/token-tasks.md"

# --- T11: prose (non-list) content counts as valid -------------------------
# Acceptance criteria written as prose paragraphs, not bullets, still count.
TEST_NAME="T11 prose-only sections → valid ok"
write_plan "$TMP/prose.md" <<'EOF'
# Plan

## Tasks

The planner will refactor the dispatch loop and add a guard.

## Acceptance criteria

The board must be promoted only after a real plan exists.
EOF
check "valid ok" 0 "$TMP/prose.md"

# --- T12: case-insensitive + extra whitespace on headings ------------------
TEST_NAME="T12 case-insensitive headings → valid ok"
write_plan "$TMP/case.md" <<'EOF'
# Plan

##   TASKS

- Task one.

## ACCEPTANCE CRITERIA

- Criterion one.
EOF
check "valid ok" 0 "$TMP/case.md"

# --- T13: Acceptance criteria written as a data-bearing table → valid ------
# A table with a real data row is legitimate content; only a lone separator
# row (structure) is skipped by the guard.
TEST_NAME="T13 Acceptance as data-bearing table → valid ok"
write_plan "$TMP/table.md" <<'EOF'
# Plan

## Tasks

1. Do the thing.

## Acceptance criteria

| AC | Description |
|----|-------------|
| 1  | The guard rejects stub plans. |
EOF
check "valid ok" 0 "$TMP/table.md"

echo ""
echo "validate-plan-body smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
