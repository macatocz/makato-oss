#!/usr/bin/env bash
# Smoke tests for the spec_tier:plan-only lightweight planning lane (#210).
#
# makato skills are Markdown prompts, not runnable bash — these tests assert
# PROSE-LEVEL contract properties on the three SKILL.md files (build-refine,
# build-create-pr, seed-issue) plus their references, and on the shared
# halt-codes table. If the prose drifts — a guard is dropped, the manifest
# read disappears, the schema bump is reverted — a test flips red.
#
# End-to-end coverage (a real plan-only dispatch through build-refine) is out
# of scope for a prose smoke test: it would require a full `claude -p` session
# against a fixture spec folder, which this harness deliberately does not run.
#
# Asserts:
#   T1  — build-refine Step 3 NEW-READs seed-manifest.json and parses spec_tier.
#   T2  — build-refine widens the lightweight branch to spec_tier:plan-only
#         alongside the legacy local- prefix (single shared branch).
#   T3  — build-refine plan-only path bypasses the design.md-missing guard.
#   T4  — build-refine Step 4 sources AC from plan.md '## Acceptance criteria'
#         and explicitly does NOT emit a synthetic AC-1 on the plan-only path.
#   T5  — build-refine HALTs with MISSING_ACCEPTANCE when the section is
#         absent OR empty, treating both identically.
#   T6  — halt-codes.md registers MISSING_ACCEPTANCE for build-refine.
#   T8  — seed-issue documents optional spec_tier + schema_version "2" and
#         states absence preserves legacy behavior.
#   T9  — build-create-pr How-to-Test has a plan-only branch reading plan.md
#         '## Acceptance criteria' (D11 enabler).
#   T10 — the legacy local- prefix path and ticket path are still documented
#         as unchanged (regression guard on the prose contract).
#
# Pure grep against committed prose. No subprocess execution.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_DIR/../.." && pwd)"
FAIL=0

REFINE_MD="$PLUGIN_DIR/skills/build-refine/SKILL.md"
REFINE_SCHEMA="$PLUGIN_DIR/skills/build-refine/references/spec-artifacts-schema.md"
CREATE_PR_MD="$PLUGIN_DIR/skills/build-create-pr/SKILL.md"
HALT_CODES="$PLUGIN_DIR/halt-codes.md"
SEED_MD="$REPO_ROOT/plugins/makato-orchestrate/skills/seed-issue/SKILL.md"

_pass() { printf '  ✓ %s\n' "$1"; }
_fail() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ----- T1: build-refine NEW-READs seed-manifest.json + parses spec_tier -----
echo "T1: build-refine Step 3 reads seed-manifest.json and parses spec_tier"
if grep -qE 'seed-manifest\.json' "$REFINE_MD" \
    && grep -qE '\.spec_tier|spec_tier // ""|spec_tier' "$REFINE_MD"; then
  _pass "build-refine references seed-manifest.json + spec_tier"
else
  _fail "build-refine does not read seed-manifest.json / parse spec_tier"
fi
if grep -qiE 'never HALT on manifest read|treat an absent file.*as "no tier"|no tier' "$REFINE_MD"; then
  _pass "manifest read is non-fatal (absent/unparseable → no tier)"
else
  _fail "build-refine does not document non-fatal manifest read"
fi

# ----- T2: lightweight branch widened to plan-only alongside local- prefix -----
echo "T2: lightweight branch accepts BOTH local- prefix and spec_tier:plan-only"
if grep -qE 'starts with .?local-' "$REFINE_MD" \
    && grep -qE 'spec_tier == "plan-only"|spec_tier:plan-only' "$REFINE_MD" \
    && grep -qiE 'same single lightweight branch' "$REFINE_MD"; then
  _pass "both triggers resolve to one shared lightweight branch"
else
  _fail "build-refine does not document the shared lightweight branch for both triggers"
fi

# ----- T3: plan-only bypasses the design.md-missing guard -----
echo "T3: plan-only path bypasses the design.md-missing stop guard"
# The phrase wraps across lines and carries bold markers, so match tokens
# independently rather than as one contiguous string.
if grep -qiE 'bypass' "$REFINE_MD" \
    && grep -qE 'design\.md.?-missing guard|design\.md.*optional.*never a stop' "$REFINE_MD"; then
  _pass "plan-only explicitly bypasses design.md-missing guard"
