#!/usr/bin/env bash
# Smoke tests for scripts/should-materialize-spec.sh — the HALT-006 auto-
# materialize recovery gate for the PO-agent's Step 1 (#200).
#
# Verifies the deterministic decision the PO-agent relies on before it either
# runs the light-planner to write a real plan.md or falls through to the
# existing HALT-006 → needs-human-review path:
#
#   * A VALID plan.md → `proceed` (not a HALT-006 case at all).
#   * A MISSING or stub/hollow plan.md AND `plan-tier:light` → `materialize`.
#   * A MISSING or stub/hollow plan.md WITHOUT `plan-tier:light` → `halt`.
#
# Every verdict, both eligibility branches, and label-order/other-label
# robustness are exercised, plus the two spec scenarios that matter most: the
# HALT-006 seed stub on a plan-tier:light issue materializes, and the same stub
# on a plan-tier:full issue halts.
#
# Pure bash — the gate delegates only to validate-plan-body.sh (bash+awk/grep).
# No gh, no network, no agent.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
GATE="$REPO_ROOT/plugins/makato-orchestrate/scripts/should-materialize-spec.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# check <expected-stdout> <expected-exit> <plan-file> <label>...
check() {
  local expected="$1" want_exit="$2" plan="$3"
  shift 3
  local got rc
  set +e
  got="$(bash "$GATE" "$plan" "$@" 2>/dev/null)"
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

# write_plan <file> — heredoc body on stdin.
write_plan() { cat >"$1"; }

echo "should-materialize-spec.sh smoke tests (#200)"

# --- Fixtures --------------------------------------------------------------

MISSING="$TMP/does-not-exist.md"   # never created

STUB="$TMP/stub.md"
write_plan "$STUB" <<'EOF'
# Plan: Add a --json flag

> Auto-seeded by seed-issue v1.2.0. Replace this stub with a full plan.

## Issue

[#200](https://github.com/macatocz/makato/issues/200)

## Acceptance criteria

_To be filled in. The PO-agent will HALT with HALT-006 (MISSING_SPEC) if
this file contains only the stub text above._
EOF

# Hollow: headings present but bodies are placeholder-only.
HOLLOW="$TMP/hollow.md"
write_plan "$HOLLOW" <<'EOF'
# Plan: X

## Tasks

<!-- nothing here yet -->

## Acceptance criteria

_To be filled in._
EOF

VALID="$TMP/valid.md"
write_plan "$VALID" <<'EOF'
# Plan: Add a --json flag to `foo list`

## Tasks

- Add `--json` flag parsing to `src/cli/list.ts`
- Serialize the item array as JSON to stdout

## Acceptance criteria

- `foo list --json` prints the item array as JSON to stdout
- exit code is non-zero on an empty result
EOF

# --- proceed: a valid plan is not a HALT-006 case --------------------------

TEST_NAME="valid plan, no labels → proceed" \
  check "proceed plan-valid" 0 "$VALID"

TEST_NAME="valid plan, plan-tier:light → still proceed" \
  check "proceed plan-valid" 0 "$VALID" plan-tier:light

TEST_NAME="valid plan, plan-tier:full → still proceed" \
  check "proceed plan-valid" 0 "$VALID" plan-tier:full

# --- materialize: MISSING/stub/hollow + plan-tier:light --------------------

TEST_NAME="missing folder + plan-tier:light → materialize (missing-file)" \
  check "materialize missing-file" 0 "$MISSING" plan-tier:light

TEST_NAME="seed stub + plan-tier:light → materialize (no-tasks-heading)" \
  check "materialize no-tasks-heading" 0 "$STUB" plan-tier:light

TEST_NAME="hollow plan + plan-tier:light → materialize (empty-tasks)" \
  check "materialize empty-tasks" 0 "$HOLLOW" plan-tier:light

TEST_NAME="label order irrelevant (light not first)" \
  check "materialize missing-file" 0 "$MISSING" enhancement plan-tier:light

TEST_NAME="extra labels alongside light still materialize" \
  check "materialize no-tasks-heading" 0 "$STUB" bug plan-tier:light priority:high

# --- halt: MISSING/stub/hollow WITHOUT plan-tier:light ---------------------

TEST_NAME="missing folder, no labels → halt" \
  check "halt missing-file-not-light" 1 "$MISSING"

TEST_NAME="seed stub + plan-tier:full → halt" \
  check "halt no-tasks-heading-not-light" 1 "$STUB" plan-tier:full

TEST_NAME="hollow plan + unrelated labels → halt" \
  check "halt empty-tasks-not-light" 1 "$HOLLOW" enhancement priority:high

TEST_NAME="missing folder + feature label → halt (feature keeps human review)" \
  check "halt missing-file-not-light" 1 "$MISSING" type:change

# --- Summary ---------------------------------------------------------------

echo ""
echo "should-materialize-spec: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
