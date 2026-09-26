#!/usr/bin/env bash
# test_harness_independence_infra.sh
#
# Behaviour-documenting tests for the makato-harness-independence infra artefacts.
# Each test function asserts the observable structure and correctness of the
# generated files. Tests pass on any OS (Linux or macOS); GPU/container checks
# are skipped when the required tools are absent.
#
# Requires: bash ≥ 4, python3 (for YAML validation), jq
#
# Usage:
#   bash tests/infra/test_harness_independence_infra.sh
#   bash tests/infra/test_harness_independence_infra.sh --verbose

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERBOSE=false
[[ "${1:-}" == "--verbose" ]] && VERBOSE=true

PASS=0
FAIL=0
SKIP=0

# ── Test framework ────────────────────────────────────────────────────────────
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    $VERBOSE && echo "  PASS: $desc" || true
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "        expected: $expected"
    echo "        actual:   $actual"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    PASS=$((PASS + 1))
    $VERBOSE && echo "  PASS: $desc" || true
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (needle '$needle' not found)"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qi "$needle"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (forbidden needle '$needle' WAS found)"
  else
    PASS=$((PASS + 1))
    $VERBOSE && echo "  PASS: $desc" || true
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  if [[ -f "$path" ]]; then
    PASS=$((PASS + 1))
    $VERBOSE && echo "  PASS: $desc" || true
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (file not found: $path)"
  fi
}

assert_yaml_valid() {
  local desc="$1" path="$2"
  if python3 -c "import yaml; yaml.safe_load(open('$path'))" 2>/dev/null; then
    PASS=$((PASS + 1))
    $VERBOSE && echo "  PASS: $desc" || true
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (YAML parse error)"
  fi
}

skip_test() {
  SKIP=$((SKIP + 1))
  $VERBOSE && echo "  SKIP: $1" || true
}

run_suite() {
  local name="$1"
  echo ""
  echo "=== $name ==="
}

# ── Suite 1: docker-compose.langfuse.yml ─────────────────────────────────────
run_suite "infra/docker-compose.langfuse.yml"

DC_FILE="$REPO_ROOT/infra/docker-compose.langfuse.yml"
assert_file_exists "file exists" "$DC_FILE"
assert_yaml_valid  "file is valid YAML" "$DC_FILE"

# Service is named langfuse (check raw YAML text — key 'langfuse:' under services)
assert_contains "services.langfuse defined" "$(cat "$DC_FILE")" "langfuse:"

# Single host port exposed
assert_contains "port mapping present" "$(cat "$DC_FILE")" '"${LANGFUSE_PORT:-3000}:3000"'

# Healthcheck stanza present
assert_contains "healthcheck defined" "$(cat "$DC_FILE")" "healthcheck:"
assert_contains "healthcheck test command" "$(cat "$DC_FILE")" "/api/public/health"

# OTLP ingestion hint present
assert_contains "OTLP endpoint env var" "$(cat "$DC_FILE")" "LANGFUSE_ENABLE_EXPERIMENTAL_FEATURES"

# Two projects seeded
assert_contains "makato project seed" "$(cat "$DC_FILE")" "MAKATO_INIT_PROJECT_NAME"
assert_contains "sagibeast project seed" "$(cat "$DC_FILE")" "SAGIBEAST_INIT_PROJECT_NAME"

# Restart policy for service reliability
assert_contains "restart policy" "$(cat "$DC_FILE")" "restart:"

# ── Suite 2: infra/vllm-serve.yaml ───────────────────────────────────────────
run_suite "infra/vllm-serve.yaml"

VLLM_FILE="$REPO_ROOT/infra/vllm-serve.yaml"
assert_file_exists "file exists" "$VLLM_FILE"
assert_yaml_valid  "file is valid YAML" "$VLLM_FILE"

# Required fields
assert_contains "model field present"                   "$(cat "$VLLM_FILE")" "^model:"
assert_contains "gpu_memory_utilization present"        "$(cat "$VLLM_FILE")" "gpu_memory_utilization:"
assert_contains "max_model_len present"                 "$(cat "$VLLM_FILE")" "max_model_len:"
assert_contains "quantization: fp8 declared"            "$(cat "$VLLM_FILE")" "quantization: fp8"
assert_contains "port: 8000 (OpenAI-compat endpoint)"  "$(cat "$VLLM_FILE")" "port: 8000"

