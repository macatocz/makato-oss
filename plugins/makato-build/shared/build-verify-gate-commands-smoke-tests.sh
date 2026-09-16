#!/usr/bin/env bash
# Contract / smoke test for build-verify gate-command consumption (#450) and
# Runtime verification doc-contract (#583).
#
# build-verify v1.8.0 updates Gates 1 and 2 to source their commands from
# gate-scout's new hook-command fields (build_hook_cmd, lint_hook_cmd) and
# adds error-count parsing so gates fail on N errors even when exit code is 0.
#
# build-verify v1.10.0 adds Gate 6 plan-command precedence: Step 1 reads
# ## Runtime verification from plan-<N>.md; Gate 6 Step 8b uses PLAN_RUNTIME_CMD
# when non-empty (takes precedence over gate-scout health_check_cmd); absent
# section → gate skipped cleanly; runtime_cmd_source field added to build.jsonl.
#
# T1 — build-verify SKILL.md Step 4 references build_hook_cmd
# T2 — build-verify SKILL.md Step 4 references pre-commit run --hook-stage manual pattern
# T3 — build-verify SKILL.md Step 5 references lint_hook_cmd
# T4 — build-verify SKILL.md Step 5 references pre-commit run --hook-stage manual pattern
# T5 — build-verify SKILL.md contains error-count parsing logic (parsed_errors in log entry)
# T6 — gate-definitions.md contains pre-commit hook path (hook-stage manual or pre-commit hook)
# T7 — plan-template.md contains ## Runtime verification heading
# T8 — plan-schema.md documents Runtime Verification Schema section
# T9 — build-verify SKILL.md Gate 6 Step 8b references runtime_cmd_source field
# T10 — build-verify SKILL.md Step 1 references reading plan for the runtime command
# T11 — gate-scout separates the executable coverage command from its threshold
# T12 — gate-scout's example coverage command contains no human-readable suffix
#
# All assertions are grep-based doc-contract checks.
# No mutation, no network.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FAIL=0

SKILL_MD="$PLUGIN_DIR/skills/build-verify/SKILL.md"
GATE_SCOUT_MD="$PLUGIN_DIR/agents/gate-scout.md"
GATE_DEFS_MD="$PLUGIN_DIR/skills/build-verify/references/gate-definitions.md"
PLAN_TEMPLATE_MD="$PLUGIN_DIR/skills/build-refine/templates/plan-template.md"
PLAN_SCHEMA_MD="$PLUGIN_DIR/skills/build-refine/references/plan-schema.md"

