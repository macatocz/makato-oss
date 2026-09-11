#!/usr/bin/env bash
# Runtime path contract checks for OMP/Claude-style installed plugins.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
FAIL=0

pass() { printf '  ✓ %s\n' "$1"; }
fail() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "T1: runtime-context resolves the current plugin outside its CWD"
ROOT_RESULT="$(
  cd /tmp
  REPO_ROOT="$REPO_ROOT" "$PLUGIN_ROOT/shared/runtime-context.sh" plugin-root makato-build
)"
if [[ "$ROOT_RESULT" == "$PLUGIN_ROOT" ]]; then
  pass "external CWD resolves makato-build root"
else
  fail "resolved root was '$ROOT_RESULT', expected '$PLUGIN_ROOT'"
fi

echo "T2: runtime-context resolves a sibling plugin from the source checkout"
ORCH_RESULT="$(
  cd /tmp
  REPO_ROOT="$REPO_ROOT" "$PLUGIN_ROOT/shared/runtime-context.sh" plugin-root makato-orchestrate
)"
if [[ "$ORCH_RESULT" == "$REPO_ROOT/plugins/makato-orchestrate" ]]; then
  pass "external CWD resolves makato-orchestrate root"
else
  fail "resolved sibling root was '$ORCH_RESULT'"
fi

echo "T3: build skills do not execute bare plugin helpers"
if rg -n --glob 'SKILL.md' \
  '^[[:space:]]*(shared/(build-log|log-bypass|default-branch|write-lessons)\.sh|plugins/makato-(build|orchestrate)/)' \
  "$PLUGIN_ROOT/skills" >/tmp/makato-build-runtime-paths.txt 2>/dev/null; then
  cat /tmp/makato-build-runtime-paths.txt
  fail "found consumer-CWD-relative helper command"
else
  pass "helper commands use an explicit installed root"
fi

echo "T4: root autonomous-mode references are runner-neutral"
if rg -n --glob 'SKILL.md' '@\.\./\.\./AUTONOMOUS-MODE\.md' "$PLUGIN_ROOT/skills" >/tmp/makato-build-autonomous-refs.txt 2>/dev/null; then
  cat /tmp/makato-build-autonomous-refs.txt
  fail "found an escaping @ reference to AUTONOMOUS-MODE.md"
else
  pass "skills read AUTONOMOUS-MODE.md through the runtime root"
fi

rm -f /tmp/makato-build-runtime-paths.txt /tmp/makato-build-autonomous-refs.txt

echo
if (( FAIL == 0 )); then
  echo "All runtime path smoke tests passed."
  exit 0
fi
echo "$FAIL runtime path smoke test(s) failed."
exit 1
