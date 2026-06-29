#!/usr/bin/env bash
# Smoke tests for issue #98 — default-branch ref resolution.
#
# Validates two layers:
#
# 1. **Runtime behaviour of `shared/default-branch.sh`** — given a fresh git
#    repository with `origin` and a non-default branch checked out, the helper
#    must echo `origin/<default>` and exit 0. This is the contract every
#    build-* skill depends on.
#
# 2. **Reproduction of the bug fixed by #98** — set up a repo whose local
#    `main` lags `origin/main` and create a feature branch off `origin/main`.
#    Then assert:
#      - `git diff main...HEAD --name-only` (the stale path) lists files from
#        commits that already shipped on `origin/main`.
#      - `git diff "$(./default-branch.sh)...HEAD" --name-only` (the fixed
#        path) lists ONLY the feature branch's own changes.
#    This is the failure mode the issue describes and the regression that
#    must stay closed.
#
# 3. **Static contract** — every build-* skill / agent that diffs the feature
#    branch references the helper rather than the bare local `main`.
#
# Usage: plugins/makato-build/shared/default-branch-smoke-tests.sh
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HELPER="$REPO_ROOT/plugins/makato-build/shared/default-branch.sh"
PASS=0
FAIL=0
FAILURES=()

assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    printf '  ✓ %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$label — expected: '$expected', actual: '$actual'")
    printf '  ✗ %s\n' "$label"
  fi
}

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

assert_no_grep() {
  local pattern="$1"
  local path="$2"
  local label="$3"
  if grep -qE "$pattern" "$REPO_ROOT/$path"; then
    FAIL=$((FAIL + 1))
    FAILURES+=("$label — forbidden pattern '$pattern' present in $path")
    printf '  ✗ %s\n' "$label"
  else
    PASS=$((PASS + 1))
    printf '  ✓ %s\n' "$label"
  fi
}

# -----------------------------------------------------------------------------
# Section 1 — runtime behaviour of the helper in an isolated repo.
# -----------------------------------------------------------------------------
printf '\n=== Helper runtime: resolves origin/<default> in a fresh repo ===\n'

SANDBOX="$(mktemp -d -t makato-98-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

# Build an "origin" bare repo with `main` as its default branch.
git init --quiet --bare --initial-branch=main "$SANDBOX/origin.git"

# Build a working clone, seed an initial commit on `main`, and push.
git clone --quiet "$SANDBOX/origin.git" "$SANDBOX/work"
(
  cd "$SANDBOX/work"
  git config user.email "test@example.com"
  git config user.name  "Test"
  echo "seed" > seed.txt
  git add seed.txt
  git commit --quiet -m "seed"
  git push --quiet origin main
)

# Add two more commits on origin/main that the local `main` will not see —
# this is the "stale local main" condition #98 describes.
git clone --quiet "$SANDBOX/origin.git" "$SANDBOX/upstream"
(
  cd "$SANDBOX/upstream"
  git config user.email "test@example.com"
  git config user.name  "Test"
  echo "already-merged-1" > merged-1.txt
  git add merged-1.txt
  git commit --quiet -m "feat: already-merged-1"
  echo "already-merged-2" > merged-2.txt
  git add merged-2.txt
  git commit --quiet -m "feat: already-merged-2"
  git push --quiet origin main
)

# Back in the working clone: do NOT pull. Fetch updates the remote ref but the
# local `main` branch still points at the seed commit — that is the bug condition.
cd "$SANDBOX/work"
git fetch --quiet origin
# Branch off origin/main (the realistic operator workflow per the issue
# reproducer) and add one feature commit.
git checkout --quiet -b feat/x origin/main
echo "feature" > feature.txt
git add feature.txt
git commit --quiet -m "feat: x"

# Sanity — local `main` is behind origin/main.
local_tip="$(git rev-parse main)"
origin_tip="$(git rev-parse origin/main)"
if [[ "$local_tip" == "$origin_tip" ]]; then
  FAIL=$((FAIL + 1))
  FAILURES+=("setup precondition — local main should lag origin/main, but they are equal")
  printf '  ✗ setup precondition: local main lags origin/main\n'