_pass() { printf '  \xe2\x9c\x93 %s\n' "$1"; }
_fail() { printf '  \xe2\x9c\x97 %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ---- T1: build-verify Step 4 references build_hook_cmd ----------------------
echo "T1: build-verify SKILL.md Step 4 references build_hook_cmd"
if grep -qF 'build_hook_cmd' "$SKILL_MD"; then
  _pass "build-verify SKILL.md references build_hook_cmd"
else
  _fail "build-verify SKILL.md missing build_hook_cmd — Step 4 not updated"
fi

# ---- T2: build-verify Step 4 references pre-commit run --hook-stage manual --
echo "T2: build-verify SKILL.md Step 4 references pre-commit run --hook-stage manual pattern"
if grep -qF 'hook-stage manual' "$SKILL_MD"; then
  _pass "build-verify SKILL.md references hook-stage manual pattern"
else
  _fail "build-verify SKILL.md missing hook-stage manual pattern — pre-commit hook path not documented"
fi

# ---- T3: build-verify Step 5 references lint_hook_cmd -----------------------
echo "T3: build-verify SKILL.md Step 5 references lint_hook_cmd"
if grep -qF 'lint_hook_cmd' "$SKILL_MD"; then
  _pass "build-verify SKILL.md references lint_hook_cmd"
else
  _fail "build-verify SKILL.md missing lint_hook_cmd — Step 5 not updated"
fi

# ---- T4: build-verify Step 5 references pre-commit run --hook-stage manual --
# Already covered by T2 (same file, same pattern) — verify the pattern appears
# at least twice (once per gate step) to confirm both steps were updated.
echo "T4: build-verify SKILL.md Step 5 references pre-commit run --hook-stage manual pattern"
COUNT="$(grep -c 'hook-stage manual' "$SKILL_MD" 2>/dev/null || echo 0)"
if (( COUNT >= 2 )); then
  _pass "build-verify SKILL.md references hook-stage manual at least twice (Gates 1 and 2)"
else
  _fail "build-verify SKILL.md references hook-stage manual fewer than 2 times — Gate 1 or Gate 2 not updated"
fi

# ---- T5: error-count parsing logic in build-verify SKILL.md -----------------
echo "T5: build-verify SKILL.md contains error-count parsing logic (parsed_errors)"
if grep -qF 'parsed_errors' "$SKILL_MD"; then
  _pass "build-verify SKILL.md documents parsed_errors in log entry"
else
  _fail "build-verify SKILL.md missing parsed_errors — error-count parsing not documented"
fi

# ---- T6: gate-definitions.md contains pre-commit hook path ------------------
echo "T6: gate-definitions.md contains pre-commit hook path"
if grep -qF 'hook-stage manual' "$GATE_DEFS_MD" || grep -qiE 'pre-commit hook' "$GATE_DEFS_MD"; then
  _pass "gate-definitions.md documents pre-commit hook path"
else
  _fail "gate-definitions.md missing pre-commit hook path — Pre-commit Hook Commands section not added"
fi

# ---- T7: plan-template.md contains ## Runtime verification heading -----------
echo "T7: plan-template.md contains ## Runtime verification heading"
if grep -qF '## Runtime verification' "$PLAN_TEMPLATE_MD"; then
  _pass "plan-template.md contains ## Runtime verification heading"
else
  _fail "plan-template.md missing ## Runtime verification heading — Task 1 not applied"
fi

# ---- T8: plan-schema.md documents Runtime Verification Schema section --------
echo "T8: plan-schema.md documents Runtime Verification Schema section"
if grep -qF 'Runtime Verification Schema' "$PLAN_SCHEMA_MD"; then
  _pass "plan-schema.md contains Runtime Verification Schema section"
else
  _fail "plan-schema.md missing Runtime Verification Schema — Task 1 schema documentation not added"
fi

# ---- T9: build-verify SKILL.md Gate 6 Step 8b references runtime_cmd_source --
echo "T9: build-verify SKILL.md Gate 6 Step 8b references runtime_cmd_source field"
if grep -qF 'runtime_cmd_source' "$SKILL_MD"; then
  _pass "build-verify SKILL.md references runtime_cmd_source in gate-health log entry"
else
  _fail "build-verify SKILL.md missing runtime_cmd_source — Gate 6 log entry not updated"
fi

# ---- T10: build-verify SKILL.md Step 1 references plan for runtime command ---
echo "T10: build-verify SKILL.md Step 1 references reading plan for the runtime command"
if grep -qF 'PLAN_RUNTIME_CMD' "$SKILL_MD"; then
  _pass "build-verify SKILL.md references PLAN_RUNTIME_CMD — Step 1 reads plan.md runtime command"
else
  _fail "build-verify SKILL.md missing PLAN_RUNTIME_CMD — Step 1 plan-read not documented"
fi


# ---- T11: gate-scout separates coverage command from threshold ---------------
echo "T11: gate-scout separates coverage command from threshold"
if grep -qF 'coverage_threshold' "$GATE_SCOUT_MD" && \
   grep -qF '"coverage":"<exact executable command>|not found"' "$GATE_SCOUT_MD"; then
  _pass "gate-scout emits coverage_threshold separately from coverage"
else
  _fail "gate-scout coverage output contract does not separate command and threshold"
fi

# ---- T12: example coverage command is executable-only ------------------------
echo "T12: gate-scout example coverage command is executable-only"
if grep -qF '"coverage": "uv run coverage run -m pytest && uv run coverage report",' "$GATE_SCOUT_MD" && \
   ! grep -qF '"coverage": "uv run pytest --cov=src/brain --cov=src/body --cov=src/shared — threshold:' "$GATE_SCOUT_MD"; then
  _pass "gate-scout example coverage command has no threshold suffix"
else
  _fail "gate-scout example coverage command still contains metadata"
fi
echo
if (( FAIL == 0 )); then
  echo "All build-verify gate-commands smoke tests passed."
  exit 0
else
  echo "$FAIL build-verify gate-commands smoke test(s) failed."
  exit 1
fi