# served_model_name exposes both the neutral makato-oss alias ("open") and the
# concrete SAGIBEAST ModelProfile name ("qwen3-reasoning") on one endpoint.
python3 - "$VLLM_FILE" <<'PYEOF' && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "  FAIL: served_model_name exposes 'open' and 'qwen3-reasoning'"; }
import yaml, sys
d = yaml.safe_load(open(sys.argv[1]))
names = d.get("served_model_name")
names = [names] if isinstance(names, str) else (names or [])
assert "open" in names, f"neutral alias 'open' missing from served_model_name: {names!r}"
assert "qwen3-reasoning" in names, f"'qwen3-reasoning' missing from served_model_name: {names!r}"
PYEOF

# GPU budget: fraction must be <= 0.85 (hard co-location ceiling for a 48 GB card;
# the working target is 0.75, leaving VRAM headroom for co-resident BGE-M3).
UTIL=$(python3 -c "import yaml; d=yaml.safe_load(open('$VLLM_FILE')); print(d.get('gpu_memory_utilization', 0))" 2>/dev/null || echo "0")
if python3 -c "import sys; sys.exit(0 if float('$UTIL') <= 0.85 else 1)" 2>/dev/null; then
  PASS=$((PASS + 1))
  $VERBOSE && echo "  PASS: gpu_memory_utilization <= 0.85" || true
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: gpu_memory_utilization ($UTIL) exceeds 48 GB co-location ceiling (0.85)"
fi

# ── Suite 3: config/config.yml models section ─────────────────────────────────
run_suite "config/config.yml"

CONFIG_FILE="$REPO_ROOT/config/config.yml"
assert_file_exists "file exists" "$CONFIG_FILE"
assert_yaml_valid  "file is valid YAML" "$CONFIG_FILE"

python3 - "$CONFIG_FILE" <<'PYEOF' && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "  FAIL: models.open section structure"; }
import yaml, sys
cfg = yaml.safe_load(open(sys.argv[1]))
assert 'models' in cfg, "models section missing"
m = cfg['models']['open']
assert 'model_name' in m, "model_name missing"
assert 'api_base' in m, "api_base missing"
assert 'api_key' in m, "api_key missing"
print("  PASS: models.open has model_name, api_base, api_key") if False else None
PYEOF

# api_base references localhost:8100 (vllm-serve.sh overrides vllm-serve.yaml's port: 8000 via --port $VLLM_PORT=8100)
assert_contains "api_base points to vLLM localhost:8100" "$(cat "$CONFIG_FILE")" "8100"

# api_key uses env-var reference (never hard-coded)
assert_contains "api_key is env-var reference" "$(cat "$CONFIG_FILE")" 'VLLM_API_KEY'

# ── Suite 4: scripts/inject-otlp-keys.sh ─────────────────────────────────────
run_suite "scripts/inject-otlp-keys.sh"

INJECT_SCRIPT="$REPO_ROOT/scripts/inject-otlp-keys.sh"
assert_file_exists "file exists"             "$INJECT_SCRIPT"
assert_contains    "is executable (chmod +x)" "$(ls -la "$INJECT_SCRIPT")" "x"

# Syntax check
bash -n "$INJECT_SCRIPT" 2>/dev/null && { PASS=$((PASS + 1)); $VERBOSE && echo "  PASS: bash syntax valid" || true; } || { FAIL=$((FAIL + 1)); echo "  FAIL: bash syntax error"; }

# Dry-run with pre-supplied keys exits 0 and writes no files
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
_dry_exit=0
MAKATO_LANGFUSE_KEY="pk-test-1" SAGIBEAST_LANGFUSE_KEY="pk-test-2" \
  bash "$INJECT_SCRIPT" --dry-run --env-file "$TMPDIR_TEST/test.env" >/dev/null 2>&1 || _dry_exit=$?
assert_eq "dry-run exit code is 0" "0" "$_dry_exit"
if [[ ! -f "$TMPDIR_TEST/test.env" ]]; then
  PASS=$((PASS + 1)); $VERBOSE && echo "  PASS: dry-run does not write env file" || true
else
  FAIL=$((FAIL + 1)); echo "  FAIL: dry-run should not write env file but it did"
fi

# Write mode: MAKATO_LANGFUSE_KEY written into env file
_write_exit=0
MAKATO_LANGFUSE_KEY="pk-lf-makato-test" SAGIBEAST_LANGFUSE_KEY="pk-lf-sagibeast-test" \
  bash "$INJECT_SCRIPT" --env-file "$TMPDIR_TEST/dispatch.env" >/dev/null 2>&1 || _write_exit=$?