else
  PASS=$((PASS + 1))
  printf '  ✓ setup precondition: local main lags origin/main\n'
fi

# 1a. Helper resolves to `origin/main`.
resolved="$("$HELPER")"
assert_eq "$resolved" "origin/main" "default-branch.sh returns origin/main"

# -----------------------------------------------------------------------------
# Section 2 — reproduce the bug, then prove the fix.
# -----------------------------------------------------------------------------
printf '\n=== Bug reproduction: stale-main diff vs origin-main diff ===\n'

# Stale-main diff pulls in the already-merged files. The bug.
stale_diff="$(git diff main...HEAD --name-only | sort | tr '\n' ',' | sed 's/,$//')"
case ",$stale_diff," in
  *,merged-1.txt,*|*,merged-2.txt,*)
    PASS=$((PASS + 1))
    printf '  ✓ stale `git diff main...HEAD` pulls in already-merged commits (reproduces #98)\n'
    ;;
  *)
    FAIL=$((FAIL + 1))
    FAILURES+=("stale-main reproducer — expected merged-1.txt / merged-2.txt in diff but got: $stale_diff")
    printf '  ✗ stale `git diff main...HEAD` does not reproduce the bug — got: %s\n' "$stale_diff"
    ;;
esac

# Fixed diff sees only the feature file. The contract.
DEFAULT_REF="$("$HELPER")"
fixed_diff="$(git diff "$DEFAULT_REF...HEAD" --name-only | sort | tr '\n' ',' | sed 's/,$//')"
assert_eq "$fixed_diff" "feature.txt" "git diff \$DEFAULT_REF...HEAD lists only the branch's own change"

# files_changed count — the headline acceptance criterion in #98.
fixed_count="$(git diff "$DEFAULT_REF...HEAD" --name-only | wc -l | tr -d ' ')"
assert_eq "$fixed_count" "1" "files_changed via DEFAULT_REF equals 1 (not 3)"

# Return to the repo root for the static-contract section below.
cd "$REPO_ROOT"

# -----------------------------------------------------------------------------
# Section 3 — static contract: build skills reference the helper, not bare main.
# -----------------------------------------------------------------------------
printf '\n=== Static contract: build-* skills use default-branch.sh ===\n'

# Skills must reference the helper.
assert_grep 'shared/default-branch\.sh' \
  'plugins/makato-build/skills/build-simplify/SKILL.md' \
  'build-simplify references shared/default-branch.sh'

assert_grep 'shared/default-branch\.sh' \
  'plugins/makato-build/skills/build-review/SKILL.md' \
  'build-review references shared/default-branch.sh'

assert_grep 'shared/default-branch\.sh' \
  'plugins/makato-build/skills/build-create-pr/SKILL.md' \
  'build-create-pr references shared/default-branch.sh'

assert_grep 'shared/default-branch\.sh' \
  'plugins/makato-build/skills/build-push-to-git/SKILL.md' \
  'build-push-to-git references shared/default-branch.sh'

assert_grep 'shared/default-branch\.sh' \
  'plugins/makato-build/agents/diff-reviewer.md' \
  'diff-reviewer agent references shared/default-branch.sh'

# Skills must NOT contain the stale-main literal anymore.
# (CHANGELOG.md is excluded — historical entries describing past behaviour
# legitimately mention the old commands and are not executable contracts.)
for path in \
  plugins/makato-build/skills/build-simplify/SKILL.md \
  plugins/makato-build/skills/build-review/SKILL.md \
  plugins/makato-build/skills/build-create-pr/SKILL.md \
  plugins/makato-build/skills/build-push-to-git/SKILL.md \
  plugins/makato-build/agents/diff-reviewer.md
do
  assert_no_grep 'git (diff|log) main(\.\.|\.\.\.)' "$path" \
    "$path has no bare \`git diff/log main...HEAD\` literal"
done

# -----------------------------------------------------------------------------
# Summary.
# -----------------------------------------------------------------------------
printf '\n=== Summary ===\n'
printf '  passed: %d\n' "$PASS"
printf '  failed: %d\n' "$FAIL"

if (( FAIL > 0 )); then
  printf '\nFailures:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi

printf '\nAll checks passed.\n'
