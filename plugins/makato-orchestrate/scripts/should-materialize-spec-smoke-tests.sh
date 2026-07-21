#!/usr/bin/env bash
# Smoke tests for scripts/should-materialize-spec.sh — the HALT-006 auto-
# materialize recovery gate for the PO-agent's Step 1 (#200, extended #527).
#
# Verifies the deterministic decision the PO-agent relies on before it either
# dispatches build-refine (committed stories.json), runs the light-planner, or
# falls through to the existing HALT-006 → needs-human-review path:
#
#   * A VALID plan.md → `proceed` (not a HALT-006 case at all).
#   * A MISSING/stub plan AND a tracked stories.json with ≥1 story
#     → `materialize-refine` (#527) — takes precedence over plan-tier:light.
#   * A MISSING or stub/hollow plan.md AND `plan-tier:light` (no committed
#     stories.json) → `materialize`.
#   * A MISSING or stub/hollow plan.md WITHOUT either engine → `halt`.
#   * An UNTRACKED stories.json → WARN + degrade to the tier fallback (#527).
#
# Every verdict, both eligibility branches, the row-2/row-3 precedence, and
# label-order/other-label robustness are exercised, plus the spec scenarios
# that matter most: the HALT-006 seed stub on a plan-tier:light issue
# materializes, the same stub on a plan-tier:full issue halts, and a full-tier
# stub next to a committed stories.json materialize-refines.
#
# Pure bash — the gate delegates only to validate-plan-body.sh (bash+awk/grep)
# plus a git-tracked probe (stubbed here via MAKATO_SPEC_STORIES_TRACKED).
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