assert_eq "write mode exits 0" "0" "$_write_exit"
assert_contains "MAKATO_LANGFUSE_KEY in env file"    "$(cat "$TMPDIR_TEST/dispatch.env")" "MAKATO_LANGFUSE_KEY"
assert_contains "SAGIBEAST_LANGFUSE_KEY in env file" "$(cat "$TMPDIR_TEST/dispatch.env")" "SAGIBEAST_LANGFUSE_KEY"
assert_contains "LANGFUSE_OTLP_ENDPOINT in env file" "$(cat "$TMPDIR_TEST/dispatch.env")" "LANGFUSE_OTLP_ENDPOINT"

# Idempotency: re-running with different keys overwrites, does not duplicate
MAKATO_LANGFUSE_KEY="pk-lf-makato-v2" SAGIBEAST_LANGFUSE_KEY="pk-lf-sagibeast-v2" \
  bash "$INJECT_SCRIPT" --env-file "$TMPDIR_TEST/dispatch.env" >/dev/null 2>&1
LINE_COUNT=$(wc -l < "$TMPDIR_TEST/dispatch.env" | tr -d ' ')
assert_eq "idempotency: env file has exactly 3 lines after re-run" "3" "$LINE_COUNT"
assert_contains "idempotency: updated MAKATO key present" "$(cat "$TMPDIR_TEST/dispatch.env")" "pk-lf-makato-v2"

# ── Suite 5: scripts/budget-check.sh ─────────────────────────────────────────
run_suite "scripts/budget-check.sh"

BUDGET_SCRIPT="$REPO_ROOT/scripts/budget-check.sh"
assert_file_exists "file exists"             "$BUDGET_SCRIPT"
assert_contains    "is executable (chmod +x)" "$(ls -la "$BUDGET_SCRIPT")" "x"

# Syntax check
bash -n "$BUDGET_SCRIPT" 2>/dev/null && { PASS=$((PASS + 1)); $VERBOSE && echo "  PASS: bash syntax valid" || true; } || { FAIL=$((FAIL + 1)); echo "  FAIL: bash syntax error"; }

# --json flag emits valid JSON
JSON_OUT=$(bash "$BUDGET_SCRIPT" --ram --json 2>/dev/null || true)
echo "$JSON_OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'status' in d; assert 'checks' in d" 2>/dev/null \
  && { PASS=$((PASS + 1)); $VERBOSE && echo "  PASS: --json emits valid JSON with status and checks" || true; } \
  || { FAIL=$((FAIL + 1)); echo "  FAIL: --json output not valid JSON or missing fields (got: $JSON_OUT)"; }

# On a system without /proc/meminfo (macOS), RAM check skips cleanly (exit 0)
if [[ ! -r /proc/meminfo ]]; then
  RAM_EXIT=0
  bash "$BUDGET_SCRIPT" --ram >/dev/null 2>&1 || RAM_EXIT=$?
  assert_eq "RAM check exits 0 when /proc/meminfo unavailable (graceful skip)" "0" "$RAM_EXIT"
else
  skip_test "RAM skip test (only relevant on non-Linux; /proc/meminfo available here)"
fi

# Script accepts --vram, --ram, --oom flags without error
bash "$BUDGET_SCRIPT" --oom >/dev/null 2>&1 && { PASS=$((PASS + 1)); $VERBOSE && echo "  PASS: --oom flag accepted" || true; } || { FAIL=$((FAIL + 1)); echo "  FAIL: --oom flag rejected"; }

# Unknown flag produces exit 1 and error message
bash "$BUDGET_SCRIPT" --unknown-flag >/dev/null 2>&1 && { FAIL=$((FAIL + 1)); echo "  FAIL: unknown flag should exit non-zero"; } || { PASS=$((PASS + 1)); $VERBOSE && echo "  PASS: unknown flag exits non-zero" || true; }

# Budget constants must match config/config.yml declarations
CONFIG_UTIL=$(python3 -c "import yaml; d=yaml.safe_load(open('$CONFIG_FILE')); print(d.get('budget',{}).get('vllm',{}).get('gpu_memory_utilization','0'))" 2>/dev/null || echo "0")
VLLM_UTIL=$(python3 -c "import yaml; d=yaml.safe_load(open('$VLLM_FILE')); print(d.get('gpu_memory_utilization','0'))" 2>/dev/null || echo "0")
assert_eq "config.yml vllm budget matches vllm-serve.yaml utilization" "$VLLM_UTIL" "$CONFIG_UTIL"

