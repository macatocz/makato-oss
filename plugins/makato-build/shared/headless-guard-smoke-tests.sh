#!/usr/bin/env bash
# Smoke tests for the MAKATO_HEADLESS defensive-guard contract (#163).
#
# Skills in makato-build are Markdown prompts, not runnable bash — these
# tests assert PROSE-LEVEL contract properties on SKILL.md and
# AUTONOMOUS-MODE.md, plus wiring properties on the two makato-orchestrate
# dispatch sites that MUST export MAKATO_HEADLESS=1. If the prose drifts
# or a caller forgets to export the env var, a test flips red.
#
# Asserts:
#   T1 — AUTONOMOUS-MODE.md § *Defensive-headless guard* exists and
#        documents that MAKATO_HEADLESS is NOT a 4th autonomous trigger.
#   T2 — build-refine SKILL.md has a Step 1b headless guard that HALTs
#        with MISSING_INPUT before Step 2 when MAKATO_HEADLESS=1 AND no
#        autonomous trigger fired.
#   T3 — build-refine Step 1b documents the "autonomous trigger wins over
#        MAKATO_HEADLESS" precedence (guard is a strict AND).
#   T4 — plugins/makato-orchestrate/scripts/loop.sh cmd_dispatch exports
#        MAKATO_HEADLESS=1 alongside the po-agent delegation prompt.
#   T5 — plugins/makato-orchestrate/scripts/context-handoff.sh
#        _emit_resume exports MAKATO_HEADLESS=1 in the emitted resume
#        script (belt-and-braces after HALT-007B handoff).
#
# The tests are pure grep against committed prose/code. There is no
# subprocess-level execution here because the skill guard runs inside a
# Claude session, not as a shell command — end-to-end coverage of the
# HALT path is out of scope for a smoke test (would require a full
# `claude -p` session against a fixture spec folder).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_DIR/../.." && pwd)"
FAIL=0

_pass() { printf '  ✓ %s\n' "$1"; }
_fail() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ----- T1: AUTONOMOUS-MODE.md documents the guard as a non-trigger -----
echo "T1: AUTONOMOUS-MODE.md § Defensive-headless guard"
AUTONOMOUS_MD="$PLUGIN_DIR/AUTONOMOUS-MODE.md"
if grep -qE '^## Defensive-headless guard' "$AUTONOMOUS_MD"; then
  _pass "guard section header present"
else
  _fail "'## Defensive-headless guard' section missing from AUTONOMOUS-MODE.md"
fi
if grep -qE 'not a fourth autonomous trigger' "$AUTONOMOUS_MD"; then
  _pass "guard explicitly disclaims trigger status"
else
  _fail "AUTONOMOUS-MODE.md does not disclaim MAKATO_HEADLESS as a trigger"
fi
if grep -qE 'MAKATO_HEADLESS=1.*(?:HALT|halt).*MISSING_INPUT' "$AUTONOMOUS_MD" \
    || grep -qE 'MISSING_INPUT: headless-without-autonomous' "$AUTONOMOUS_MD"; then
  _pass "guard HALT payload documented"
else
  _fail "AUTONOMOUS-MODE.md missing MISSING_INPUT / halt semantics"
fi

# ----- T2: build-refine SKILL.md has Step 1b guard -----
echo "T2: build-refine Step 1b headless guard"
REFINE_MD="$PLUGIN_DIR/skills/build-refine/SKILL.md"
if grep -qE '^### Step 1b — Headless-context defensive guard' "$REFINE_MD"; then
  _pass "Step 1b heading present"
else
  _fail "build-refine SKILL.md missing '### Step 1b — Headless-context defensive guard'"
fi
if grep -qE 'MAKATO_HEADLESS=1' "$REFINE_MD" && \
    grep -qE 'MISSING_INPUT: headless-without-autonomous' "$REFINE_MD"; then
  _pass "Step 1b names the env var and the HALT payload"
else
  _fail "Step 1b prose missing MAKATO_HEADLESS or the halt payload"
fi
# Step 1b must sit between Step 1a and Step 2 — order asserts the
# guard fires BEFORE the spec-folder lookup, i.e. before any Step 11
# AskUserQuestion could ever be reached.
STEP_1A_LINE="$(grep -nE '^### Step 1a' "$REFINE_MD" | head -1 | cut -d: -f1)"
STEP_1B_LINE="$(grep -nE '^### Step 1b' "$REFINE_MD" | head -1 | cut -d: -f1)"
STEP_2_LINE="$(grep -nE '^### Step 2' "$REFINE_MD" | head -1 | cut -d: -f1)"
if [[ -n "$STEP_1A_LINE" && -n "$STEP_1B_LINE" && -n "$STEP_2_LINE" ]] \
    && (( STEP_1A_LINE < STEP_1B_LINE )) && (( STEP_1B_LINE < STEP_2_LINE )); then
  _pass "Step 1b ordered between Step 1a and Step 2"
else
  _fail "Step 1a/1b/2 heading order broken (1a=$STEP_1A_LINE 1b=$STEP_1B_LINE 2=$STEP_2_LINE)"
fi

# ----- T3: precedence documented (autonomous trigger wins) -----
echo "T3: build-refine Step 1b precedence contract"
if grep -qE 'autonomous wins' "$REFINE_MD" \
    || grep -qE 'strict AND' "$REFINE_MD"; then
  _pass "Step 1b documents autonomous-wins precedence"
else
  _fail "Step 1b does not document precedence (autonomous trigger + MAKATO_HEADLESS)"
fi

# ----- T4: loop.sh cmd_dispatch exports MAKATO_HEADLESS=1 -----
echo "T4: loop.sh cmd_dispatch exports MAKATO_HEADLESS=1"
LOOP_SH="$REPO_ROOT/plugins/makato-orchestrate/scripts/loop.sh"
if grep -qE 'MAKATO_HEADLESS=1[[:space:]]+"\$CLAUDE_BIN"' "$LOOP_SH"; then
  _pass "loop.sh cmd_dispatch line exports MAKATO_HEADLESS=1"
else
  _fail "loop.sh cmd_dispatch does NOT export MAKATO_HEADLESS=1 on the claude invocation"
fi

# ----- T5: context-handoff.sh _emit_resume exports MAKATO_HEADLESS=1 -----
echo "T5: context-handoff.sh resume script exports MAKATO_HEADLESS=1"
HANDOFF_SH="$REPO_ROOT/plugins/makato-orchestrate/scripts/context-handoff.sh"
# The resume script is a heredoc — MAKATO_HEADLESS must appear on the
# `exec` line inside that heredoc so it lands in the emitted script.
if grep -qE 'exec[[:space:]]+env[[:space:]]+MAKATO_HEADLESS=1[[:space:]]+"\$CLAUDE_BIN"' "$HANDOFF_SH"; then
  _pass "context-handoff.sh resume script exports MAKATO_HEADLESS=1"
else
  _fail "context-handoff.sh resume script does NOT export MAKATO_HEADLESS=1"
fi

echo
if (( FAIL == 0 )); then
  echo "All 5 headless-guard smoke tests passed."
  exit 0
else
  echo "$FAIL headless-guard smoke test(s) failed."
  exit 1
fi