# check_stderr <grep-pattern> <plan-file> <label>...: assert the gate's stderr
# matches the pattern (used for the untracked-stories.json WARN path).
check_stderr() {
  local pat="$1" plan="$2"
  shift 2
  local err
  set +e
  err="$(bash "$GATE" "$plan" "$@" 2>&1 1>/dev/null)"
  set -e
  if printf '%s' "$err" | grep -q "$pat"; then
    pass=$((pass + 1))
    printf '  ✓ %s (stderr matched /%s/)\n' "${TEST_NAME:-test}" "$pat"
  else
    fail=$((fail + 1))
    printf '  ✗ %s: stderr did not match /%s/; got [%s]\n' \
      "${TEST_NAME:-test}" "$pat" "$err"
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

# --- halt: MISSING/stub/hollow WITHOUT any materialization engine ----------

TEST_NAME="missing folder, no labels → halt" \
  check "halt missing-file-no-engine" 1 "$MISSING"

TEST_NAME="seed stub + plan-tier:full → halt" \
  check "halt no-tasks-heading-no-engine" 1 "$STUB" plan-tier:full

TEST_NAME="hollow plan + unrelated labels → halt" \
  check "halt empty-tasks-no-engine" 1 "$HOLLOW" enhancement priority:high

TEST_NAME="missing folder + feature label → halt (feature keeps human review)" \
  check "halt missing-file-no-engine" 1 "$MISSING" type:change

# --- materialize-refine: committed stories.json is the authoritative source (#527) ---
# Fixtures live in their own dirs so the stories.json probe (dirname-based)
# never bleeds into the row-3/row-4 cases above, which sit directly in $TMP.

# A stub plan next to a non-empty stories.json, forced tracked.
REFINE_DIR="$TMP/refine"
mkdir -p "$REFINE_DIR"
write_plan "$REFINE_DIR/plan-527.md" <<'EOF'
# Plan: X

## Acceptance criteria

_To be filled in._
EOF
cat >"$REFINE_DIR/stories.json" <<'EOF'
{"slug":"x","stories":[{"id":"S1","title":"do a thing","description":{}}]}
EOF

# A missing plan (never created) but a tracked stories.json alongside it.
REFINE_MISSING_DIR="$TMP/refine-missing"
mkdir -p "$REFINE_MISSING_DIR"
cat >"$REFINE_MISSING_DIR/stories.json" <<'EOF'
{"slug":"y","stories":[{"id":"S1","title":"another thing","description":{}}]}
EOF

# An EMPTY stories.json (stories: []) — must NOT trigger materialize-refine.
REFINE_EMPTY_DIR="$TMP/refine-empty"
mkdir -p "$REFINE_EMPTY_DIR"
write_plan "$REFINE_EMPTY_DIR/plan-527.md" <<'EOF'
# Plan: X

## Acceptance criteria

_To be filled in._
EOF
cat >"$REFINE_EMPTY_DIR/stories.json" <<'EOF'
{"slug":"z","stories":[]}
EOF

TEST_NAME="stub plan + tracked stories.json → materialize-refine" \
  MAKATO_SPEC_STORIES_TRACKED=1 \
  check "materialize-refine no-tasks-heading" 0 "$REFINE_DIR/plan-527.md"

TEST_NAME="missing plan + tracked stories.json → materialize-refine" \
  MAKATO_SPEC_STORIES_TRACKED=1 \
  check "materialize-refine missing-file" 0 "$REFINE_MISSING_DIR/plan-527.md"

# Precedence: row 2 (stories.json) beats row 3 (plan-tier:light).
TEST_NAME="stories.json + plan-tier:light → materialize-refine (row 2 precedence)" \
  MAKATO_SPEC_STORIES_TRACKED=1 \
  check "materialize-refine no-tasks-heading" 0 "$REFINE_DIR/plan-527.md" plan-tier:light

# A full-tier issue WITH a committed stories.json still materialize-refines
# (the whole point of #527 — no plan-tier:light label needed).
TEST_NAME="stories.json + plan-tier:full → materialize-refine (full-tier autonomous)" \
  MAKATO_SPEC_STORIES_TRACKED=1 \
  check "materialize-refine no-tasks-heading" 0 "$REFINE_DIR/plan-527.md" plan-tier:full

# Empty stories.json (no entries) → falls through to the tier fallback.
TEST_NAME="empty stories.json + plan-tier:full → halt (no stories to refine)" \
  MAKATO_SPEC_STORIES_TRACKED=1 \
  check "halt no-tasks-heading-no-engine" 1 "$REFINE_EMPTY_DIR/plan-527.md" plan-tier:full

TEST_NAME="empty stories.json + plan-tier:light → materialize (light-planner fallback)" \
  MAKATO_SPEC_STORIES_TRACKED=1 \
  check "materialize no-tasks-heading" 0 "$REFINE_EMPTY_DIR/plan-527.md" plan-tier:light

# --- untracked stories.json: WARN + degrade to tier fallback (#527) --------
# An UNTRACKED stories.json cannot survive a fresh clone — it must NOT drive
# materialize-refine; the gate degrades to the tier fallback and warns.

TEST_NAME="untracked stories.json + plan-tier:full → halt (degrade, no refine)" \
  MAKATO_SPEC_STORIES_TRACKED=0 \
  check "halt no-tasks-heading-no-engine" 1 "$REFINE_DIR/plan-527.md" plan-tier:full

TEST_NAME="untracked stories.json + plan-tier:light → materialize (degrade to light-planner)" \
  MAKATO_SPEC_STORIES_TRACKED=0 \
  check "materialize no-tasks-heading" 0 "$REFINE_DIR/plan-527.md" plan-tier:light

TEST_NAME="untracked stories.json emits a WARN to stderr" \
  MAKATO_SPEC_STORIES_TRACKED=0 \
  check_stderr "untracked stories.json" "$REFINE_DIR/plan-527.md" plan-tier:full

# --- errexit-safety: a present-but-invalid stories.json must not abort ------
# stories_has_entries returns non-zero on malformed / no-stories JSON. Under
# `set -e` the gate must still reach the tier fallback (not exit mid-script),
# so these assert a clean verdict rather than an empty/garbled line.

# Malformed JSON (not parseable): has_entries fails → no materialize-refine.
REFINE_BAD_DIR="$TMP/refine-badjson"
mkdir -p "$REFINE_BAD_DIR"
write_plan "$REFINE_BAD_DIR/plan-527.md" <<'EOF'
# Plan: X

## Acceptance criteria

_To be filled in._
EOF
printf '{ this is not valid json ' >"$REFINE_BAD_DIR/stories.json"

TEST_NAME="malformed stories.json + plan-tier:full → halt (no abort)" \
  MAKATO_SPEC_STORIES_TRACKED=1 \
  check "halt no-tasks-heading-no-engine" 1 "$REFINE_BAD_DIR/plan-527.md" plan-tier:full

TEST_NAME="malformed stories.json + plan-tier:light → materialize (degrade, no abort)" \
  MAKATO_SPEC_STORIES_TRACKED=1 \
  check "materialize no-tasks-heading" 0 "$REFINE_BAD_DIR/plan-527.md" plan-tier:light

# JSON object with no `stories` key at all: has_entries fails cleanly.
REFINE_NOKEY_DIR="$TMP/refine-nokey"
mkdir -p "$REFINE_NOKEY_DIR"
write_plan "$REFINE_NOKEY_DIR/plan-527.md" <<'EOF'
# Plan: X

## Acceptance criteria

_To be filled in._
EOF
echo '{"slug":"q"}' >"$REFINE_NOKEY_DIR/stories.json"

TEST_NAME="stories.json without stories[] key + plan-tier:full → halt (no abort)" \
  MAKATO_SPEC_STORIES_TRACKED=1 \
  check "halt no-tasks-heading-no-engine" 1 "$REFINE_NOKEY_DIR/plan-527.md" plan-tier:full

# --- Summary ---------------------------------------------------------------

echo ""
echo "should-materialize-spec: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
