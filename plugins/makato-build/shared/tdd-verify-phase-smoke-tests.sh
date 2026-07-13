#!/usr/bin/env bash
# Smoke tests for the TDD VERIFY phase contract (#285).
# Validates the static documentation contract: build-implement-tdd Step 6
# documents the cross-task regression sweep, tdd-cycle-rules.md documents
# both the per-task and cross-task VERIFY gates, and the session-end
# verification step (Step 7) is preserved as a distinct gate.
#
# These are documentation/grep smoke tests rather than runtime tests because
# the consumer half is implemented as instructions to the LLM that drives each
# skill, not as executable code. The documented contract is the source of truth.
#
# Usage: plugins/makato-build/shared/tdd-verify-phase-smoke-tests.sh
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PASS=0
FAIL=0
FAILURES=()

assert_grep() {
  local pattern="$1"
  local path="$2"
  local label="$3"
  if grep -qE "$pattern" "$REPO_ROOT/$path"; then
    PASS=$((PASS + 1))
    printf '  ✓ %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$label — pattern '$pattern' not found in $path")
    printf '  ✗ %s\n' "$label"
  fi
}

SKILL_MD="plugins/makato-build/skills/build-implement-tdd/SKILL.md"
RULES_MD="plugins/makato-build/skills/build-implement-tdd/references/tdd-cycle-rules.md"

printf '\n=== T1: Step 6 documents the cross-task regression sweep ===\n'
# build-implement-tdd/SKILL.md Step 6 must name the cross-task regression sweep.
# Acceptable phrasings: "cross-task", "ACCUMULATED_PRIOR", "accumulated.*test.*files"
assert_grep 'cross-task|ACCUMULATED_PRIOR|accumulated.*test.*files' \
  "$SKILL_MD" \
  'build-implement-tdd SKILL.md documents the cross-task regression sweep'

# The sweep section heading must be present so future readers can locate it.
assert_grep 'Cross-task regression sweep' \
  "$SKILL_MD" \
  'build-implement-tdd SKILL.md has a Cross-task regression sweep section heading'

printf '\n=== T2: Step 6 uses BASELINE_FAILURES in the sweep gate ===\n'
# The sweep applies the same gate formula as per-task VERIFY.
# BASELINE_FAILURES must appear in the sweep context (not just the step-3 baseline).
assert_grep 'BASELINE_FAILURES' \
  "$SKILL_MD" \
  'build-implement-tdd SKILL.md references BASELINE_FAILURES in the sweep gate'

# The cross-task-verify JSONL step name must be explicitly documented.
assert_grep 'cross-task-verify' \
  "$SKILL_MD" \
  'build-implement-tdd SKILL.md documents the cross-task-verify JSONL step name'

printf '\n=== T3: tdd-cycle-rules.md documents both Level 1 and Level 2 VERIFY ===\n'
# Level 1 (per-task) gate must still reference zero new failures.
assert_grep 'Zero new failures|zero new failures' \
  "$RULES_MD" \
  'tdd-cycle-rules.md documents Level 1 per-task zero-new-failures gate'

# Level 2 (cross-task) gate must be present.
assert_grep 'cross-task|Level 2|Cross-task' \
  "$RULES_MD" \
  'tdd-cycle-rules.md documents Level 2 cross-task VERIFY gate'

# Task 1 skip rule must be documented so readers know the first sweep is for task 2+.
assert_grep 'Task 1 skip|task 1|first task' \
  "$RULES_MD" \
  'tdd-cycle-rules.md documents the Task 1 skip rule'

printf '\n=== T4: Step 7 final-suite gate is preserved as a distinct step ===\n'
# The session-end full-suite run (Step 7) must still exist and must be
# named distinctly from the per-task cross-task sweep to avoid confusion.
assert_grep 'Step 7' \
  "$SKILL_MD" \
  'build-implement-tdd SKILL.md retains Step 7 final-suite verification'

assert_grep 'Final suite verification|final-verify|final suite' \
  "$SKILL_MD" \
  'build-implement-tdd SKILL.md Step 7 names the final-suite gate distinctly'

printf '\n=== Summary ===\n'
printf 'Passed: %d\n' "$PASS"
printf 'Failed: %d\n' "$FAIL"
if (( FAIL > 0 )); then
  printf '\nFailures:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
printf '\nAll TDD VERIFY phase contract checks passed.\n'