else
  _fail "build-refine does not document design.md-guard bypass for plan-only"
fi

# ----- T4: AC sourced from plan.md, NOT synthetic AC-1 -----
echo "T4: plan-only sources AC from plan.md '## Acceptance criteria', not synthetic AC-1"
if grep -qE '## Acceptance criteria' "$REFINE_MD" \
    && grep -qE 'synthetic AC-1' "$REFINE_MD" \
    && grep -qiE 'real acceptance criteria exist|not the synthetic' "$REFINE_MD"; then
  _pass "plan-only reads plan.md AC and disclaims synthetic AC-1"
else
  _fail "build-refine does not source AC from plan.md / still emits synthetic AC-1 on plan-only"
fi

# ----- T5: MISSING_ACCEPTANCE HALT on absent-OR-empty section -----
echo "T5: MISSING_ACCEPTANCE HALTs on absent OR empty section (treated identically)"
if grep -qE 'MISSING_ACCEPTANCE' "$REFINE_MD" \
    && grep -qiE 'absent or empty|absent.*empty|empty.*identical|treat both cases' "$REFINE_MD"; then
  _pass "empty and missing sections both HALT with MISSING_ACCEPTANCE"
else
  _fail "build-refine does not HALT MISSING_ACCEPTANCE on absent/empty AC section"
fi

# ----- T6: halt-codes.md registers MISSING_ACCEPTANCE -----
echo "T6: halt-codes.md registers MISSING_ACCEPTANCE for build-refine"
if grep -qE 'MISSING_ACCEPTANCE' "$HALT_CODES" \
    && grep -E 'MISSING_ACCEPTANCE' "$HALT_CODES" | grep -qE 'build-refine'; then
  _pass "MISSING_ACCEPTANCE registered against build-refine"
else
  _fail "halt-codes.md missing MISSING_ACCEPTANCE / not tied to build-refine"
fi

# ----- T8: seed-issue documents optional spec_tier + schema_version 2 -----
echo "T8: seed-issue documents optional spec_tier and schema_version 2"
if grep -qE 'spec_tier' "$SEED_MD" \
    && grep -qE 'schema_version.*"2"|"schema_version": "2"' "$SEED_MD" \
    && grep -qiE 'optional|absent.*legacy|legacy behavior' "$SEED_MD"; then
  _pass "seed-issue documents optional spec_tier + schema_version 2 + legacy preservation"
else
  _fail "seed-issue does not document optional spec_tier / schema_version 2 / legacy note"
fi

# ----- T9: build-create-pr plan-only How-to-Test branch (D11) -----
echo "T9: build-create-pr How-to-Test reads plan.md AC for plan-only (D11)"
if grep -qiE 'spec_tier.*plan-only|plan-only' "$CREATE_PR_MD" \
    && grep -qE '## Acceptance criteria' "$CREATE_PR_MD"; then
  _pass "build-create-pr sources How-to-Test from plan.md on plan-only"
else
  _fail "build-create-pr How-to-Test has no plan-only / plan.md AC branch"
fi

# ----- T10: legacy paths still documented as unchanged (regression guard) -----
echo "T10: legacy local- prefix and ticket paths documented as unchanged"
if grep -qiE 'legacy|unchanged|byte-for-byte' "$REFINE_MD" \
    && grep -qE 'Ticket path' "$REFINE_MD"; then
  _pass "legacy local- and ticket paths preserved in prose"
else
  _fail "build-refine dropped the legacy/ticket-path preservation language"
fi

# ----- schema reference documents seed-manifest + plan-only AC source -----
echo "T11: spec-artifacts-schema.md documents seed-manifest.json + plan-only AC"
if grep -qE 'seed-manifest\.json' "$REFINE_SCHEMA" \
    && grep -qE 'spec_tier' "$REFINE_SCHEMA" \
    && grep -qE '## Acceptance criteria' "$REFINE_SCHEMA"; then
  _pass "schema reference documents manifest + plan-only AC source"
else
  _fail "spec-artifacts-schema.md missing seed-manifest / spec_tier / plan-only AC docs"
fi

echo
if (( FAIL == 0 )); then
  echo "All plan-only-tier smoke tests passed."
  exit 0
else
  echo "$FAIL plan-only-tier smoke test(s) failed."
  exit 1
fi
