#!/usr/bin/env bash
# Smoke tests for scripts/harness-audit.sh.
#
# Run from the makato repo root (or any directory inside it):
#   plugins/makato-contribute/scripts/harness-audit-smoke-tests.sh
#
# Scenarios:
#   T1: AGENTS.md within threshold, has cross-ref → KEEP
#   T2: AGENTS.md section large (>150 lines total), no cross-ref → BLOAT
#   T3: agent with bypassPermissions + disallowedTools → OK
#   T4: agent with bypassPermissions, no disallowedTools, not in whitelist → READ_WRITE_MISMATCH
#   T5: agent without permissionMode field → MISSING_PM
#   T6: known write-capable agent (coder) with no disallowedTools → OK
#   T7: --non-interactive flag → no mutation (byte-identical output)
#   T8: empty plugins dir → exits 0 with no output
#
# Uses temporary sandbox directories; cleans up on exit.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/makato-contribute/scripts/harness-audit.sh"

SANDBOX="${CLAUDE_JOB_DIR:-/tmp}/harness-audit-smoke-$$"
mkdir -p "$SANDBOX"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

fail() { echo "  FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

# ---------------------------------------------------------------------------
# _make_agents_md <dir> <line_count> [--with-ref]
#   Write a synthetic AGENTS.md with the given total line count into dir.
#   When --with-ref is passed, the content includes a #NNN cross-reference.
# ---------------------------------------------------------------------------
_make_agents_md() {
  local dir="$1" line_count="$2" with_ref="${3:-}"
  mkdir -p "$dir"
  local file="$dir/AGENTS.md"
  {
    echo "# Test Plugin"
    echo ""
    echo "## Hard Constraints"
    echo ""
    echo "- No bad things"
    echo ""
    echo "## Custom Section"
    echo ""
    if [[ "$with_ref" == "--with-ref" ]]; then
      echo "This section relates to #123 and specs/my-spec."
    else
      echo "This section has no cross-reference at all."
    fi
    # Pad to the desired line count
    local current_lines=9
    while [[ $current_lines -lt $line_count ]]; do
      echo "# padding line $current_lines"
      (( current_lines++ )) || true
    done
  } > "$file"
}

# ---------------------------------------------------------------------------
# _make_agent_md <dir> <agent_name> [permissionMode=<val>] [disallowedTools=<val>]
#   Write a synthetic agent .md file with the given frontmatter into dir/agents/.
# ---------------------------------------------------------------------------
_make_agent_md() {
  local agents_dir="$1" agent_name="$2"
  shift 2
  local pm="" dt=""
  for arg in "$@"; do
    case "$arg" in
      permissionMode=*) pm="${arg#permissionMode=}" ;;
      disallowedTools=*) dt="${arg#disallowedTools=}" ;;
    esac
  done
  mkdir -p "$agents_dir"
  local file="$agents_dir/${agent_name}.md"
  {
    echo "---"
    echo "name: $agent_name"
    echo "description: Test agent"
    [[ -n "$pm" ]] && echo "permissionMode: $pm"
    [[ -n "$dt" ]] && echo "disallowedTools: $dt"
    echo "---"
    echo ""
    echo "# $agent_name"
  } > "$file"
}

# ---------------------------------------------------------------------------
# _classify <fake_repo_root>
#   Run harness-audit.sh against a fake repo root and return stdout.
# ---------------------------------------------------------------------------
_classify() {
  local repo_root="$1"
  bash "$SCRIPT" "$repo_root" 2>/dev/null
}

echo "=== T1: AGENTS.md within threshold, has cross-ref → KEEP ==="
(
  D="$SANDBOX/t1"
  PLUGIN_DIR="$D/plugins/myplugin"
  _make_agents_md "$PLUGIN_DIR" 50 --with-ref

  OUT="$(_classify "$D")"
  # All sections should be KEEP (file is within 150-line threshold)
  BLOAT="$(echo "$OUT" | python3 -c "
import sys,json
recs=[json.loads(l) for l in sys.stdin if l.strip()]
print(sum(1 for r in recs if r.get('type')=='agents-md' and r['action']=='BLOAT'))
")"
  [[ "$BLOAT" -eq 0 ]] || fail "T1: expected 0 BLOAT findings for a 50-line file, got $BLOAT (output: $OUT)"
  KEEPS="$(echo "$OUT" | python3 -c "
import sys,json
recs=[json.loads(l) for l in sys.stdin if l.strip()]
print(sum(1 for r in recs if r.get('type')=='agents-md' and r['action']=='KEEP'))
")"
  [[ "$KEEPS" -gt 0 ]] || fail "T1: expected at least 1 KEEP, got 0 (output: $OUT)"
)
pass "T1: AGENTS.md within threshold → all sections KEEP"

echo "=== T2: AGENTS.md section large (>150 lines total), no cross-ref → BLOAT ==="
(
  D="$SANDBOX/t2"
  PLUGIN_DIR="$D/plugins/bigplugin"
  _make_agents_md "$PLUGIN_DIR" 200  # no --with-ref

  OUT="$(_classify "$D")"
  # Custom Section should be BLOAT (no ref, file over threshold)
  BLOAT="$(echo "$OUT" | python3 -c "
import sys,json
recs=[json.loads(l) for l in sys.stdin if l.strip()]
print(sum(1 for r in recs if r.get('type')=='agents-md' and r['action']=='BLOAT'))
")"
  [[ "$BLOAT" -ge 1 ]] || fail "T2: expected at least 1 BLOAT for a 200-line file with no refs, got $BLOAT (output: $OUT)"
)
pass "T2: over-threshold AGENTS.md without cross-ref → BLOAT"

