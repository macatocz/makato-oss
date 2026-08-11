#!/usr/bin/env bash
# Smoke tests for the MAKATO_TRANSCRIPT_PATH env override in
# scripts/functions.sh _emit_langfuse_trace.
#
# Strategy: because functions.sh is not standalone (it is sourced by loop.sh),
# these tests verify:
#   Part A (structural) — MAKATO_TRANSCRIPT_PATH is referenced in the
#     _emit_langfuse_trace function body in functions.sh.
#   Part B (behavioural) — a minimal wrapper that replicates only the
#     transcript-path derivation logic shows the env override is honoured.
#     The wrapper code is extracted character-for-character from functions.sh
#     (via grep) so it reflects the actual production logic, not a copy.
#
# Usage:
#   plugins/makato-orchestrate/scripts/tests/langfuse-trace-smoke-tests.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUNCTIONS_SH="$SCRIPT_DIR/../functions.sh"

PASS=0; FAIL=0; FAILED_TESTS=()
pass() { PASS=$((PASS + 1)); echo "  ok  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); echo "  FAIL $1 — $2"; }

# ---- T1: structural — MAKATO_TRANSCRIPT_PATH referenced in _emit_langfuse_trace ----
t1_env_var_present() {
  if grep -A40 '^_emit_langfuse_trace()' "$FUNCTIONS_SH" | \
      grep -q 'MAKATO_TRANSCRIPT_PATH'; then
    pass "T1 MAKATO_TRANSCRIPT_PATH referenced in _emit_langfuse_trace"
  else
    fail "T1" "MAKATO_TRANSCRIPT_PATH NOT found in _emit_langfuse_trace body"
  fi
}

# ---- T2: MAKATO_TRANSCRIPT_PATH override honoured --------------------------------
# Extracts the actual transcript-path block from functions.sh and evaluates it in
# isolation: the result must equal MAKATO_TRANSCRIPT_PATH when set.
t2_override_honoured() {
  local d; d="$(mktemp -d)"
  local fake_repo="$d/repo"
  local session_id="test-session-abc"
  local project_hash; project_hash="$(echo -n "$fake_repo" | sed 's|/|-|g' | sed 's|^-||')"
  local expected_override="/tmp/custom-transcript.jsonl"

  # Build a tiny test script that evaluates just the transcript-path logic from
  # functions.sh so we run the REAL code under test, not a copy of it.
  # Extract lines between "Derive transcript path" and "[[ -f " (exclusive) and
  # strip the `local` keyword (not valid at top-level) to get a runnable snippet.
  cat > "$d/eval_path.bash" << INNER_EOF
#!/usr/bin/env bash
REPO_ROOT="$fake_repo"
session_id="$session_id"
$(awk '/Derive transcript path/{found=1; next} found && /\[\[ -f "\$transcript/{exit} found{print}' \
    "$FUNCTIONS_SH" \
    | sed 's/^[[:space:]]*local //')
echo "\$transcript"
INNER_EOF
  chmod +x "$d/eval_path.bash"

  # Scenario A: override set → must equal MAKATO_TRANSCRIPT_PATH
  local got_a
  got_a=$(MAKATO_TRANSCRIPT_PATH="$expected_override" bash "$d/eval_path.bash" 2>/dev/null)
  if [[ "$got_a" == "$expected_override" ]]; then
    pass "T2a MAKATO_TRANSCRIPT_PATH override used when set"
  else
    fail "T2a" "expected '$expected_override', got '$got_a'"
  fi

  # Scenario B: override unset → must use legacy HOME derivation
  local expected_legacy="$HOME/.claude/projects/${project_hash}/${session_id}.jsonl"
  local got_b
  got_b=$(bash "$d/eval_path.bash" 2>/dev/null)
  if [[ "$got_b" == "$expected_legacy" ]]; then
    pass "T2b legacy HOME derivation used when MAKATO_TRANSCRIPT_PATH unset"
  else
    fail "T2b" "expected '$expected_legacy', got '$got_b'"
  fi

  rm -rf "$d"
}

echo "== langfuse-trace smoke tests =="
t1_env_var_present
t2_override_honoured

echo ""
echo "Passed: $PASS   Failed: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'Failed tests: %s\n' "${FAILED_TESTS[*]}"
  exit 1
fi
