#!/usr/bin/env bash
# validate-agents-hard-constraints-smoke-tests.sh
# Smoke tests for validate-agents-hard-constraints.sh.
#
# Test cases:
#   T1 — AGENTS.md missing ## Hard Constraints -> expect exit 1
#   T2 — AGENTS.md with ## Hard Constraints after line 30 -> expect exit 1
#   T3 — AGENTS.md with ## Hard Constraints at line 3 (before line 30) -> expect exit 0
#   T4 — No files passed -> expect exit 0
#
# Run:
#   bash plugins/makato-core/pre-commit/validate-agents-hard-constraints-smoke-tests.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/validate-agents-hard-constraints.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FATAL: hook script not found or not executable at $SCRIPT" >&2
  exit 1
fi

PASS=0
FAIL=0
TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

run_test() {
  local name="$1" expected="$2"
  shift 2
  local actual_exit=0
  "$SCRIPT" "$@" 2>/dev/null || actual_exit=$?
  if [[ "$actual_exit" -eq "$expected" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name -- expected exit $expected, got $actual_exit"
    FAIL=$((FAIL + 1))
  fi
}

# T1: AGENTS.md missing ## Hard Constraints entirely
T1="$TMPDIR_LOCAL/T1_AGENTS.md"
cat > "$T1" << 'EOF'
# My Plugin -- Contributor Guide

## Goal

Does things.
EOF
run_test "T1: missing Hard Constraints section, exit 1" 1 "$T1"

# T2: AGENTS.md with ## Hard Constraints at line 35 (too late)
T2="$TMPDIR_LOCAL/T2_AGENTS.md"
{
  echo "# My Plugin"
  echo ""
  for i in $(seq 1 31); do echo "line $i content"; done
  echo ""
  echo "## Hard Constraints"
  echo ""
  echo "Never do bad things."
} > "$T2"
run_test "T2: Hard Constraints after line 30, exit 1" 1 "$T2"

# T3: AGENTS.md with ## Hard Constraints at line 3 (well within limit)
T3="$TMPDIR_LOCAL/T3_AGENTS.md"
cat > "$T3" << 'EOF'
# My Plugin -- Contributor Guide

## Hard Constraints

- Never edit source files directly.
- Always run tests before committing.
- Do not add bypassPermissions without documented justification.
- Skills must be self-contained with no ../outside-plugin paths.
- Every skill must log JSONL session start, steps, and session end.

## Goal

Does things well.
EOF
run_test "T3: Hard Constraints before line 30, exit 0" 0 "$T3"

# T4: No files passed (empty args)
run_test "T4: no files passed, exit 0" 0

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
