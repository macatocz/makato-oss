#!/usr/bin/env bash
# Contract / smoke test for gate-scout pre-commit hook-commands probe (#450).
#
# gate-scout v1.2.0 adds Step 1d: it probes .pre-commit-config.yaml for
# type-check (pyright/mypy) and lint (ruff/flake8/pylint) hook IDs and
# exposes new R1 data fields (build_hook_cmd, lint_hook_cmd, pyright_env,
# build_hook_missing, lint_hook_missing) so build-verify Gates 1 and 2 can
# run the CI-authoritative pre-commit command instead of a raw tool invocation.
#
# T1 — gate-scout.md Step 1d probes .pre-commit-config.yaml
# T2 — gate-scout.md maps pyright → build_hook_cmd
# T3 — gate-scout.md maps ruff → lint_hook_cmd
# T4 — gate-scout R1 data shape includes build_hook_cmd and lint_hook_cmd fields
# T5 — gate-scout version is 1.2.0 or higher
#
# All assertions are grep-based doc-contract checks.
# No mutation, no network.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FAIL=0

GATE_SCOUT_MD="$PLUGIN_DIR/agents/gate-scout.md"

_pass() { printf '  \xe2\x9c\x93 %s\n' "$1"; }
_fail() { printf '  \xe2\x9c\x97 %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ---- T1: gate-scout.md Step 1d probes .pre-commit-config.yaml ---------------
echo "T1: gate-scout.md Step 1d probes .pre-commit-config.yaml"
if grep -qF 'pre-commit-config.yaml' "$GATE_SCOUT_MD"; then
  _pass "gate-scout.md references .pre-commit-config.yaml"
else
  _fail "gate-scout.md does not reference .pre-commit-config.yaml — Step 1d missing"
fi

# ---- T2: gate-scout.md maps pyright → build_hook_cmd -----------------------
echo "T2: gate-scout.md maps pyright → build_hook_cmd"
if grep -qF 'build_hook_cmd' "$GATE_SCOUT_MD"; then
  _pass "gate-scout.md documents build_hook_cmd field"
else
  _fail "gate-scout.md missing build_hook_cmd field"
fi

# ---- T3: gate-scout.md maps ruff → lint_hook_cmd ---------------------------
echo "T3: gate-scout.md maps ruff → lint_hook_cmd"
if grep -qF 'lint_hook_cmd' "$GATE_SCOUT_MD"; then
  _pass "gate-scout.md documents lint_hook_cmd field"
else
  _fail "gate-scout.md missing lint_hook_cmd field"
fi

# ---- T4: gate-scout R1 data shape includes build_hook_cmd and lint_hook_cmd -
echo "T4: gate-scout R1 data shape includes build_hook_cmd and lint_hook_cmd"
# Both fields must appear in the data shape description (prose section) and
# the success example JSON block.
if grep -qF '"build_hook_cmd"' "$GATE_SCOUT_MD" && grep -qF '"lint_hook_cmd"' "$GATE_SCOUT_MD"; then
  _pass "gate-scout.md R1 data shape includes both build_hook_cmd and lint_hook_cmd"
else
  _fail "gate-scout.md R1 data shape missing build_hook_cmd or lint_hook_cmd"
fi

# ---- T5: gate-scout version is 1.2.0 or higher ------------------------------
echo "T5: gate-scout version is 1.2.0 or higher"
if grep -qE 'version: "1\.[2-9]\.' "$GATE_SCOUT_MD" || grep -qE 'version: "1\.2\.0"' "$GATE_SCOUT_MD"; then
  _pass "gate-scout.md version is 1.2.0 or higher"
else
  _fail "gate-scout.md version is not 1.2.0 or higher — bump required"
fi

echo
if (( FAIL == 0 )); then
  echo "All gate-scout hook-commands smoke tests passed."
  exit 0
else
  echo "$FAIL gate-scout hook-commands smoke test(s) failed."
  exit 1
fi
