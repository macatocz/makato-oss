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
for skill in build-implement-tdd build-implement-goal build-verify build-push-to-git build-create-pr build-refine build-simplify build-address-pr-comments; do
  assert_grep 'WORKTREE_PATH' \
    "plugins/makato-build/skills/$skill/SKILL.md" \
    "$skill mentions WORKTREE_PATH"
  assert_grep 'Workspace-isolation entry guard' \
    "plugins/makato-build/skills/$skill/SKILL.md" \
    "$skill has a Workspace-isolation entry guard"
  assert_grep '[Mm]andatory in autonomous' \
    "plugins/makato-build/skills/$skill/SKILL.md" \
    "$skill declares the field mandatory in autonomous mode"
  assert_grep 'git rev-parse --show-toplevel' \
    "plugins/makato-build/skills/$skill/SKILL.md" \
    "$skill documents the interactive-mode fallback"
done

printf '\n=== Contract: entry-guard runs before Step 1 for skills with prompts ===\n'
# Skills whose Step 1 calls AskUserQuestion must guard before the prompt, not
# after — otherwise an autonomous dispatch with empty WORKTREE_PATH deadlocks
# at the prompt instead of HALTing cleanly. Each of these skill files must
# explicitly reference "before Step 1" in their entry-guard section.
# (Issue #114 collapsed the bold "BEFORE Step 1" marker to lowercase prose
#  "before Step 1" inside a forward-ref to AUTONOMOUS-MODE.md; the contract
#  is unchanged — the guard still runs before any AskUserQuestion site.)
for skill in build-implement-tdd build-implement-goal build-simplify build-address-pr-comments build-refine; do
  assert_grep '[Bb]efore Step 1' \
    "plugins/makato-build/skills/$skill/SKILL.md" \
    "$skill entry-guard runs before Step 1 (no deadlock on AskUserQuestion)"
done

printf '\n=== Contract: spec-artefact reads use REPO_ROOT, not WORKTREE_PATH ===\n'
# Skills that read plan.md / stories.json / prd.md must resolve REPO_ROOT from
# the git common-dir so specs/ (gitignored) is found on the main checkout
# rather than the empty specs/ slot inside the worktree.
for skill in build-implement-tdd build-implement-goal build-push-to-git build-create-pr build-refine build-simplify build-address-pr-comments; do
  assert_grep 'REPO_ROOT' \
    "plugins/makato-build/skills/$skill/SKILL.md" \
    "$skill resolves REPO_ROOT for spec-artefact reads"
  assert_grep 'git-common-dir' \
    "plugins/makato-build/skills/$skill/SKILL.md" \
    "$skill derives REPO_ROOT via git-common-dir"
done

printf '\n=== Contract: build-log.sh is worktree-aware ===\n'
assert_grep 'git rev-parse --git-common-dir' \
  plugins/makato-build/shared/build-log.sh \
  'build-log.sh derives REPO_ROOT from git common-dir (worktree-safe)'
# Make sure the legacy --show-toplevel anchor was actually replaced (the
# fallback uses it but the primary resolver must not).
if grep -E '^REPO_ROOT="\$\(git rev-parse --show-toplevel\)"$' \
    "$REPO_ROOT/plugins/makato-build/shared/build-log.sh" >/dev/null; then
  FAIL=$((FAIL + 1))
  FAILURES+=('build-log.sh still uses bare --show-toplevel as the primary resolver')
  printf '  ✗ build-log.sh primary resolver does NOT use bare --show-toplevel\n'
else
  PASS=$((PASS + 1))
  printf '  ✓ build-log.sh primary resolver does NOT use bare --show-toplevel\n'
fi

printf '\n=== Contract: build-push-to-git Step 8 forwards WORKTREE_PATH to build-create-pr ===\n'
assert_grep 'WORKTREE_PATH.*forwarded|forwarded.*WORKTREE_PATH' \
  plugins/makato-build/skills/build-push-to-git/SKILL.md \
  'build-push-to-git Step 8 hand-off forwards WORKTREE_PATH in the context bundle'

printf '\n=== Contract: coder agent HALTs on empty WORKTREE_PATH in autonomous mode ===\n'
assert_grep 'MISSING_INPUT: WORKTREE_PATH required in autonomous mode' \
  plugins/makato-build/agents/coder.md \
  'coder.md Phase 0 declares MISSING_INPUT on empty WORKTREE_PATH'
assert_grep 'AGENT_ID' \
  plugins/makato-build/agents/coder.md \
  'coder.md Phase 0 detects autonomous mode via AGENT_ID'

printf '\n=== Contract: AUTONOMOUS-MODE.md documents the REPO_ROOT split ===\n'
assert_grep 'Two roots, one contract' \
  plugins/makato-build/AUTONOMOUS-MODE.md \
  'AUTONOMOUS-MODE.md has the WORKTREE_PATH vs REPO_ROOT explanation'
assert_grep 'specs/' \
  plugins/makato-build/AUTONOMOUS-MODE.md \
  'AUTONOMOUS-MODE.md notes specs/ is gitignored'
# The phantom $AUTONOMOUS env var check was removed; make sure it does not
# regress (an inline `${AUTONOMOUS:-…}` reference is fine as a doc cite, but
# the canonical falsy-check snippet must not include it).
if grep -E '"\$\{AUTONOMOUS:-false\}" == "true"' \
    "$REPO_ROOT/plugins/makato-build/AUTONOMOUS-MODE.md" >/dev/null; then
  FAIL=$((FAIL + 1))
  FAILURES+=('AUTONOMOUS-MODE.md still references phantom ${AUTONOMOUS:-false} env var')
  printf '  ✗ AUTONOMOUS-MODE.md does NOT carry the phantom AUTONOMOUS env-var check\n'
else
  PASS=$((PASS + 1))
  printf '  ✓ AUTONOMOUS-MODE.md does NOT carry the phantom AUTONOMOUS env-var check\n'
fi

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
assert_grep 'cross-task|ACCUMULATED_PRIOR|Cross-task regression sweep' \
  plugins/makato-build/skills/build-implement-tdd/SKILL.md \
  'build-implement-tdd Step 6 documents the cross-task regression sweep'

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
