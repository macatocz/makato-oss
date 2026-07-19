#!/usr/bin/env bash
# Contract / smoke test for build-verify gate-command consumption (#450).
#
# build-verify v1.8.0 updates Gates 1 and 2 to source their commands from
# gate-scout's new hook-command fields (build_hook_cmd, lint_hook_cmd) and
# adds error-count parsing so gates fail on N errors even when exit code is 0.
#
# T1 — build-verify SKILL.md Step 4 references build_hook_cmd
# T2 — build-verify SKILL.md Step 4 references pre-commit run --hook-stage manual pattern
# T3 — build-verify SKILL.md Step 5 references lint_hook_cmd
# T4 — build-verify SKILL.md Step 5 references pre-commit run --hook-stage manual pattern
# T5 — build-verify SKILL.md contains error-count parsing logic (parsed_errors in log entry)
# T6 — gate-definitions.md contains pre-commit hook path (hook-stage manual or pre-commit hook)
#
# All assertions are grep-based doc-contract checks.
# No mutation, no network.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FAIL=0

SKILL_MD="$PLUGIN_DIR/skills/build-verify/SKILL.md"
GATE_DEFS_MD="$PLUGIN_DIR/skills/build-verify/references/gate-definitions.md"

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

echo
if (( FAIL == 0 )); then
  echo "All build-verify gate-commands smoke tests passed."
  exit 0
else
  echo "$FAIL build-verify gate-commands smoke test(s) failed."
  exit 1
fi