echo "=== T3: agent with bypassPermissions + disallowedTools → OK ==="
(
  D="$SANDBOX/t3"
  _make_agents_md "$D/plugins/myplugin" 50 --with-ref
  _make_agent_md "$D/plugins/myplugin/agents" "my-scout" \
    "permissionMode=bypassPermissions" "disallowedTools=Write, Edit, NotebookEdit"

  OUT="$(_classify "$D")"
  ACTION="$(echo "$OUT" | python3 -c "
import sys,json
recs=[json.loads(l) for l in sys.stdin if l.strip()]
perm=[r for r in recs if r.get('type')=='permission' and r['agent']=='my-scout']
print(perm[0]['action'] if perm else 'NONE')
")"
  [[ "$ACTION" == "OK" ]] || fail "T3: expected OK for bypassPermissions+disallowedTools, got $ACTION"
)
pass "T3: bypassPermissions + disallowedTools → OK"

echo "=== T4: agent with bypassPermissions, no disallowedTools, not in whitelist → READ_WRITE_MISMATCH ==="
(
  D="$SANDBOX/t4"
  _make_agents_md "$D/plugins/myplugin" 50 --with-ref
  _make_agent_md "$D/plugins/myplugin/agents" "unknown-agent" \
    "permissionMode=bypassPermissions"
  # No disallowedTools, not in known write-capable list

  OUT="$(_classify "$D")"
  ACTION="$(echo "$OUT" | python3 -c "
import sys,json
recs=[json.loads(l) for l in sys.stdin if l.strip()]
perm=[r for r in recs if r.get('type')=='permission' and r['agent']=='unknown-agent']
print(perm[0]['action'] if perm else 'NONE')
")"
  [[ "$ACTION" == "READ_WRITE_MISMATCH" ]] || fail "T4: expected READ_WRITE_MISMATCH, got $ACTION"
)
pass "T4: bypassPermissions + no disallowedTools + unknown agent → READ_WRITE_MISMATCH"

echo "=== T5: agent without permissionMode field → MISSING_PM ==="
(
  D="$SANDBOX/t5"
  _make_agents_md "$D/plugins/myplugin" 50 --with-ref
  _make_agent_md "$D/plugins/myplugin/agents" "no-pm-agent"
  # No permissionMode at all

  OUT="$(_classify "$D")"
  ACTION="$(echo "$OUT" | python3 -c "
import sys,json
recs=[json.loads(l) for l in sys.stdin if l.strip()]
perm=[r for r in recs if r.get('type')=='permission' and r['agent']=='no-pm-agent']
print(perm[0]['action'] if perm else 'NONE')
")"
  [[ "$ACTION" == "MISSING_PM" ]] || fail "T5: expected MISSING_PM, got $ACTION"
)
pass "T5: agent without permissionMode → MISSING_PM"

echo "=== T6: known write-capable agent (coder) with no disallowedTools → OK ==="
(
  D="$SANDBOX/t6"
  _make_agents_md "$D/plugins/myplugin" 50 --with-ref
  _make_agent_md "$D/plugins/myplugin/agents" "coder" \
    "permissionMode=bypassPermissions"
  # coder is in the write-capable whitelist

  OUT="$(_classify "$D")"
  ACTION="$(echo "$OUT" | python3 -c "
import sys,json
recs=[json.loads(l) for l in sys.stdin if l.strip()]
perm=[r for r in recs if r.get('type')=='permission' and r['agent']=='coder']
print(perm[0]['action'] if perm else 'NONE')
")"
  [[ "$ACTION" == "OK" ]] || fail "T6: expected OK for coder (write-capable whitelist), got $ACTION"
)
pass "T6: known write-capable agent coder → OK"

echo "=== T7: --non-interactive flag → exits 0, output byte-identical to regular run ==="
(
  D="$SANDBOX/t7"
  PLUGIN_DIR="$D/plugins/myplugin"
  _make_agents_md "$PLUGIN_DIR" 200  # no --with-ref → will have BLOAT findings
  _make_agent_md "$PLUGIN_DIR/agents" "my-scout" \
    "permissionMode=bypassPermissions" "disallowedTools=Write,Edit"

  # Run without flag
  OUT_PLAIN="$(bash "$SCRIPT" "$D" 2>/dev/null)"
  EXIT_PLAIN=$?

  # Run with --non-interactive
  OUT_NI="$(bash "$SCRIPT" "$D" "--non-interactive" 2>/dev/null)"
  EXIT_NI=$?

  # Both should exit 0 (classification only — never errors)
  [[ "$EXIT_PLAIN" -eq 0 ]] || fail "T7: plain run should exit 0, got $EXIT_PLAIN"
  [[ "$EXIT_NI" -eq 0 ]]    || fail "T7: --non-interactive run should exit 0, got $EXIT_NI"

  # The classifier output should be identical regardless of --non-interactive
  # (the flag is an approval-gate concern at the skill level; the bash helper
  # is pure classification in both cases).
  [[ "$OUT_PLAIN" == "$OUT_NI" ]] || fail "T7: --non-interactive output differs from plain run"
)
pass "T7: --non-interactive exits 0 with byte-identical classification output"

echo "=== T8: empty plugins dir → exits 0 with no output ==="
(
  D="$SANDBOX/t8"
  mkdir -p "$D/plugins"
  # No subdirectories → no AGENTS.md, no agents/

  OUT="$(bash "$SCRIPT" "$D" 2>/dev/null)"
  EXIT_CODE=$?
  [[ "$EXIT_CODE" -eq 0 ]] || fail "T8: expected exit 0 on empty plugins dir, got $EXIT_CODE"
  [[ -z "$OUT" ]] || fail "T8: expected no output on empty plugins dir, got: $OUT"
)
pass "T8: empty plugins dir → no-op exit-0"

echo ""
echo "All harness-audit-smoke-tests passed."
