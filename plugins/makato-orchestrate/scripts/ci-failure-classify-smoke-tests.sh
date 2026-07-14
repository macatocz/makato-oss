#!/usr/bin/env bash
# ci-failure-classify-smoke-tests.sh
# Smoke tests for po-agent Step 6a CI failure type classification logic.
# Verifies that po-agent.md describes the correct classification rules.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

PLUGIN_DIR="plugins/makato-orchestrate"
PO_AGENT_MD="${PLUGIN_DIR}/agents/po-agent.md"

PASS=0
FAIL=0

_pass() { printf "  ✓ %s\n" "$1"; (( PASS++ )) || true; }
_fail() { printf "  ✗ %s\n" "$1" >&2; (( FAIL++ )) || true; }

assert() {
  local label="$1" cmd="$2" arg="${3:-}"
  if [[ -n "$arg" ]]; then
    if "$cmd" "$arg"; then _pass "$label"; else _fail "$label"; fi
  else
    if $cmd; then _pass "$label"; else _fail "$label"; fi
  fi
}

contains_F() { grep -qF "$1" "$2"; }
contains_E() { grep -qE "$1" "$2"; }

echo "=== ci-failure-classify smoke tests ==="
echo

# T1: sensor check name classification
echo "T1: sensor tool name triggers ci_failure_type: sensor"
if grep -qE 'ci_failure_type' "$PO_AGENT_MD"; then
  _pass "po-agent.md defines ci_failure_type field"
else
  _fail "po-agent.md missing ci_failure_type field"
fi
for tool in ruff pyright bandit biome sqlfluff markdownlint semgrep trivy gitleaks helm; do
  if grep -qE "(?i).*${tool}" "$PO_AGENT_MD" 2>/dev/null || grep -qi "$tool" "$PO_AGENT_MD"; then
    _pass "po-agent.md references sensor tool: $tool"
  else
    _fail "po-agent.md missing sensor tool in classification regex: $tool"
  fi
done

# T2: test check name classification
echo
echo "T2: test tool name triggers ci_failure_type: test"
for tool in pytest jest; do
  if grep -qi "$tool" "$PO_AGENT_MD"; then
    _pass "po-agent.md references test tool: $tool"
  else
    _fail "po-agent.md missing test tool in classification regex: $tool"
  fi
done

# T3: unknown fallback documented
echo
echo "T3: unknown fallback documented"
if grep -qF '"unknown"' "$PO_AGENT_MD"; then
  _pass 'po-agent.md documents "unknown" fallback ci_failure_type'
else
  _fail 'po-agent.md missing "unknown" fallback ci_failure_type'
fi

# T4: sensor routing to sensor-fixer (not only build-implement-tdd)
echo
echo "T4: sensor routing dispatches sensor-fixer"
if grep -qE 'sensor.fixer|sensor_fixer' "$PO_AGENT_MD"; then
  _pass "po-agent.md dispatches sensor-fixer on sensor ci_failure_type"
else
  _fail "po-agent.md missing sensor-fixer dispatch for ci_failure_type == sensor"
fi

# T5: ci_failure_type in JSONL row
echo
echo "T5: ci_failure_type present in ci-poll JSONL row"
if grep -A3 'ci-poll' "$PO_AGENT_MD" | grep -qF 'ci_failure_type'; then
  _pass "ci-poll JSONL row includes ci_failure_type field"
else
  _fail "ci-poll JSONL row missing ci_failure_type field"
fi

# T6: sensor-delegated audit row
echo
echo "T6: sensor-delegated JSONL row documented in po-agent"
if grep -qF 'sensor-delegated' "$PO_AGENT_MD"; then
  _pass "po-agent.md documents sensor-delegated JSONL audit row"
else
  _fail "po-agent.md missing sensor-delegated JSONL audit row"
fi

# T7: escalation path preserved (fall through to build-implement-tdd)
echo
echo "T7: escalation path preserved on sensor-fixer failure"
if grep -qF 'build-implement-tdd' "$PO_AGENT_MD" && \
   grep -A10 'sensor.fixer' "$PO_AGENT_MD" | grep -qF 'build-implement-tdd'; then
  _pass "po-agent.md preserves build-implement-tdd escalation on sensor-fixer failure"
else
  _fail "po-agent.md missing build-implement-tdd escalation path after sensor-fixer"
fi

echo
echo "=========================================="
printf "Passed: %d\n" "$PASS"
printf "Failed: %d\n" "$FAIL"
echo "=========================================="

[[ $FAIL -eq 0 ]]
