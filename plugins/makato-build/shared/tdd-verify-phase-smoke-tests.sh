#!/usr/bin/env bash
# Smoke tests for the TDD verification contract (#148/#149, supersedes #285).
# Validates the static documentation contract: coders run only targeted
# RED/GREEN commands, the build-implement-tdd coordinator accepts a valid R1
# without running a suite or a cross-task regression sweep, carries the Step 3
# baseline forward, and hands whole-change verification to build-verify.
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

# The cross-task regression sweep was removed on purpose (#149); its return
# would silently re-add a whole-suite run to every TDD session.
assert_no_grep() {
  local pattern="$1"
  local path="$2"
  local label="$3"
  if grep -qiE "$pattern" "$REPO_ROOT/$path"; then
    FAIL=$((FAIL + 1))
    FAILURES+=("$label — pattern '$pattern' unexpectedly found in $path")
    printf '  ✗ %s\n' "$label"
  else
    PASS=$((PASS + 1))
    printf '  ✓ %s\n' "$label"
  fi
}

SKILL_MD="plugins/makato-build/skills/build-implement-tdd/SKILL.md"
RULES_MD="plugins/makato-build/skills/build-implement-tdd/references/tdd-cycle-rules.md"

printf '\n=== T1: the coordinator accepts a valid coder R1 without running tests ===\n'
assert_grep 'do not run a regression sweep or other tests in the coordinator' \
  "$SKILL_MD" \
  'build-implement-tdd SKILL.md forbids a regression sweep in the coordinator'

assert_no_grep 'cross-task-verify|ACCUMULATED_PRIOR' \
  "$SKILL_MD" \
  'build-implement-tdd SKILL.md has no cross-task sweep step or accumulated-test-file set'

printf '\n=== T2: the Step 3 baseline is established once and carried forward ===\n'
assert_grep 'BASELINE_FAILURES' \
  "$SKILL_MD" \
  'build-implement-tdd SKILL.md defines BASELINE_FAILURES from the baseline row'

assert_grep 'Carry the Step 3 baseline result forward for .build-verify.' \
  "$SKILL_MD" \
  'build-implement-tdd SKILL.md Step 7 carries the baseline forward to build-verify'

printf '\n=== T3: tdd-cycle-rules.md documents targeted RED and GREEN only ===\n'
assert_grep '^### RED' \
  "$RULES_MD" \
  'tdd-cycle-rules.md documents the RED phase'

assert_grep '^### GREEN' \
  "$RULES_MD" \
  'tdd-cycle-rules.md documents the GREEN phase'

assert_grep 'run(s)? only targeted commands' \
  "$RULES_MD" \
  'tdd-cycle-rules.md limits the coder to targeted commands'

assert_grep 'do not run those gates or a cross-task' \
  "$RULES_MD" \
  'tdd-cycle-rules.md states the coder and coordinator run no cross-task regression sweep'

printf '\n=== T4: whole-change verification is handed to build-verify ===\n'
assert_grep '^### Step 7 — Hand off to build-verify' \
  "$SKILL_MD" \
  'build-implement-tdd SKILL.md Step 7 is the build-verify hand-off'

assert_grep 'Do not run a suite, integration suite, coverage, or' \
  "$SKILL_MD" \
  'build-implement-tdd SKILL.md Step 7 forbids suite, coverage and lint in the coordinator'

assert_grep 'build-verify. owns build, lint,' \
  "$RULES_MD" \
  'tdd-cycle-rules.md assigns whole-change gates to build-verify'

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
printf '\nAll TDD verification contract checks passed.\n'
