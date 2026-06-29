#!/usr/bin/env bash
# Smoke tests for WORKTREE_PATH propagation (GAP-017 / #46 follow-up, #85).
# Validates the static documentation contract: every consumer skill/agent
# declares the WORKTREE_PATH input, applies the falsy-check / fallback,
# and forwards it through dispatch hand-offs. Runs from the makato repo root.
#
# The contract under test is the propagation CHAIN —
#   PO-agent → build-implement-tdd → coder
# all reference the canonical WORKTREE_PATH key, the workspace-isolation
# guard, and the falsy-fallback pattern from AUTONOMOUS-MODE.md.
#
# This is a documentation/grep smoke test rather than a runtime test because
# the consumer half is implemented as instructions to the LLM that drives
# each skill, not as executable code. A runtime test would require booting a
# full PO-agent → build-implement-tdd → coder dispatch chain; the documented
# contract is the source of truth and the runtime behaviour follows from it.
#
# Usage: plugins/makato-build/shared/worktree-path-propagation-smoke-tests.sh
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

printf '\n=== Contract: AUTONOMOUS-MODE.md anchors the WORKTREE_PATH section ===\n'
assert_grep '## WORKTREE_PATH — workspace-isolation contract' \
  plugins/makato-build/AUTONOMOUS-MODE.md \
  'AUTONOMOUS-MODE.md has WORKTREE_PATH heading'
assert_grep 'Falsy-check pattern' \
  plugins/makato-build/AUTONOMOUS-MODE.md \
  'AUTONOMOUS-MODE.md documents the falsy-check pattern'
assert_grep 'MISSING_INPUT: WORKTREE_PATH required in autonomous mode' \
  plugins/makato-build/AUTONOMOUS-MODE.md \
  'AUTONOMOUS-MODE.md specifies the HALT message'
assert_grep 'git rev-parse --show-toplevel' \
  plugins/makato-build/AUTONOMOUS-MODE.md \
  'AUTONOMOUS-MODE.md documents the interactive-mode fallback'

printf '\n=== Contract: each consumer skill declares WORKTREE_PATH input ===\n'
for skill in build-implement-tdd build-implement-goal build-verify build-push-to-git build-create-pr; do
  assert_grep 'WORKTREE_PATH' \
    "plugins/makato-build/skills/$skill/SKILL.md" \
    "$skill mentions WORKTREE_PATH"
  assert_grep 'Workspace-isolation entry guard' \
    "plugins/makato-build/skills/$skill/SKILL.md" \
    "$skill has a Workspace-isolation entry guard"
  assert_grep 'Mandatory in autonomous mode' \
    "plugins/makato-build/skills/$skill/SKILL.md" \
    "$skill declares the field mandatory in autonomous mode"
  assert_grep 'git rev-parse --show-toplevel' \
    "plugins/makato-build/skills/$skill/SKILL.md" \
    "$skill documents the interactive-mode fallback"
done

printf '\n=== Contract: coder agent receives and honours WORKTREE_PATH ===\n'
assert_grep 'WORKTREE_PATH' \
  plugins/makato-build/agents/coder.md \
  'coder.md declares WORKTREE_PATH as an Input field'
assert_grep 'Phase 0 — Workspace isolation' \
  plugins/makato-build/agents/coder.md \
  'coder.md adds a Phase 0 workspace-isolation step'
assert_grep 'cd "\$WORKTREE_PATH"' \
  plugins/makato-build/agents/coder.md \
  'coder.md cds into WORKTREE_PATH in Phase 0'

printf '\n=== Contract: propagation chain — PO-agent → build-implement-tdd → coder ===\n'
# Each link names the next consumer by their input key, so a future edit
# that breaks the chain shows up here.
assert_grep 'WORKTREE_PATH' \
  plugins/makato-orchestrate/agents/po-agent.md \
  'PO-agent (producer) names WORKTREE_PATH as the dispatch-bundle key'
assert_grep 'AUTONOMOUS-MODE.md' \
  plugins/makato-orchestrate/agents/po-agent.md \
  'PO-agent cross-references AUTONOMOUS-MODE.md for the consumer half'
assert_grep 'WORKTREE_PATH.*forwarded verbatim' \
  plugins/makato-build/skills/build-implement-tdd/SKILL.md \
  'build-implement-tdd forwards WORKTREE_PATH to nested coder dispatch'
assert_grep 'WORKTREE_PATH' \
  plugins/makato-build/agents/coder.md \
  'coder.md (innermost consumer) declares the same key'

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
printf '\nAll WORKTREE_PATH propagation contract checks passed.\n'
