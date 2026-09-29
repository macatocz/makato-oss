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
echo "T3: runtime-context discovers an installed build plugin via omp"
TMP_ROOT="$(mktemp -d)"
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/helper/shared"
cp "$PLUGIN_ROOT/shared/runtime-context.sh" "$TMP_ROOT/helper/shared/runtime-context.sh"
cat >"$TMP_ROOT/bin/omp" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"marketplace":[{"id":"makato-build@makato-suite","entries":[{"installPath":"'"$PLUGIN_ROOT"'"}]}]}'
EOF
chmod +x "$TMP_ROOT/bin/omp"
OMP_RESULT="$(
  PATH="$TMP_ROOT/bin:$PATH" \
    "$TMP_ROOT/helper/shared/runtime-context.sh" plugin-root makato-build
)"
if [[ "$OMP_RESULT" == "$PLUGIN_ROOT" ]]; then
  pass "omp registry resolves makato-build without runner env vars"
else
  fail "omp registry resolved '$OMP_RESULT', expected '$PLUGIN_ROOT'"
fi
rm -rf "$TMP_ROOT"


echo "T4: build skills do not execute bare plugin helpers"
if rg -n --glob 'SKILL.md' \
  '^[[:space:]]*(shared/(build-log|log-bypass|default-branch|write-lessons|interactive-worktree|spec_folder)\.sh|plugins/makato-(build|orchestrate)/)' \
  "$PLUGIN_ROOT/skills" >/tmp/makato-build-runtime-paths.txt 2>/dev/null; then
  cat /tmp/makato-build-runtime-paths.txt
  fail "found consumer-CWD-relative helper command"
else
  pass "helper commands use an explicit installed root"
fi

echo "T5: root autonomous-mode references are runner-neutral"
if rg -n --glob 'SKILL.md' '@\.\./\.\./AUTONOMOUS-MODE\.md' "$PLUGIN_ROOT/skills" >/tmp/makato-build-autonomous-refs.txt 2>/dev/null; then
  cat /tmp/makato-build-autonomous-refs.txt
  fail "found an escaping @ reference to AUTONOMOUS-MODE.md"
else
  pass "skills read AUTONOMOUS-MODE.md through the runtime root"
fi

echo "T6: build skills do not resolve suite-owned agents from skill-relative paths"
if rg -n --glob 'SKILL.md' 'agents/gate-scout\.md|@[^` ]*gate-scout\.md' \
  "$PLUGIN_ROOT/skills" >/tmp/makato-build-relative-agent-paths.txt 2>/dev/null; then
  cat /tmp/makato-build-relative-agent-paths.txt
  fail "found a skill-relative gate-scout agent path"
else
  pass "gate-scout is dispatched by registry name, not a skill-relative path"
fi

echo "T7: build skills never probe consumer-repository plugin siblings"
if rg -n 'REPO_ROOT/plugins/makato-' \
  "$PLUGIN_ROOT/skills/build-refine/SKILL.md" \
  "$PLUGIN_ROOT/skills/build-implement-tdd/SKILL.md" \
  "$PLUGIN_ROOT/skills/build-simplify/SKILL.md" \
  >/tmp/makato-build-consumer-plugin-paths.txt 2>/dev/null; then
  cat /tmp/makato-build-consumer-plugin-paths.txt
  fail "found a consumer-repository plugin path probe"
else
  pass "suite-owned files are resolved through installed roots"
fi

echo "T8: optional orchestrate scout dispatch checks installed root and agent"
if grep -q 'MAKATO_ORCHESTRATE_ROOT' \
  "$PLUGIN_ROOT/skills/build-implement-tdd/SKILL.md" &&
   grep -q 'agents/task-file-scout\.md' \
  "$PLUGIN_ROOT/skills/build-implement-tdd/SKILL.md"; then
  pass "task-file-scout dispatch has an explicit optional-root guard"
else
  fail "task-file-scout dispatch lacks installed-root/agent availability guard"
fi

echo "T9: exploration skips planned files before parallel reads"
if grep -q 'create.*target' "$PLUGIN_ROOT/skills/build-refine/SKILL.md" &&
   grep -q 'Promise\.all' "$PLUGIN_ROOT/skills/build-refine/SKILL.md" &&
   grep -q 'Promise\.all' "$PLUGIN_ROOT/skills/build-explore/SKILL.md" &&
   grep -q 'Promise\.all' "$REPO_ROOT/plugins/makato-orchestrate/agents/task-file-scout.md" &&
   grep -q 'confirmed regular files' "$REPO_ROOT/plugins/makato-orchestrate/agents/task-file-scout.md"; then
  pass "exploration paths are filtered before OMP parallel reads"
else
  fail "missing-file preflight contract is incomplete"
fi

echo "T10: PR artifact validation uses explicit portable paths"
if grep -q 'ARTIFACT_PATH="\$SPEC_FOLDER/created-issues.json"' \
   "$PLUGIN_ROOT/skills/build-create-pr/SKILL.md" &&
   grep -q 'SCHEMA_PATH=' "$PLUGIN_ROOT/skills/build-create-pr/SKILL.md" &&
   grep -q 'MAKATO_PLAN_ROOT' "$PLUGIN_ROOT/skills/build-create-pr/SKILL.md" &&
   ! grep -q 'SCHEMA_PATH=.*REPO_ROOT/plugins/makato-plan' \
     "$PLUGIN_ROOT/skills/build-create-pr/SKILL.md" &&
   ! grep -q "open('\$SPEC_FOLDER/" \
     "$PLUGIN_ROOT/skills/build-create-pr/SKILL.md"; then
  pass "PR artifact and schema paths are explicit and consumer-repo safe"
else
  fail "PR artifact validation still uses an undefined or consumer-relative path"
fi

rm -f /tmp/makato-build-relative-agent-paths.txt \
  /tmp/makato-build-consumer-plugin-paths.txt /tmp/makato-build-scout-guard.txt

rm -f /tmp/makato-build-runtime-paths.txt /tmp/makato-build-autonomous-refs.txt

echo
if (( FAIL == 0 )); then
  echo "All runtime path smoke tests passed."
  exit 0
fi
echo "$FAIL runtime path smoke test(s) failed."
exit 1