# ── Suite 6: OpenAI / Apple-local / remote-Linux profile independence ────────
# (local-openai-gpt-macos-compatibility, Task 5 — extends this file per the
# plan's Task 5 file list). Asserts the three provider profiles resolve
# independently of one another and of any Claude-specific assumption, and
# that the macOS/remote-Linux guard scripts Task 5 adds/modifies are present
# and structurally sound.
run_suite "provider/platform independence (Task 5)"

MODEL_PROFILES_FILE="$REPO_ROOT/config/model-profiles.yml"
RESOLVE_PROFILE="$REPO_ROOT/scripts/resolve-model-profile.py"
assert_file_exists "config/model-profiles.yml exists" "$MODEL_PROFILES_FILE"
assert_file_exists "scripts/resolve-model-profile.py exists" "$RESOLVE_PROFILE"

# The checked-in credential-free local-vLLM default must be preserved.
DEFAULT_PROFILE=$(sed -nE 's/^default_profile:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' "$MODEL_PROFILES_FILE" | head -1)
assert_eq "default_profile is still the checked-in qwen-vllm default" "qwen-vllm" "$DEFAULT_PROFILE"

# Each profile resolves independently (no cross-provider leakage) — provider
# field must match the profile's own declared provider, never another
# profile's, and never a Claude-specific value.
for pair in "openai:openai" "qwen-vllm:local" "apple-ollama:ollama"; do
  profile="${pair%%:*}"
  expected_provider="${pair##*:}"
  summary_json=$(python3 "$RESOLVE_PROFILE" "$profile" --config "$MODEL_PROFILES_FILE" --emit summary 2>/dev/null) \
    && { PASS=$((PASS + 1)); $VERBOSE && echo "  PASS: profile '$profile' resolves cleanly" || true; } \
    || { FAIL=$((FAIL + 1)); echo "  FAIL: profile '$profile' failed to resolve"; }
  actual_provider=$(printf '%s' "$summary_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("provider",""))' 2>/dev/null || echo "")
  assert_eq "profile '$profile' provider is independent ('$expected_provider')" "$expected_provider" "$actual_provider"
  assert_not_contains "profile '$profile' summary has no Claude-specific field" "$summary_json" "claude"
done

# The Task 5 macOS/remote-Linux scripts must exist and never hardcode a
# Claude-only harness assumption (this story's harness adapter is
# provider-neutral — see plugins/makato-orchestrate/scripts/harness-command.sh).
for script in "scripts/macos-setup.sh" "scripts/preflight-model-runtime.sh" \
              "scripts/preflight-omp-context.sh" "scripts/preflight-optional-services.sh"; do
  full_path="$REPO_ROOT/$script"
  assert_file_exists "$script exists" "$full_path"
  if [[ -f "$full_path" ]]; then
    if grep -qi "claude" "$full_path"; then
      FAIL=$((FAIL + 1))
      echo "  FAIL: $script contains a Claude-specific reference (should be provider-neutral)"
    else
      PASS=$((PASS + 1))
      $VERBOSE && echo "  PASS: $script has no Claude-specific reference" || true
    fi
  fi
done

# scripts/preflight-omp-context.sh and scripts/preflight-model-runtime.sh must
# honour MAKATO_MODEL_PROFILE (not hardcode a single provider).
assert_contains "preflight-omp-context.sh honours MAKATO_MODEL_PROFILE" \
  "$(cat "$REPO_ROOT/scripts/preflight-omp-context.sh")" "MAKATO_MODEL_PROFILE"
assert_contains "preflight-model-runtime.sh honours MAKATO_MODEL_PROFILE" \
  "$(cat "$REPO_ROOT/scripts/preflight-model-runtime.sh")" "MAKATO_MODEL_PROFILE"

# infra/bootstrap-vllm.sh and infra/vllm-serve.sh must guard against running
# on a non-Linux (Darwin/Apple Silicon) host — Task 5's explicit Linux/NVIDIA
# guard, kept separate from the macOS setup path.
assert_contains "bootstrap-vllm.sh guards against non-Linux hosts" \
  "$(cat "$REPO_ROOT/infra/bootstrap-vllm.sh")" 'uname -s'
assert_contains "vllm-serve.sh guards against non-Linux hosts" \
  "$(cat "$REPO_ROOT/infra/vllm-serve.sh")" 'uname -s'

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "═══════════════════════════════════════════════"

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
