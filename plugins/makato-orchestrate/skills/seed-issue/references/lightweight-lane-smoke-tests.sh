#!/usr/bin/env bash
# Integration smoke tests for the seed-issue lightweight planning lane (#212).
#
# seed-issue's Step 8.5 orchestrates a live LLM agent (light-planner) and gh
# calls that cannot run in CI. What CAN — and must — be tested deterministically
# is the DECISION LOGIC that gates board promotion: given a plan-tier label and
# the guard's verdict on the plan.md that exists after the agent runs, does
# seed-issue promote, defer, or fall back correctly?
#
# This test models Step 2.5 (tier detection) + Step 8.5b/c (guard → promote or
# fallback) as pure shell over fixtures, mirroring the three spec scenarios in
# issue #212:
#   Scenario 1: plan-tier:light + substantive body → valid plan → PROMOTE.
#   Scenario 2: plan-tier:light + thin body → stub plan → FALLBACK (re-tier full).
#   Scenario 3: plan-tier:full → standard path, light-planner NOT dispatched.
#
# The guard itself (validate-plan-body.sh) has its own unit suite; here we
# assert the lane's routing decision, which is the #212 restructure's core risk.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
GUARD="$REPO_ROOT/plugins/makato-orchestrate/scripts/validate-plan-body.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# --- Step 2.5 model: derive the lane from labels + type --------------------
# Mirrors SKILL.md Step 2.5: LIGHTWEIGHT_LANE=true iff plan-tier:light AND
# new-work. Emits "<lane> <tier>".
detect_lane() {
  local type="$1"; shift
  local labels; labels="$(printf '%s\n' "$@")"
  local tier
  tier="$(printf '%s\n' "$labels" | grep -m1 -oE 'plan-tier:(light|full|change)' | sed 's/^plan-tier://' || true)"
  [ -z "$tier" ] && tier="none"
  if [ "$tier" = "light" ] && [ "$type" = "new-work" ]; then
    printf 'true %s\n' "$tier"
  else
    printf 'false %s\n' "$tier"
  fi
}

# --- Step 8.5b/c model: the promotion decision ----------------------------
# Given the lane flag and (for the lightweight lane) the plan.md the agent
# left behind, decide the board action. Emits one of:
#   promote            — lightweight lane, guard valid → set spec_tier + Ready
#   fallback           — lightweight lane, guard invalid → re-tier full, stay Todo
#   promote-standard   — standard path, promote unconditionally (no agent)
decide() {
  local lane="$1" plan="$2"
  if [ "$lane" != "true" ]; then
    printf 'promote-standard\n'
    return 0
  fi
  # Lightweight lane: the guard verdict is the source of truth.
  if bash "$GUARD" "$plan" >/dev/null 2>&1; then
    printf 'promote\n'
  else
    printf 'fallback\n'
  fi
}

check() {
  local expected="$1" got="$2"
  if [ "$got" = "$expected" ]; then
    pass=$((pass + 1)); printf '  ✓ %s → %s\n' "${TEST_NAME:-test}" "$got"
  else
    fail=$((fail + 1)); printf '  ✗ %s: expected [%s] got [%s]\n' "${TEST_NAME:-test}" "$expected" "$got"
  fi
}

# ---------------------------------------------------------------------------
# Fixtures: the plan.md that exists AFTER light-planner runs.
# ---------------------------------------------------------------------------

# A full plan (light-planner success) — Scenario 1.
cat > "$TMP/full-plan.md" <<'EOF'
# Implementation Plan: 300-add-json-flag

## Tasks

1. Add a `--json` flag to `foo list` (goal).
2. Serialize the item array to stdout as JSON (tdd).

## Acceptance criteria

- `foo list --json` prints the item array as JSON to stdout.
- The command exits non-zero when the result set is empty.
EOF

# The seed stub (thin body — light-planner declined to overwrite) — Scenario 2.
cat > "$TMP/stub-plan.md" <<'EOF'
# Plan: Add dark mode

> Auto-seeded by seed-issue v1.2.0 on 2026-07-10. Replace this stub with a
> full plan before the PO-agent starts.

## Issue

[#301](https://github.com/macatocz/makato/issues/301)

## Acceptance criteria

_To be filled in. The PO-agent will HALT with HALT-006 (MISSING_SPEC) if
this file contains only the stub text above._
EOF

# ---------------------------------------------------------------------------
# Scenario 1 — plan-tier:light + substantive body → valid plan → PROMOTE
# ---------------------------------------------------------------------------
TEST_NAME="S1a tier detection: plan-tier:light + new-work → lane=true"
check "true light" "$(detect_lane new-work "plan-tier:light" "type:feature" "effort:s")"

TEST_NAME="S1b decision: lightweight lane + valid plan → promote"
lane="$(detect_lane new-work "plan-tier:light" "type:feature" | cut -d' ' -f1)"
check "promote" "$(decide "$lane" "$TMP/full-plan.md")"

# ---------------------------------------------------------------------------
# Scenario 2 — plan-tier:light + thin body → stub remains → FALLBACK
# ---------------------------------------------------------------------------
TEST_NAME="S2a tier detection: plan-tier:light + new-work → lane=true"
check "true light" "$(detect_lane new-work "plan-tier:light" "type:feature")"

TEST_NAME="S2b decision: lightweight lane + stub plan → fallback (re-tier full)"
lane="$(detect_lane new-work "plan-tier:light" "type:feature" | cut -d' ' -f1)"
check "fallback" "$(decide "$lane" "$TMP/stub-plan.md")"

# ---------------------------------------------------------------------------
# Scenario 3 — plan-tier:full → standard path, light-planner NOT dispatched
# ---------------------------------------------------------------------------
TEST_NAME="S3a tier detection: plan-tier:full → lane=false"
check "false full" "$(detect_lane new-work "plan-tier:full" "type:feature")"

TEST_NAME="S3b decision: standard path → promote-standard (no agent, no guard)"
lane="$(detect_lane new-work "plan-tier:full" "type:feature" | cut -d' ' -f1)"
check "promote-standard" "$(decide "$lane" "/nonexistent-guard-not-consulted.md")"

# ---------------------------------------------------------------------------
# Edge cases on the routing itself
# ---------------------------------------------------------------------------
TEST_NAME="E1 plan-tier:light but type=change → lane=false (light lane is new-work only)"
check "false light" "$(detect_lane change "plan-tier:light" "type:change")"

TEST_NAME="E2 no plan-tier label → lane=false, tier=none (soft dep on #211)"
check "false none" "$(detect_lane new-work "type:feature" "effort:s")"

TEST_NAME="E3 plan-tier:change → lane=false (change tier is not the light lane)"
check "false change" "$(detect_lane new-work "plan-tier:change")"

TEST_NAME="E4 standard path never consults the guard (guard file absent → still promote-standard)"
check "promote-standard" "$(decide "false" "/definitely/not/here.md")"

echo ""
echo "seed-issue lightweight-lane smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
